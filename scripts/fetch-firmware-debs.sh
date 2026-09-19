#!/bin/bash
# fetch-firmware-debs.sh -- rebuild fw_picked/debs-build/ from Ubiquiti's UNAS2
# firmware: checksum-verify the pinned image, extract its squashfs rootfs (offset
# located directly, no binwalk), then repack every package in debs-build.packages
# via repack-firmware-package.sh (host dpkg-deb; no chroot, no package execution).
#
# Requires: bash, wget, python3, dpkg-deb, unsquashfs (`squashfs-tools`).
# Usage:    scripts/fetch-firmware-debs.sh
#
# Environment overrides:
#   FW_URL        download URL (default: the pinned UNAS2 6.0.9 image)
#   FW_FILE       local firmware path (default fw-download/UNAS2-6.0.9.bin)
#   SQUASHFS_ROOT extracted rootfs (default fw_extract/UNAS2-6.0.9/squashfs-root)
#   UNSQUASHFS    path to unsquashfs if not on PATH
#
# The debs are not tracked by git; re-verify with UNAS-CloudKey/05-verify.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FW_VERSION="UNAS2-6.0.9+ebb4e934"
FW_SHA256="b5c08497fe64ac278c6fa5c4c015098e76d282d0497760d4df0bf5884269423a"
FW_URL="${FW_URL:-https://fw-download.ubnt.com/data/unifi-drive/e4da-UNAS2-6.0.9-ebb4e934-573a-4ddb-9f62-2712429f1c20.bin}"
FW_FILE="${FW_FILE:-$PROJECT_DIR/fw-download/UNAS2-6.0.9.bin}"
SQUASHFS_ROOT="${SQUASHFS_ROOT:-$PROJECT_DIR/fw_extract/UNAS2-6.0.9/squashfs-root}"
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
    log "repacking $(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$PKG_LIST") package(s) into $DEBS_DIR"
    mkdir -p "$DEBS_DIR"
    rm -f "$DEBS_DIR"/*.deb
    local failed=0 pkg
    while read -r pkg; do
        [[ -z "$pkg" || "$pkg" == \#* ]] && continue
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
