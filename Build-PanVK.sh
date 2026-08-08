#!/bin/bash
set -oe pipefail

workdir="$(pwd)/pan_workdir"
ndk="$workdir/android-ndk-r30-beta2/toolchains/llvm/prebuilt/linux-x86_64/bin"
sysroot="$workdir/android-ndk-r30-beta2/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
mesasrc="https://github.com/JustCallMeJade/mesa-26.2.git"
deps="git pkg-config cmake build-essential wget2 patchelf zip unzip curl"
VERSION="26.2.0-V1.0"
ndk_home="$ndk/.."

echo "Only works in Ubuntu/Debian x86_64!!! press Ctrl + C to exit"

sleep 10

echo "Installing build dependencies..."

apt install sudo -y &> /dev/null || true

sudo sed -i '/^Types:/{/deb-src/! s/$/ deb-src/;}' /etc/apt/sources.list.d/*.sources || true

sudo apt-get update -y > /dev/null 2>&1
sudo apt-get build-dep mesa -y -qq > /dev/null 2>&1
sudo apt-get build-dep libarchive -y -qq > /dev/null 2>&1
sudo apt install -y $deps > /dev/null 2>&1
sudo apt install git pkg-config cmake patchelf build-essential wget2 zip # fallback when deps installation failed

sudo apt-get install -y \
              build-essential \
              llvm-22 \
              llvm-22-dev \
              libllvm22 \
              libclang-22-dev \
              clang-22 \
              libclc-21-dev \
              libllvmspirvlib-22-dev \
              libelf-dev \
              spirv-tools \
              bison \
              flex \
              libdrm-dev \
              pkg-config \
              bindgen &> /dev/null

sudo apt remove -y rustc cargo &> /dev/null || true

mkdir -p "$workdir" && cd "$workdir"
mkdir -p "$workdir/output"

rm -rf "$workdir/android-ndk-r30-beta2"
rm -rf "$workdir/mesa"
rm -rf "$workdir/android-ndk-r30-beta2-linux.zip"

cd "$workdir"

export RUSTUP_HOME="$workdir/rustup"
export CARGO_HOME="$workdir/cargo"
export PATH="$CARGO_HOME/bin:$PATH"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

rustup target add aarch64-linux-android

wget2 -q -nv https://dl.google.com/android/repository/android-ndk-r30-beta2-linux.zip
unzip android-ndk-r30-beta2-linux.zip &> /dev/null

git clone \
    --depth=1 \
    --single-branch \
    --branch test-kbase \
    "$mesasrc" mesa

cd mesa

mkdir -p .cargo

cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$ndk/aarch64-linux-android36-clang"
ar = "$ndk/llvm-ar"

[env]
CC_aarch64_linux_android = "$ndk/aarch64-linux-android36-clang"
CXX_aarch64_linux_android = "$ndk/aarch64-linux-android36-clang++"
EOF

unzip shims.zip -d ./

git config user.name "PanVK-Builder"
git config user.email "sdddxd86@gmail.com"

rm -f VERSION 
cat <<EOF > VERSION
$VERSION
EOF

sed -i 's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' src/vulkan/runtime/vk_android.c || true
sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true
sed -i 's/#if defined(HAVE_MEMFD_CREATE) \&\& !defined __TERMUX__/#if defined(HAVE_MEMFD_CREATE)/' src/util/anon_file.c

# ============================================================
# LLVM 22 HOST TOOLCHAIN
# ============================================================

export LLVM_CONFIG=llvm-config-22
export LIBCLANG_PATH=/usr/lib/llvm-22/lib
export LD_LIBRARY_PATH="/usr/lib/llvm-22/lib:${LD_LIBRARY_PATH:-}"

export CC=clang-22
export CXX=clang++-22

# Force bindgen to use LLVM 22's clang/libclang.
export BINDGEN_CLANG_PATH=/usr/bin/clang-22

# Bindgen must parse the target as Android AArch64 rather than
# accidentally treating it as the host x86_64 architecture.
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android36 --sysroot=$sysroot"

cat > android-aarch64.txt <<EOF
[binaries]
ar = '$ndk/llvm-ar'
c = ['$ndk/aarch64-linux-android36-clang', '-D__TERMUX__']
cpp = ['$ndk/aarch64-linux-android36-clang++', '-fno-exceptions', '--start-no-unused-arguments', '--end-no-unused-arguments', '-D__TERMUX__']
strip = '$ndk/llvm-strip'
pkg-config = '/usr/bin/pkg-config'
rust = ['rustc', '--target=aarch64-linux-android']
cargo = 'cargo'

[built-in options]
c_args = ['--sysroot=$sysroot', '-fno-emulated-tls', '-I$workdir/mesa/shims/include', '-isystem$sysroot/usr/include', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLFCN_H', '-UHAVE_SECURE_GETENV', '-UHAVE_QSORT_S', '-include', 'fcntl.h', '-include', 'time.h', '-Wl,-llog', '-Wl,-lsync', '-fvisibility=default']
cpp_args = ['--sysroot=$sysroot', '-include', '$workdir/mesa/src/util/u_gralloc/force_aosp_abi.h', '-D_LIBCPP_DISABLE_EXTERN_TEMPLATE', '-fno-emulated-tls', '-I$workdir/mesa/shims/include', '-isystem$sysroot/usr/include', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLFCN_H', '-UHAVE_SECURE_GETENV', '-UHAVE_QSORT_S', '-include', 'fcntl.h', '-include', 'time.h', '-include', 'dlfcn.h', '-Wl,-llog', '-Wl,-lsync', '-fvisibility=default', '-D_LIBCPP_ABI_NAMESPACE=__1']
c_link_args = ['--sysroot=$sysroot', '-Wl,--allow-shlib-undefined', '-L$workdir/mesa/shims', '-L$ndk_home/lib/clang/21/linux/aarch64', '-llog', '-lsync']
cpp_link_args = ['--sysroot=$sysroot', '-Wl,--allow-shlib-undefined', '-L$workdir/mesa/shims', '-L$ndk_home/lib/clang/21/linux/aarch64', '-llog', '-lsync']

[properties]
sys_root = '$sysroot'
needs_exe_wrapper = true
pkg_config_libdir = '$workdir/mesa/shims'
bindgen_clang_properties = '--sysroot=$sysroot'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

# ============================================================
# BUILD HOST TOOLS WITH LLVM 22
# ============================================================

export CC=clang-22
export CXX=clang++-22
export LLVM_CONFIG=llvm-config-22
export LIBCLANG_PATH=/usr/lib/llvm-22/lib
export LD_LIBRARY_PATH="/usr/lib/llvm-22/lib:${LD_LIBRARY_PATH:-}"
export BINDGEN_CLANG_PATH=/usr/bin/clang-22
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android36 --sysroot=$sysroot"

meson setup build-host \
              -Dplatforms=[] \
              -Dgallium-drivers=[] \
              -Dvulkan-drivers=[] \
              -Dtools=panfrost \
              -Dprecomp-compiler=enabled \
              -Dinstall-precomp-compiler=true \
              -Dllvm=enabled \
              -Dmesa-clc=enabled -Dinstall-mesa-clc=true

ninja -C build-host src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/panfrost/clc/panfrost_compile

ln -sf "build-host/src/compiler/clc/mesa_clc" "build-host/src/compiler/clc/mesa-clc"
ln -sf "build-host/src/compiler/spirv/vtn_bindgen2" "build-host/src/compiler/spirv/vtn-bindgen2"

export PATH="$workdir/mesa/build-host/src/compiler/clc:$workdir/mesa/build-host/src/compiler/spirv:$workdir/mesa/build-host/src/panfrost/clc:$PATH"

# ============================================================
# ANDROID TARGET TOOLCHAIN
# ============================================================

export CC="$ndk/aarch64-linux-android36-clang"
export CXX="$ndk/aarch64-linux-android36-clang++"

# Keep LLVM 22 for bindgen/libclang.
export LLVM_CONFIG=llvm-config-22
export LIBCLANG_PATH=/usr/lib/llvm-22/lib
export LD_LIBRARY_PATH="/usr/lib/llvm-22/lib:${LD_LIBRARY_PATH:-}"
export BINDGEN_CLANG_PATH=/usr/bin/clang-22
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android36 --sysroot=$sysroot"

meson setup build \
    --cross-file android-aarch64.txt \
    -Dbuildtype=release \
    -Dstrip=true \
    -Dplatforms=android \
    -Dvideo-codecs=all \
    -Dplatform-sdk-version=36 \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=panfrost \
    -Dvulkan-beta=true \
    -Degl=disabled \
    -Dandroid-strict=false \
    -Dallow-fallback-for=libdrm \
    -Dmesa-clc=system \
    -Dprecomp-compiler=system \
    -Dvalgrind=disabled \
    -Dglx=disabled \
    -Dgbm=disabled \
    -Dglvnd=disabled \
    -Dopengl=false \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dllvm=disabled \
    -Dpanfrost-rust=true \
    --prefix "$workdir/output"

ninja -C build -j"$(nproc --all)" install 

git clone --depth 1 https://gitlab.freedesktop.org/mesa/libdrm

cd libdrm

export CFLAGS="-DANDROID"

mv ../android-aarch64.txt .

meson setup build \
--cross-file android-aarch64.txt \
-Dbuildtype=release \
--prefix "$workdir/output" \
-Dexynos=enabled \
-Dtests=disabled \
-Damdgpu=disabled \
-Dnouveau=disabled \
-Dintel=disabled \
-Dradeon=disabled \
-Dtegra=disabled \
-Detnaviv=disabled \
-Dfreedreno=disabled \
-Dvc4=disabled \
-Darmada=disabled \
-Domap=disabled \
-Dvmwgfx=disabled

ninja -C build

ninja -C build install &> /dev/null

cd "$workdir/output/lib"

echo "packaging PanVK"

patchelf --set-soname libvulkan_mali.so libvulkan_panfrost.so
mv libvulkan_panfrost.so libvulkan_mali.so

cat <<EOF > meta.json
{
"schemaVersion": 1,
"name": "Mesa PanVK v$VERSION",
"description": "Custom mali_kbase patches with Leegao's mesa. See supported GPUs here: [https://docs.mesa3d.org/drivers/panfrost.html].",
"author": "JustCallMeJade",
"packageVersion": "1",
"vendor": "Mesa3D, Leegao",
"driverVersion": "Vulkan 1.4",
"minApi": 30,
"libraryName": "libvulkan_mali.so"
}
EOF

zip -9 PanVK-v$VERSION.zip libvulkan_mali.so meta.json libdrm.so

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "VERSION=$VERSION" >> "$GITHUB_ENV"
fi

echo "build complete."

exit 0
