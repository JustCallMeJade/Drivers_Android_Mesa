#!/bin/bash

workdir="$(pwd)/turnip_workdir"
ndk="$workdir/r29/toolchains/llvm/prebuilt/linux-x86_64/bin"
sysroot="$workdir/r29/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

deps="git pkg-config cmake build-essential wget2 patchelf zip"
VERSION="26.3.0-V5.0"

if [[ -z "${API_VER:-}" ]]; then
    echo "API_VER is not set. Select an API version:"
    select ver in 27 28 29 30 31 32 33 34 35 36; do
        if [[ -n "$ver" ]]; then
            API_VER="$ver"
            export API_VER
            break
        fi
        echo "Invalid selection."
    done
fi

echo "Only works in Debian/Ubuntu Arm64!!! press Ctrl + C to exit"
echo "Installing build dependencies..."

sudo sed -i '/^Types:/{/deb-src/! s/$/ deb-src/;}' /etc/apt/sources.list.d/debian.sources

sudo apt-get update -y > /dev/null 2>&1
sudo apt-get build-dep mesa -y -qq > /dev/null 2>&1
sudo apt-get build-dep libarchive -y -qq > /dev/null 2>&1
sudo apt install -y $deps > /dev/null 2>&1
sudo apt install git pkg-config cmake patchelf build-essential wget2 zip # fallback when deps installation failed

mkdir -p "$workdir" && cd "$workdir"
mkdir -p "$workdir/turnip"

rm -rf "$workdir/r29"
rm -rf "$workdir/mesa"
rm -rf "$workdir/android-ndk-r29-linux-aarch64.tar.gz"

cd "$workdir"
wget2 -q -nv https://github.com/SnowNF/ndk-aarch64-linux/releases/download/0.0.2/android-ndk-r29-linux-aarch64.tar.gz
tar -xzf android-ndk-r29-linux-aarch64.tar.gz

git clone "$mesasrc" --depth=1
cd mesa

git config user.name "Turnip-Builder"
git config user.email "sdddxd86@gmail.com"

rm -f VERSION
cat <<EOF > VERSION
$VERSION
EOF

cd "$workdir/mesa"

sed -i 's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' src/vulkan/runtime/vk_android.c || true
sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true

git add -A

cd "$workdir/mesa"
echo "#define TUGEN8_DRV_VERSION \"v$VERSION\"" > ./src/freedreno/vulkan/tu_version.h

export PATH="$ndk:$PATH"
export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export STRIP=llvm-strip
export OBJDUMP=llvm-objdump
export OBJCOPY=llvm-objcopy
export LDFLAGS="-fuse-ld=lld"

cd "$workdir/mesa"

cat <<EOF > android-aarch64.txt
[binaries]
ar = '$ndk/llvm-ar'
c = ['$ndk/aarch64-linux-android$API_VER-clang', '--sysroot=$sysroot', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
cpp = ['$ndk/aarch64-linux-android$API_VER-clang++', '--sysroot=$sysroot', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$sysroot/usr/lib/pkg-config', 'PKG_CONFIG_SYSROOT_DIR=$sysroot', '/usr/bin/pkg-config']

[built-in options]
c_args = ['--sysroot=$sysroot', '-Wno-error']
cpp_args = ['--sysroot=$sysroot']
c_link_args = ['--sysroot=$sysroot']
cpp_link_args = ['--sysroot=$sysroot']

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
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

cd "$workdir/mesa"
rm -rf build-android-aarch64

meson setup build-android-aarch64 \
    --cross-file android-aarch64.txt \
    --native-file native.txt \
    --prefix "$workdir/turnip" \
    -Dbuildtype=debugoptimized \
    -Dstrip=true \
    -Dplatforms=android \
    -Dvideo-codecs=all \
    -Dplatform-sdk-version="$API_VER" \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dvulkan-beta=true \
    -Dfreedreno-kmds=kgsl \
    -Degl=disabled \
    -Dandroid-strict=false || exit 1

ninja -C build-android-aarch64 -j"$(nproc)" install || exit 1

cd "$workdir/turnip/lib"

echo "packaging turnip"

patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
mv libvulkan_freedreno.so vulkan.adreno.so

cat <<EOF > meta.json
{
"schemaVersion": 1,
"name": "Mesa Turnip v$VERSION",
"description": "Built from Mesa source",
"author": "JustCallMeJade",
"packageVersion": "1",
"vendor": "Mesa3D",
"driverVersion": "Vulkan 1.4.354",
"minApi": 28,
"libraryName": "vulkan.adreno.so"
}
EOF

zip -9 "$workdir/turnip/Turnip-v$VERSION.zip" vulkan.adreno.so meta.json

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "VERSION=$VERSION" >> "$GITHUB_ENV"
fi

echo "build complete."

exit 0
