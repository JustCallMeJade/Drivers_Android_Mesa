#!/bin/bash

workdir="$(pwd)/turnip_workdir"
ndk="$workdir/r29/toolchains/llvm/prebuilt/linux-x86_64/bin" #yes r29 is the directory
sysroot="$workdir/r29/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_VERSION="26.3.0-devel"
echo "Only works in debian Arm64!!! press Ctrl + C to exit"
echo "Installing build dependencies..."

sed -i '/^Types:/ s/$/ deb-src/' /etc/apt/sources.list.d/debian.sources
    
apt-get update
apt-get build-dep mesa -y -qq > /dev/null 2>&1
apt-get build-dep libarchive -y -qq > /dev/null 2>&1

apt-get install -y pkg-config git cmake wget zip patchelf libclc-21-dev -qq > /dev/null 2>&1

mkdir -p "$workdir"
cd "$workdir"

mkdir -p "$workdir/turnip"

rm -rf "$workdir/r29"
rm -rf "$workdir/mesa"
rm -f "$workdir/android-ndk-r29-linux-aarch64.tar.gz"

wget -q -nv https://github.com/SnowNF/ndk-aarch64-linux/releases/download/0.0.2/android-ndk-r29-linux-aarch64.tar.gz
tar -xzf android-ndk-r29-linux-aarch64.tar.gz

git clone $mesasrc --depth=1
cd mesa

export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export STRIP=llvm-strip
export OBJDUMP=llvm-objdump
export OBJCOPY=llvm-objcopy
export LDFLAGS="-fuse-ld=lld"

cat <<EOF > android-aarch64.txt
[binaries]
ar = '$ndk/llvm-ar'
c = ['$ndk/aarch64-linux-android35-clang', '--sysroot=$sysroot', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
cpp = ['$ndk/aarch64-linux-android35-clang++', '--sysroot=$sysroot', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$sysroot/usr/lib/pkg-config', 'PKG_CONFIG_SYSROOT_DIR=$sysroot', '/usr/bin/pkg-config']

[built-in options]
c_args = ['--sysroot=$sysroot', '-Wno-error']
cpp_args = ['--sysroot=$sysroot']
c_link_args = ['--sysroot=$sysroot']
cpp_link_args = ['--sysroot=$sysroot']

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
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

rm -rf build-android-aarch64

meson setup build-android-aarch64 \
    --cross-file android-aarch64.txt \
    --native-file native.txt \
    --prefix "$workdir/turnip" \
    -Dbuildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version=35 \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dvulkan-beta=true \
    -Dfreedreno-kmds=kgsl \
    -Degl=disabled

ninja -C build-android-aarch64 install

cd "$workdir/turnip/lib"

echo "packaging turnip"

cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Mesa Turnip v$BUILD_VERSION",
  "description": "Built from Mesa source",
  "author": "JustCallMeJade",
  "packageVersion": "1",
  "vendor": "Mesa3D",
  "driverVersion": "Vulkan 1.4.354",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

zip -9 "$workdir/turnip/Turnip-v$BUILD_VERSION.zip" libvulkan_freedreno.so meta.json

if [ "$GITHUB_ACTIONS" = "true" ]; then
    echo "BUILD_VERSION=$BUILD_VERSION" >> "$GITHUB_ENV"
fi

echo "build complete."
exit 0
