#!/usr/bin/env python3

import difflib
import os
import subprocess
import sys


def find_git_repo_root(path):
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=path, capture_output=True, text=True, timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def try_git_am(repo_root, patch_path):
    print(f"Git repo detected at {repo_root} — trying `git am --3way` first "
          f"(more reliable than fuzzy matching when it works, since it can "
          f"use git's own 3-way merge against blob history).")

    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root, capture_output=True, text=True,
    )
    if status.stdout.strip():
        print("  Working tree has uncommitted changes — skipping git am "
              "(would risk mixing them into the am session) and going "
              "straight to fuzzy matching instead.")
        return False

    result = subprocess.run(
        ["git", "am", "--3way", os.path.abspath(patch_path)],
        cwd=repo_root, capture_output=True, text=True,
    )
    if result.returncode == 0:
        print("  git am --3way: succeeded")
        print(result.stdout.strip())
        return True

    print("  git am --3way: failed, aborting am session and falling back "
          "to fuzzy matching")
    print("  ---")
    for line in (result.stdout + result.stderr).strip().splitlines():
        print(f"  {line}")
    print("  ---")
    subprocess.run(["git", "am", "--abort"], cwd=repo_root, capture_output=True)
    return False


class Hunk:
    def __init__(self, old_lines, new_lines):
        self.old_lines = old_lines
        self.new_lines = new_lines


class FileChange:
    def __init__(self, path):
        self.path = path
        self.hunks = []
        self.is_new_file = False
        self.new_file_content = None
        self.is_deleted = False


def _clean_diff_path(raw_path):
    path = raw_path.split("\t")[0].strip()
    if path == "/dev/null":
        return None
    if path.startswith("a/") or path.startswith("b/"):
        path = path[2:]
    return path


def parse_patch(patch_path):
    with open(patch_path, errors="replace") as f:
        lines = f.readlines()

    changes = []
    cur = None
    in_hunk = False
    old_buf, new_buf = [], []
    new_file_mode = False
    is_deleted_file = False
    new_file_lines = []
    pending_minus_path = None

    def flush_hunk():
        nonlocal old_buf, new_buf
        if cur is not None and (old_buf or new_buf):
            cur.hunks.append(Hunk(old_buf, new_buf))
        old_buf, new_buf = [], []

    def start_new_file(path):
        nonlocal cur, in_hunk, new_file_mode, is_deleted_file, new_file_lines
        flush_hunk()
        in_hunk = False
        new_file_mode = False
        is_deleted_file = False
        new_file_lines = []
        cur = FileChange(path)
        changes.append(cur)

    for raw in lines:
        line = raw.rstrip("\n")

        if raw.startswith("diff --git"):
            parts = raw.split()
            path = parts[-1][2:] if len(parts) >= 4 else None
            start_new_file(path)
            pending_minus_path = None
            continue

        if raw.startswith("--- "):
            pending_minus_path = _clean_diff_path(raw[4:])
            continue

        if raw.startswith("+++ "):
            plus_path = _clean_diff_path(raw[4:])
            resolved = plus_path if plus_path is not None else pending_minus_path
            if cur is None or resolved != cur.path:
                start_new_file(resolved)
            if pending_minus_path is None:
                cur.is_new_file = True
            if plus_path is None:
                cur.is_deleted = True
            pending_minus_path = None
            continue

        if cur is None:
            continue

        if raw.startswith("new file mode"):
            new_file_mode = True
            cur.is_new_file = True
            continue

        if raw.startswith("deleted file mode"):
            cur.is_deleted = True
            continue

        if raw.startswith("@@"):
            flush_hunk()
            in_hunk = True
            continue

        if raw.startswith("index "):
            continue

        if not in_hunk:
            continue

        if raw.startswith("-") and not raw.startswith("---"):
            old_buf.append(line[1:])
        elif raw.startswith("+") and not raw.startswith("+++"):
            new_buf.append(line[1:])
            if new_file_mode:
                new_file_lines.append(line[1:])
        elif raw.startswith("\\"):
            continue
        elif raw.startswith(" ") or line == "":
            content = line[1:] if raw.startswith(" ") else line
            old_buf.append(content)
            new_buf.append(content)
        else:
            flush_hunk()
            in_hunk = False

    flush_hunk()

    for c in changes:
        if c.is_new_file:
            c.new_file_content = "\n".join(new_file_lines) + "\n" if new_file_lines else ""

    return [c for c in changes if c.path and (c.hunks or c.new_file_content is not None)]


