#!/bin/bash
set -xe

workdir="$(pwd)/pan_workdir"
ndk="$workdir/android-ndk-r30-beta2/toolchains/llvm/prebuilt/linux-x86_64/bin"
sysroot="$workdir/android-ndk-r30-beta2/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
mesasrc="https://github.com/leegao/mesa-26.2.git"
deps="git pkg-config cmake build-essential wget2 patchelf zip unzip"
VERSION="26.2.0-V1.0"
ndk_home="$ndk/.."
tmux="data/data/com.termux/files"

echo "Only works in Ubuntu x86_64!!! press Ctrl + C to exit"
echo "Installing build dependencies..."

apt install sudo -y &> /dev/null || true

sudo sed -i '/^Types:/{/deb-src/! s/$/ deb-src/;}' /etc/apt/sources.list.d/ubuntu.sources || true

sudo apt-get update -y > /dev/null 2>&1
sudo apt-get build-dep mesa -y -qq > /dev/null 2>&1
sudo apt-get build-dep libarchive -y -qq > /dev/null 2>&1
sudo apt install -y $deps > /dev/null 2>&1
sudo apt install git pkg-config cmake patchelf build-essential wget2 zip # fallback when deps installation failed
sudo apt-get install -y \
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
sudo apt remove -y rustc cargo &> /dev/null || true

mkdir -p "$workdir" && cd "$workdir"
mkdir -p "$workdir/mesa-vulkan-icd-panfrost"

rm -rf "$workdir/android-ndk-r30-beta2"
rm -rf "$workdir/mesa"
rm -rf "$workdir/android-ndk-r30-beta2-linux.zip"

cd "$workdir"

cd "$workdir/mesa-vulkan-icd-panfrost"
mkdir -p DEBIAN

mkdir -p $tmux/usr/lib
mkdir -p $tmux/usr/share/vulkan/icd.d

cat > ./DEBIAN/control << 'EOF'
Package: mesa-vulkan-icd-panfrost
Version: 26.2.0
Architecture: aarch64
Maintainer: JustCallMeJade <sdddxd86@gmail.com>
Section: libs
Priority: optional
Description: Mesa PanVK with leegao's kbase patches.
Replaces: mesa-vulkan-icd-freedreno
EOF

cd $workdir

export RUSTUP_HOME="$workdir/rustup"
export CARGO_HOME="$workdir/cargo"
export PATH="$CARGO_HOME/bin:$PATH"
export RUSTUP_HOME="$workdir/rustup"
export CARGO_HOME="$workdir/cargo"
export PATH="$CARGO_HOME/bin:$PATH"
export CARGO_BUILD_TARGET=aarch64-linux-android
export RUSTFLAGS="-Clinker=$ndk/aarch64-linux-android36-clang"

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

export CARGO_BUILD_TARGET=aarch64-linux-android
export RUSTFLAGS="-Clinker=$ndk/aarch64-linux-android36-clang"

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

cat > android-aarch64.txt <<EOF
[binaries]
ar = '$ndk/llvm-ar'
c = ['$ndk/aarch64-linux-android36-clang', '-D__TERMUX__']
cpp = ['$ndk/aarch64-linux-android36-clang++', '-fno-exceptions', '--start-no-unused-arguments', '--end-no-unused-arguments', '-D__TERMUX__']
strip = '$ndk/llvm-strip'
pkg-config = '/usr/bin/pkg-config'

[built-in options]
c_args = ['--sysroot=$sysroot', '-fno-emulated-tls', '-I$workdir/mesa/shims/include', '-isystem$sysroot/usr/include', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLFCN_H', '-UHAVE_SECURE_GETENV', '-UHAVE_QSORT_S', '-include', 'fcntl.h', '-include', 'time.h', '-Wl,-llog', '-Wl,-lsync', '-fvisibility=default']
cpp_args = ['--sysroot=$sysroot', '-include', '$workdir/mesa/src/util/u_gralloc/force_aosp_abi.h', '-D_LIBCPP_DISABLE_EXTERN_TEMPLATE', '-fno-emulated-tls', '-I$workdir/mesa/shims/include', '-isystem$sysroot/usr/include', '-DHAVE_STRUCT_TIMESPEC', '-DHAVE_DLFCN_H', '-UHAVE_SECURE_GETENV', '-UHAVE_QSORT_S', '-include', 'fcntl.h', '-include', 'time.h', '-include', 'dlfcn.h', '-Wl,-llog', '-Wl,-lsync', '-fvisibility=default', '-D_LIBCPP_ABI_NAMESPACE=__1']
c_link_args = ['--sysroot=$sysroot', '-Wl,--allow-shlib-undefined', '-L$workdir/mesa/shims', '-L$ndk_home/lib/clang/21/linux/aarch64', '-llog', '-lsync']
cpp_link_args = ['--sysroot=$sysroot', '-Wl,--allow-shlib-undefined', '-L$workdir/mesa/shims', '-L$ndk_home/lib/clang/21/linux/aarch64', '-llog', '-lsync']

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
    -Dplatforms=android,x11 \
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
    --prefix "$workdir/mesa-vulkan-icd-panfrost/$tmux/usr"

ninja -C build -j"$(nproc --all)" install 

cd "$workdir"

echo "packaging PanVK"

cd "$workdir/mesa-vulkan-icd-panfrost/data/data/com.termux/files/usr/share/vulkan/icd.d/"

rm -f panfrost_icd.aarch64.json

cat > panfrost_icd.aarch64.json <<'EOF'
{
    "ICD": {
        "api_version": "1.4.354",
        "library_arch": "64",
        "library_path": "/data/data/com.termux/files/usr/lib/libvulkan_panfrost.so"
    },
    "file_format_version": "1.0.1"
}
EOF

cd "$workdir"

dpkg-deb --build $workdir/mesa-vulkan-icd-panfrost

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "VERSION=$VERSION" >> "$GITHUB_ENV"
fi

echo "build complete."

exit 0
