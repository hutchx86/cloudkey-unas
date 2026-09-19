#!/bin/bash
# 00-create-chroot.sh -- create the bullseye cross-compile chroot that
# 01-build-kernel.sh must run inside (bullseye's gcc 10.2.1 exactly matches
# the CloudKey's kernel build). Run once on the local build machine, as root.
#
# Usage: sudo ./00-create-chroot.sh [chroot-path] [build-bind-mount-source]
#   chroot-path:             default /home/$SUDO_USER/bullseye-chroot
#   build-bind-mount-source: default /home/$SUDO_USER/ck-kernel-build, mounted as /build
#                            inside the chroot; copy UNAS-CloudKey/ + 01's inputs there.
# Idempotent: skips debootstrap if the chroot is valid, re-does the bind mount if unmounted.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)." >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

CHROOT_PATH="${1:-$REAL_HOME/bullseye-chroot}"
BUILD_DIR="${2:-$REAL_HOME/ck-kernel-build}"

log() { echo "[create-chroot] $*"; }

log "chroot path: $CHROOT_PATH"
log "build bind-mount source: $BUILD_DIR (appears as /build inside the chroot)"

if [[ -f "$CHROOT_PATH/etc/os-release" ]] && grep -q "bullseye" "$CHROOT_PATH/etc/os-release" 2>/dev/null; then
    log "chroot already exists and looks like bullseye -- skipping debootstrap"
else
    if ! command -v debootstrap >/dev/null 2>&1; then
        log "installing debootstrap"
        apt-get update -q
        apt-get install -y debootstrap
    fi
    log "debootstrapping bullseye into $CHROOT_PATH (this takes a few minutes)"
    mkdir -p "$CHROOT_PATH"
    debootstrap bullseye "$CHROOT_PATH" http://deb.debian.org/debian/
fi

mkdir -p "$BUILD_DIR" "$CHROOT_PATH/build"
if mountpoint -q "$CHROOT_PATH/build"; then
    log "build bind mount already active"
else
    log "bind-mounting $BUILD_DIR at $CHROOT_PATH/build"
    mount --bind "$BUILD_DIR" "$CHROOT_PATH/build"
fi

# Packages 01-build-kernel.sh's check_prerequisites() expects, plus git (cloned repo),
# perl/python3 (statx work), abootimg, openssh-client; python3/perl aren't guaranteed by debootstrap.
log "installing cross-compile toolchain and kernel build dependencies"
chroot "$CHROOT_PATH" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y \
        crossbuild-essential-arm64 build-essential \
        bc bison flex libssl-dev libelf-dev dwarves kmod cpio rsync \
        python3 perl device-tree-compiler abootimg git \
        wget ca-certificates openssh-client
'

log "verifying toolchain"
GCC_VERSION="$(chroot "$CHROOT_PATH" aarch64-linux-gnu-gcc --version | head -1)"
echo "$GCC_VERSION"
if ! grep -q "10.2.1" <<<"$GCC_VERSION"; then
    echo "WARNING: expected gcc 10.2.1 (Debian bullseye) -- got a different version." >&2
    echo "This tree is known to fail or misbehave with mismatched compilers." >&2
fi

log "done. Next: copy UNAS-CloudKey/ (plus the tarball/verified-running config/live DTB) into $BUILD_DIR, then:"
log "  sudo chroot $CHROOT_PATH /bin/bash"
log "  cd /build && ./UNAS-CloudKey/01-build-kernel.sh"
