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

