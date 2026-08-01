#!/bin/bash -e

set -euo pipefail

WORKDIR="$PWD/Workdir"
OUTPUT="$WORKDIR/Builds"

sed -i '/^Types:/ {/deb-src/! s/$/ deb-src/;}' /etc/apt/sources.list.d/debian.sources

apt update -y &> /dev/null
apt build-dep -y mesa &> /dev/null
apt install wget cmake pkg-config git unzip -y &> /dev/null

mkdir -p $WORKDIR $OUTPUT

cd $WORKDIR

wget -O ndk.tar.gz https://github.com/SnowNF/ndk-aarch64-linux/releases/download/0.0.2/android-ndk-r29-linux-aarch64.tar.gz &> /dev/null

tar -zxf ndk.tar.gz &> /dev/null

wget -O shims.zip https://raw.githubusercontent.com/leegao/mesa-26.2/test-kbase/shims.zip

unzip shims.zip &> /dev/null

export shims="$WORKDIR/shims"

export PKG_CONFIG_LIBDIR="$shims/lib"

export NDK_BIN="$WORKDIR/r29/toolchains/llvm/prebuilt/linux-x86_64/bin"

git clone --depth=1 https://gitlab.freedesktop.org/mesa/mesa.git

cd mesa

cat <<EOF > android.txt
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['$NDK_BIN/aarch64-linux-android28-clang', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
cpp = ['$NDK_BIN/aarch64-linux-android28-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
c_ld = '$NDK_BIN/ld.lld'
cpp_ld = '$NDK_BIN/ld.lld'
strip = '$NDK_BIN/llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

cat <<EOF > native.txt
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

wget https://raw.githubusercontent.com/leegao/mesa-26.2/refs/heads/test-kbase/0000-disable-android-detection.patch
wget https://raw.githubusercontent.com/leegao/mesa-26.2/refs/heads/test-kbase/0006-wsi-no-pthread_cancel.patch

patch -p1 -i 0000-disable-android-detection.patch
patch -p1 -i 0006-wsi-no-pthread_cancel.patch

meson setup build-android-aarch64 \
    --cross-file android.txt \
    --native-file native.txt \
    --prefix "$OUTPUT" \
    -Dbuildtype=release \
    -Dstrip=true \
    -Dplatforms=android,x11 \
    -Dplatform-sdk-version=28 \
    -Dandroid-stub=true \
    -Dgallium-drivers=zink \
    -Dvulkan-drivers=freedreno \
    -Dvulkan-beta=true \
    -Dfreedreno-kmds=kgsl \
    -Degl=enabled \
    -Degl-native-platform=x11

    ninja -C build-android-aarch64 -j$(nproc) install
