#!/bin/bash
# repack-firmware-package.sh
#
# Rebuilds an installable .deb for a package that genuinely shipped inside
# the extracted firmware image (fw_extract/) but was never picked into
# fw_picked/debs-build/ during the original extraction pass. Does NOT
# execute any of the package's own files (no chroot, no qemu-user-static
# needed even for arm64 binaries) -- it only reads metadata + copies bytes
# out of the firmware's own dpkg database, then calls the host's native
# dpkg-deb to wrap them. Safe to run on any host architecture.
#
# Background: this is how wsdd, wsdd-server, unifi-rclone, and
# unifi-drive-rclone were recovered -- all four were installed in the original
# firmware image (/var/lib/dpkg/status confirms it) but fw_picked/debs-build/
# never got a copy of them.
#
# Usage:
#   scripts/repack-firmware-package.sh <package-name> [extracted-root]
#
# extracted-root defaults to fw_extract/fwupdate.bin.extracted/squashfs-root
# relative to this script's parent directory. Output lands in
# fw_picked/debs-build/<package>_<version>_<arch>.deb.
#
# What this does NOT handle (check by hand for these before trusting the
# result -- see the printed control file and file list for a sanity check):
#   - Packages using triggers (Triggers-Pending/Triggers-Awaited) --
#     uncommon for firmware-bundled leaf packages, not seen in this project
#     so far.
#   - Packages whose full doc/changelog/man files were pruned from the
#     firmware image at build time (harmless to skip -- purely
#     documentation -- but this script will print a warning per missing
#     file rather than silently continuing, so you notice).

set -euo pipefail

PKG="${1:?usage: repack-firmware-package.sh <package-name> [extracted-root]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQ="${2:-$SCRIPT_DIR/../fw_extract/fwupdate.bin.extracted/squashfs-root}"
OUT_DIR="$SCRIPT_DIR/../fw_picked/debs-build"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

STATUS="$SQ/var/lib/dpkg/status"
INFO_DIR="$SQ/var/lib/dpkg/info"

[[ -f "$STATUS" ]] || { echo "ERROR: $STATUS not found -- is extracted-root correct?" >&2; exit 1; }

CONTROL_STANZA=$(awk -v pkg="$PKG" '
    $0 == "Package: " pkg { found=1 }
    found { print }
    found && /^$/ { exit }
' "$STATUS")

[[ -n "$CONTROL_STANZA" ]] || { echo "ERROR: no status stanza found for $PKG" >&2; exit 1; }

VERSION=$(echo "$CONTROL_STANZA" | sed -n 's/^Version: //p')
ARCH=$(echo "$CONTROL_STANZA" | sed -n 's/^Architecture: //p')
[[ -n "$VERSION" && -n "$ARCH" ]] || { echo "ERROR: could not parse Version/Architecture for $PKG" >&2; exit 1; }

# Multi-Arch: same packages keep their dpkg info files arch-suffixed
# (e.g. libubnt:arm64.list); single-arch packages use the bare name.
info_file() {
    local suffix="$1" f
    f="$INFO_DIR/$PKG.$suffix"
    [[ -f "$f" ]] && { echo "$f"; return 0; }
    f="$INFO_DIR/$PKG:$ARCH.$suffix"
    [[ -f "$f" ]] && { echo "$f"; return 0; }
    return 1
}

LISTFILE="$(info_file list || true)"
[[ -n "$LISTFILE" ]] || { echo "ERROR: no file list found for $PKG (looked for $PKG.list and $PKG:$ARCH.list)" >&2; exit 1; }

PKGROOT="$BUILD_DIR/$PKG"
mkdir -p "$PKGROOT/DEBIAN"

while read -r p; do
    [[ "$p" == "/." || "$p" == "/" ]] && continue
    src="$SQ$p"
    dst="$PKGROOT$p"
    if [[ -d "$src" ]]; then
        mkdir -p "$dst"
    elif [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    else
        echo "WARNING: $p listed but missing from firmware image (likely pruned docs/man at build time) -- skipping" >&2
    fi
done < "$LISTFILE"

# control fields dpkg-deb needs, minus dpkg-runtime-only fields (Status).
echo "$CONTROL_STANZA" | grep -v '^Status:' > "$PKGROOT/DEBIAN/control"

# Maintainer scripts + conffiles, if this package has any.
for extra in conffiles postinst preinst postrm prerm; do
    extra_src="$(info_file "$extra" || true)"
    if [[ -n "$extra_src" ]]; then
        cp "$extra_src" "$PKGROOT/DEBIAN/$extra"
        [[ "$extra" != "conffiles" ]] && chmod 0755 "$PKGROOT/DEBIAN/$extra"
    fi
done

mkdir -p "$OUT_DIR"
# Debian filename convention drops the epoch (the "N:" prefix on Version,
# if any) from the filename -- dpkg-deb doesn't care either way since the
# real Package/Version come from the control file, not the filename, but
# match convention (and avoid a literal ':' in the filename) anyway.
FILENAME_VERSION="${VERSION#*:}"
OUT_FILE="$OUT_DIR/${PKG}_${FILENAME_VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKGROOT" "$OUT_FILE"

echo
echo "Built: $OUT_FILE"
echo "Review before trusting:"
dpkg-deb -I "$OUT_FILE"