def find_target_file(root, diff_path):
    basename = os.path.basename(diff_path)
    diff_parts = diff_path.replace("\\", "/").split("/")

    candidates = []
    for dirpath, _, filenames in os.walk(root):
        if basename in filenames:
            candidates.append(os.path.join(dirpath, basename))

    if not candidates:
        return None
    if len(candidates) == 1:
        return candidates[0]

    def score(candidate):
        cparts = candidate.replace("\\", "/").split("/")
        s = 0
        for a, b in zip(reversed(cparts), reversed(diff_parts)):
            if a == b:
                s += 1
            else:
                break
        return s

    candidates.sort(key=score, reverse=True)
    return candidates[0]


def _pick_anchor_line(old_lines):
    def is_trivial(l):
        s = l.strip()
        return len(s) < 8 or s in ("{", "}", "};", "});", "),", "(", ")")

    candidates = [l for l in old_lines if not is_trivial(l)]
    pool = candidates or old_lines
    return max(pool, key=len)


def find_best_window(file_lines, old_lines, min_ratio=0.6, local_radius=40):
    n = len(old_lines)
    if n == 0:
        return None

    anchor = _pick_anchor_line(old_lines)
    anchor_positions = [i for i, l in enumerate(file_lines) if l == anchor]

    if not anchor_positions:
        return None

    anchor_rel = old_lines.index(anchor)

    best = None
    best_ratio = 0.0
    for pos in anchor_positions:
        approx_start = max(0, pos - anchor_rel - local_radius)
        approx_end = min(len(file_lines), pos - anchor_rel + n + local_radius)
        for size_delta in range(-3, 8):
            size = n + size_delta
            if size <= 0:
                continue
            for start in range(approx_start, max(approx_start, approx_end - size) + 1):
                end = start + size
                if end > len(file_lines):
                    break
                window = file_lines[start:end]
                ratio = difflib.SequenceMatcher(None, old_lines, window, autojunk=False).ratio()
                if ratio > best_ratio:
                    best_ratio = ratio
                    best = (start, end)

    if best and best_ratio >= min_ratio:
        return best, best_ratio
    return None


def build_replacement(old_lines, new_lines, window_lines):
    sm = difflib.SequenceMatcher(None, old_lines, window_lines, autojunk=False)
    old_to_window = {}
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("equal", "replace"):
            for k in range(i1, i2):
                old_to_window[k] = True

    result = []
    old_idx = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            result.extend(new_lines[_map_new_index(old_lines, new_lines, i1):_map_new_index(old_lines, new_lines, i2)]
                          if False else window_lines[j1:j2])
        elif tag == "replace" or tag == "delete":
            pass
        elif tag == "insert":
            result.extend(window_lines[j1:j2])

    if difflib.SequenceMatcher(None, old_lines, window_lines, autojunk=False).ratio() > 0.97:
        return "\n".join(new_lines)

    new_pos_map = _align_new_lines(old_lines, new_lines)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal" or tag == "replace" or tag == "delete":
            n1 = new_pos_map.get(i1, len(new_lines) if i1 >= len(old_lines) else None)
            n2 = new_pos_map.get(i2, len(new_lines) if i2 >= len(old_lines) else None)
            if n1 is not None and n2 is not None:
                out.extend(new_lines[n1:n2])
        elif tag == "insert":
            out.extend(window_lines[j1:j2])
    return "\n".join(out)


def _align_new_lines(old_lines, new_lines):
    sm = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    mapping = {}
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1 + 1):
                if i1 + k <= len(old_lines):
                    mapping[i1 + k] = j1 + k
        elif tag in ("replace", "delete"):
            mapping[i1] = j1
            mapping[i2] = j2
        elif tag == "insert":
            mapping[i1] = j1
    mapping[len(old_lines)] = len(new_lines)
    return mapping


def _map_new_index(old_lines, new_lines, i):
    return _align_new_lines(old_lines, new_lines).get(i, len(new_lines))


