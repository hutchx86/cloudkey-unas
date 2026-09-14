#!/bin/bash
# fetch-firmware-debs.sh
#
# Rebuilds fw_picked/debs-build/ from Ubiquiti's UNAS Pro firmware: downloads
# (and checksum-verifies) the pinned image, extracts its squashfs rootfs,
# then repacks every package named in fw_picked/debs-build.packages into a
# real .deb using repack-firmware-package.sh (host dpkg-deb; no chroot, no
# execution of package contents). Exists so the ~320M of pinned .debs don't
# need to live in git -- they are regenerable from the firmware instead.
#
# The package set was pinned from UNASPRO.al324.v5.1.33 (the newest v5.1.x
# build still served by the firmware API as of 2026-09-13); its packages are
# version-identical to the original v5.1.31 image this project started from
# (unifi-drive 4.3.10, unifi-core 5.1.132, node24 24.8.0, ...).
#
# Requires: bash, wget, python3, dpkg-deb, and unsquashfs (Debian package
# `squashfs-tools`). binwalk is NOT used -- the squashfs offset is located
# directly.
#
# Usage:
#   scripts/fetch-firmware-debs.sh
#
# Environment overrides:
#   FW_URL        download URL (default: the pinned v5.1.33 image)
#   FW_FILE       local firmware path (default fw-download/UNASPRO-5.1.33.bin)
#   SQUASHFS_ROOT extracted rootfs (default fw_extract/UNASPRO-5.1.33/squashfs-root)
#   UNSQUASHFS    path to unsquashfs if not on PATH
#
# After running, the debs are NOT tracked by git. Re-verify any provisioned
# device with UNAS-CloudKey/05-verify.sh before trusting the new set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FW_VERSION="v5.1.33+44ce47b"
FW_SHA256="0d711a42b68649bf2a9e129123211e59896d8b29860d85c8c43b4e98d2c59d66"
FW_URL="${FW_URL:-https://fw-download.ubnt.com/data/unifi-drive/7a07-UNASPRO-5.1.33-10b23dea-e891-4699-bd66-3ecff7f954db.bin}"
FW_FILE="${FW_FILE:-$PROJECT_DIR/fw-download/UNASPRO-5.1.33.bin}"
SQUASHFS_ROOT="${SQUASHFS_ROOT:-$PROJECT_DIR/fw_extract/UNASPRO-5.1.33/squashfs-root}"
DEBS_DIR="$PROJECT_DIR/fw_picked/debs-build"
PKG_LIST="$PROJECT_DIR/fw_picked/debs-build.packages"
UNSQUASHFS="${UNSQUASHFS:-unsquashfs}"

log() { echo "[fetch-debs] $*"; }
fail() { echo "[fetch-debs] ERROR: $*" >&2; exit 1; }

require_tools() {
    command -v wget >/dev/null 2>&1 || fail "wget not found"
    command -v python3 >/dev/null 2>&1 || fail "python3 not found"
    command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb not found"
    command -v "$UNSQUASHFS" >/dev/null 2>&1 || \
        fail "unsquashfs not found (install the 'squashfs-tools' package, or set UNSQUASHFS=/path/to/unsquashfs)"
    [[ -f "$PKG_LIST" ]] || fail "package list not found: $PKG_LIST"
    [[ -f "$SCRIPT_DIR/repack-firmware-package.sh" ]] || fail "repack-firmware-package.sh not found next to this script"
}

download_firmware() {
    if [[ -f "$FW_FILE" ]] && echo "$FW_SHA256  $FW_FILE" | sha256sum -c - >/dev/null 2>&1; then
        log "using existing verified firmware: $FW_FILE"
        return 0
    fi
    log "downloading $FW_VERSION -> $FW_FILE"
    mkdir -p "$(dirname "$FW_FILE")"
    wget -q --show-progress -O "$FW_FILE.tmp" "$FW_URL" || fail "download failed"
    mv "$FW_FILE.tmp" "$FW_FILE"
    if ! echo "$FW_SHA256  $FW_FILE" | sha256sum -c - >/dev/null 2>&1; then
        fail "sha256 mismatch for $FW_FILE -- expected $FW_SHA256 (wrong/updated image? re-pin FW_URL/FW_SHA256/FW_VERSION in this script)"
    fi
    log "  OK: sha256 matches pinned $FW_VERSION"
}

extract_rootfs() {
    if [[ -f "$SQUASHFS_ROOT/var/lib/dpkg/status" ]]; then
        log "using existing extraction: $SQUASHFS_ROOT"
        return 0
    fi
    local offset
    offset="$(python3 - "$FW_FILE" <<'PYEOF'
import sys
# squashfs superblock magic, little-endian 'hsqs'
magic = b'hsqs'
with open(sys.argv[1], 'rb') as f:
    prev = b''
    base = 0
    while True:
        buf = f.read(1 << 20)
        if not buf:
            break
        window = prev + buf
        i = window.find(magic)
        if i >= 0:
            print(base - len(prev) + i)
            sys.exit(0)
        prev = window[-len(magic):]
        base += len(buf)
sys.exit(1)
PYEOF
)" || fail "no squashfs ('hsqs') found in $FW_FILE"

    log "extracting squashfs at offset $offset -> $SQUASHFS_ROOT"
    rm -rf "$SQUASHFS_ROOT"
    mkdir -p "$(dirname "$SQUASHFS_ROOT")"
    "$UNSQUASHFS" -o "$offset" -d "$SQUASHFS_ROOT" "$FW_FILE" >/dev/null
    [[ -f "$SQUASHFS_ROOT/var/lib/dpkg/status" ]] || fail "extraction produced no dpkg status -- offset/format wrong?"
}

repack_all() {
    log "repacking $(wc -l < "$PKG_LIST") package(s) into $DEBS_DIR"
    mkdir -p "$DEBS_DIR"
    rm -f "$DEBS_DIR"/*.deb
    local failed=0 pkg
    while read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if ! "$SCRIPT_DIR/repack-firmware-package.sh" "$pkg" "$SQUASHFS_ROOT" >/dev/null 2>&1; then
            log "  FAIL: $pkg (not in this firmware image, or repack error)"
            failed=$((failed + 1))
        fi
    done < "$PKG_LIST"
    local built
    built="$(find "$DEBS_DIR" -maxdepth 1 -name '*.deb' | wc -l)"
    log "built $built .deb(s)"
    if (( failed > 0 )); then
        fail "$failed package(s) failed to repack"
    fi
}

main() {
    require_tools
    download_firmware
    extract_rootfs
    repack_all
    log "done. Verify the device with UNAS-CloudKey/05-verify.sh before trusting the new set."
}

if ! (return 0 2>/dev/null); then
    main "$@"
fi
