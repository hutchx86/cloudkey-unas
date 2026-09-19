#!/bin/bash
# repack-firmware-package.sh -- rebuild an installable .deb for a package that
# shipped inside the extracted firmware image but was never picked into
# fw_picked/debs-build/. Reads metadata + copies bytes from the firmware's own
# dpkg database and wraps them with the host's dpkg-deb. Does NOT execute any of
# the package's files (no chroot/qemu, even for arm64); safe on any host arch.
#
# Usage:    scripts/repack-firmware-package.sh <package-name> [extracted-root]
# Default:  extracted-root is fw_extract/fwupdate.bin.extracted/squashfs-root
#           (relative to this script's parent dir); output goes to
#           fw_picked/debs-build/<package>_<version>_<arch>.deb.
#
# NOT handled (check by hand -- the printed control file/list shows a sanity
# check): packages using triggers, and doc/changelog/man files pruned from the
# image (harmless; each missing file prints a warning rather than being silent).

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

# Multi-Arch: same packages arch-suffix their dpkg info files (e.g. libubnt:arm64.list); single-arch use the bare name.
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
# Debian convention drops the Version epoch ("N:") from the filename; dpkg-deb reads version from control, but match convention (and avoid ':' in the name).
FILENAME_VERSION="${VERSION#*:}"
OUT_FILE="$OUT_DIR/${PKG}_${FILENAME_VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKGROOT" "$OUT_FILE"

echo
echo "Built: $OUT_FILE"
echo "Review before trusting:"
dpkg-deb -I "$OUT_FILE"
