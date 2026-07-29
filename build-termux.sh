#!/bin/bash -e

WORKDIR="$PWD/Workdir"
OUTPUT="$WORKDIR/Builds"

sed -i '/^Types:/ {/deb-src/! s/$/ deb-src/;}' /etc/apt/sources.list.d/debian.sources

apt update -y &> /dev/null
apt build-dep -y mesa &> /dev/null
apt install wget cmake pkg-config git -y &> /dev/null

mkdir -p $WORKDIR $OUTPUT

cd $WORKDIR

wget -O ndk.zip https://dl.google.com/android/repository/android-ndk-r30-beta2-linux.zip &> /dev/null

unzip ndk.zip &> /dev/null

wget -O Rootfs.tar https://github.com/JustCallMeJade/TermuxFS-RootFS/releases/download/build-20260218/termuxfs-aarch64.tar &> /dev/null

tar -xf Rootfs.tar

export rfs="$WORKDIR/data/data/com.termux/files/usr"

export PKG_CONFIG_PATH="$rfs/lib/pkgconfig:$rfs/share/pkgconfig"

export PKG_CONFIG_LIBDIR="$rfs/lib/pkgconfig:$rfs/share/pkgconfig"

export NDK-BIN="$WORKDIR/android-ndk-r30-beta2/toolchains/llvm/prebuilt/linux-x86_64/bin"

git clone --depth=1 https://gitlab.freedesktop.org/mesa/mesa.git

cd mesa

cat <<EOF > android.txt
[binaries]
ar = '$ndk/llvm-ar'
c = ['$ndk/aarch64-linux-android28-clang', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
cpp = ['$NDK-BKN/aarch64-linux-android28-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
c_ld = '$NDK-BIN/ld.lld'
cpp_ld = '$NDK-BIN/ld.lld'
strip = '$NDK-BIN/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$rfs/lib/pkg-config:$rfs/share/pkg-config', 'PKG_CONFIG_PATH=$rfs/lib/pkgconfig:$rfs/lib/pkgconfig', 'pkg-config']

[properties]
sys_root = '$sysroot'

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

[build_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

meson setup build-android-aarch64 \
    --cross-file android.txt \
    --native-file native.txt \
    --prefix "$OUTPUT" \
    -Dbuildtype=debugoptimized \
    -Dstrip=true \
    -Dplatforms=android,x11 \
    -Dvideo-codecs=all \
    -Dplatform-sdk-version=28 \
    -Dandroid-stub=true \
    -Dgallium-drivers=freedreno \
    -Dvulkan-drivers=freedreno \
    -Dvulkan-beta=true \
    -Dfreedreno-kmds=kgsl \
    -Degl=enabled \
    -Dandroid-strict=false \
    -Degl-native-platform=x11

    ninja -C build-aarch64 -j$(nproc) install