def apply_file_change(path, change):
    if change.is_new_file:
        if os.path.exists(path):
            with open(path) as f:
                existing = f.read()
            if existing == change.new_file_content:
                print(f"  {path}: new file, already present (identical), skipping")
            else:
                print(f"  {path}: new file, but a DIFFERENT file already exists here — not overwriting")
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(change.new_file_content)
            print(f"  {path}: created")
        return

    with open(path) as f:
        content = f.read()
    file_lines = content.split("\n")
    trailing_newline = content.endswith("\n")

    applied = 0
    skipped = 0
    for idx, hunk in enumerate(change.hunks):
        old_text = "\n".join(hunk.old_lines)
        new_text = "\n".join(hunk.new_lines)

        if new_text and new_text in content:
            print(f"  {path}: hunk {idx}: already applied, skipping")
            continue

        if old_text in content:
            content = content.replace(old_text, new_text, 1)
            file_lines = content.split("\n")
            print(f"  {path}: hunk {idx}: exact match, applied")
            applied += 1
            continue

        result = find_best_window(file_lines, hunk.old_lines)
        if result is None:
            print(f"  {path}: hunk {idx}: no confident match found, SKIPPED")
            skipped += 1
            continue

        (start, end), ratio = result
        window_lines = file_lines[start:end]
        replacement_text = build_replacement(hunk.old_lines, hunk.new_lines, window_lines)
        new_file_lines = file_lines[:start] + replacement_text.split("\n") + file_lines[end:]
        content = "\n".join(new_file_lines)
        file_lines = content.split("\n")
        print(f"  {path}: hunk {idx}: fuzzy match (similarity {ratio:.2f}), applied — please spot-check")
        applied += 1

    if not trailing_newline and content.endswith("\n"):
        content = content[:-1]

    if applied:
        with open(path, "w") as f:
            f.write(content)
        print(f"  {path}: {applied} hunk(s) applied, {skipped} skipped")
    elif skipped:
        print(f"  {path}: 0 hunks applied, {skipped} skipped — file left untouched")


def process_one_patch(patch_path, abs_root):
    if not os.path.isfile(patch_path):
        print(f"ERROR: {patch_path} not found — skipping")
        return

    print(f"Parsing: {patch_path}")

    repo_root = find_git_repo_root(abs_root)
    if repo_root:
        if try_git_am(repo_root, patch_path):
            print("Done via git am — fuzzy matching wasn't needed.\n")
            return
        print()

    changes = parse_patch(patch_path)
    print(f"Found {len(changes)} file change(s) in {patch_path}")
    print(f"Searching under: {abs_root}\n")

    for change in changes:
        if change.is_new_file:
            target = os.path.join(abs_root, os.path.dirname(change.path), os.path.basename(change.path))
            parent_name = os.path.basename(os.path.dirname(change.path))
            found_dir = None
            if parent_name:
                for dirpath, dirnames, _ in os.walk(abs_root):
                    if os.path.basename(dirpath) == parent_name:
                        found_dir = dirpath
                        break
            if found_dir:
                target = os.path.join(found_dir, os.path.basename(change.path))
            apply_file_change(target, change)
            continue

        target = find_target_file(abs_root, change.path)
        if not target:
            print(f"{change.path}: not found anywhere under {abs_root}, skipping")
            continue
        apply_file_change(target, change)

    print()


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 patch-fixer.py patch1.patch [patch2.patch ...] [target_root]")
        sys.exit(1)

    args = sys.argv[1:]

    if os.path.isdir(args[-1]):
        root = args[-1]
        patch_paths = args[:-1]
    else:
        root = "."
        patch_paths = args

    if not patch_paths:
        print("ERROR: no patch files given")
        sys.exit(1)

    abs_root = os.path.abspath(root)
    if not os.path.isdir(abs_root):
        print(f"ERROR: {abs_root} is not a directory")
        sys.exit(1)

    print(f"{len(patch_paths)} patch file(s) to apply, in order, against {abs_root}\n")

    for i, patch_path in enumerate(patch_paths, 1):
        print(f"=== [{i}/{len(patch_paths)}] {patch_path} ===")
        process_one_patch(patch_path, abs_root)

    print("All patches processed.")


if __name__ == "__main__":
    main()
