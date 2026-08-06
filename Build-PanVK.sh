#!/bin/bash
set -oe pipefail

workdir="$(pwd)/pan_workdir"
ndk="$workdir/android-ndk-r30-beta2/toolchains/llvm/prebuilt/linux-x86_64/bin"
sysroot="$workdir/android-ndk-r30-beta2/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
mesasrc="https://github.com/leegao/mesa-26.2.git"
deps="git pkg-config cmake build-essential wget2 patchelf zip unzip"
VERSION="26.2.0-V1.0"
ndk_home="$ndk/.."
author="$(whoami)"
DEBIAN_FRONTEND=noninteractive

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    export author="JustCallMeJade"
fi

echo "Only works in Ubuntu/Debian based distros on X86_64!!! press Ctrl + C to exit"

sleep 10

clear

echo "Installing build dependencies..."

apt install sudo -y &> /dev/null || true # For root users, non root users will still run the script

sudo sed -i '/^Types:/{/deb-src/! s/$/ deb-src/;}' /etc/apt/sources.list.d/*.sources || true

sudo apt-get update -y -qq
sudo apt-get build-dep mesa -y -qq &> /dev/null
sudo apt install -y -qq $deps
sudo apt-get install -y -qq \
              build-essential \
              llvm-22-dev \
              libclang-22-dev \
              libclc-22-dev \
              libllvmspirvlib-22-dev \
              libelf-dev \
              spirv-tools \
              bison \
              flex \
              libdrm-dev \
              pkg-config \
              clang \
              llvm \
              llvm-dev &> /dev/null

mkdir -p "$workdir" && cd "$workdir"
mkdir -p "$workdir/output"

rm -rf "$workdir/android-ndk-r30-beta2"
rm -rf "$workdir/mesa"
rm -rf "$workdir/android-ndk-r30-beta2-linux.zip"

cd "$workdir"

wget2 -q -nv https://dl.google.com/android/repository/android-ndk-r30-beta2-linux.zip
unzip android-ndk-r30-beta2-linux.zip &> /dev/null

git clone \
    --depth=1 \
    --single-branch \
    --branch test-kbase \
    "$mesasrc" mesa
    
cd mesa

VK_API=$(grep -m1 -oP "(?<=--api-version', ')[0-9]+\.[0-9]+" src/panfrost/vulkan/meson.build)
VK_PATCH=$(grep -m1 -oP '(?<=VK_HEADER_VERSION">)[0-9]+' src/vulkan/registry/vk.xml)
VK_VERSION="$VK_API.$VK_PATCH"

unzip shims.zip -d ./ &> /dev/null

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

cat > android-aarch64.txt <<EOF
[binaries]
ar = '$ndk/llvm-ar'
c = ['$ndk/aarch64-linux-android36-clang', '-D__TERMUX__']
cpp = ['$ndk/aarch64-linux-android36-clang++', '-fno-exceptions', '--start-no-unused-arguments', '--end-no-unused-arguments', '-D__TERMUX__']
strip = '$ndk/llvm-strip'
pkg-config = '/usr/bin/pkg-config'

[built-in options]
c_args = ['--sysroot=$sysroot', '-fno-emulated-tls', '-I$workdir/mesa/shims/include', '-isystem$sysroot/usr/include', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLFCN_H', '-UHAVE_SECURE_GETENV', '-UHAVE_QSORT_S', '-include', 'fcntl.h', '-include', 'time.h', '-Wl,-llog', '-Wl,-lsync', '-fvisibility=default', '-Wl,-z,max-page-size=16384', '-Wl,-z,common-page-size=16834']
cpp_args = ['--sysroot=$sysroot', '-include', '$workdir/mesa/src/util/u_gralloc/force_aosp_abi.h', '-D_LIBCPP_DISABLE_EXTERN_TEMPLATE', '-fno-emulated-tls', '-I$workdir/mesa/shims/include', '-isystem$sysroot/usr/include', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLFCN_H', '-UHAVE_SECURE_GETENV', '-UHAVE_QSORT_S', '-include', 'fcntl.h', '-include', 'time.h', '-include', 'dlfcn.h', '-Wl,-llog', '-Wl,-lsync', '-fvisibility=default', '-D_LIBCPP_ABI_NAMESPACE=__1', '-Wl,-z,max-page-size=16384', '-Wl,-z,common-page-size=16834']
c_link_args = ['--sysroot=$sysroot', '-Wl,--allow-shlib-undefined', '-L$workdir/mesa/shims', '-L$ndk_home/lib/clang/18/linux/aarch64', '-llog', '-lsync', '-Wl,-z,common-page-size=16834', '-Wl,-z,max-page-size=16384']
cpp_link_args = ['--sysroot=$sysroot', '-Wl,--allow-shlib-undefined', '-L$workdir/mesa/shims', '-L$ndk_home/lib/clang/18/linux/aarch64', '-llog', '-lsync']

[properties]
sys_root = '$sysroot'
needs_exe_wrapper = true
pkg_config_libdir = '$workdir/mesa/shims'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

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
    -Dpanfrost-rust=false \
    --prefix "$workdir/output"

ninja -C build -j"$(nproc --all)" install 

cd "$workdir/output/lib"

echo "packaging PanVK"

patchelf --set-soname libvulkan_mali.so libvulkan_panfrost.so
mv libvulkan_panfrost.so libvulkan_mali.so

cat <<EOF > meta.json
{
"schemaVersion": 1,
"name": "Mesa PanVK v$VERSION",
"description": "custom mali_kbase patches Needs minimum android 16 or Android linux kernel 6.10",
"author": "$author",
"packageVersion": "26.2.0",
"vendor": "Mesa3D, Leegao",
"driverVersion": "$VK_VERSION",
"minApi": 36,
"libraryName": "libvulkan_mali.so"
}
EOF

zip -9 PanVK-v$VERSION.zip libvulkan_mali.so meta.json

echo "build complete."

exit 0
