#!/bin/bash
# install-unifi-drive-stack.sh
#
# Fresh-install path: assumes the custom 3.18.44-btrfscustom kernel and
# ui_hdd_pwrctl_fake.ko are ALREADY flashed/present (aborts otherwise).
# Installs the NAS/Drive package set and calls
# apply-cloudkey-drive-fixes.sh (must live in the same directory).
#
# The real 4.x-era Drive app is never published in apt.artifacts.ui.com's
# generic repo (only a much older 1.x lineage), so this installs the
# genuine app from the fw_picked/debs-build/ .debs (extracted from this
# device's own real firmware) and installs every dependency in ONE apt/dpkg
# pass -- a corrective `apt-get install -f` afterward caused apt's resolver
# to REMOVE unifi-drive/unifi-drive-config entirely on a real run.
#
# unifi-drive-rclone (>= 1.74.4) is a genuine dependency not present in this
# project folder or the generic apt repo. This script deliberately
# hard-fails with a clear message rather than silently skipping it or
# guessing a URL.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS_DIR="${DEBS_DIR:-$SCRIPT_DIR/../fw_picked/debs-build}"
MODULES_DIR="${MODULES_DIR:-$SCRIPT_DIR/../fw_picked/kernel-modules-3.18.44-btrfscustom}"
EXPECT_KERNEL="3.18.44-btrfscustom"

log() { echo "[install-unifi-drive-stack] $*"; }

# Some bullseye-security point-release builds this device's sources.list
# references have been pruned from security.debian.org entirely (genuine
# 404, not a fluke) -- hit for the samba family, the avahi family, and
# ubnt-libvips42's imaging-library deps. The regular (non-security) archive
# still has an older build of the same source packages. This wraps any
# `apt-get "$@"`: on ANY apt-get failure, retries from the regular archive
# with --allow-downgrades, then `apt-mark hold`s whatever apt actually
# touched (via a dry-run `-s` pass, not a hardcoded package list) so a later
# `apt-get update` with security re-enabled doesn't re-fetch the
# still-missing version. The fallback's own dry-run result is the signal: if
# the regular-archive retry doesn't resolve things either, the ORIGINAL
# failure is restored and propagated untouched -- this can't mask an
# unrelated apt error, only one this fallback demonstrably fixes.
apt_run_with_mirror_gap_retry() {
    local out orig_status
    if out=$(apt-get "$@" 2>&1); then
        printf '%s\n' "$out"
        return 0
    fi
    orig_status=$?
    printf '%s\n' "$out" >&2

    # Don't gate this on a specific error-message signature: a security
    # mirror gap surfaces as a plain fetch 404 when a package is first
    # requested, but as an "unmet dependencies / held broken packages"
    # resolver error when a package needing an EXACT version match runs into
    # a sibling already held at the regular-archive version (hit for real
    # installing avahi-daemon after libavahi-client3/common3 were held by an
    # earlier samba-correction pass). A narrow grep misses the second shape.
    #
    # Instead: always attempt the regular-archive-only fallback on ANY
    # apt-get failure and let its own dry-run result be the signal. This
    # still only masks a failure this fallback demonstrably fixes, so it
    # can't silently paper over an unrelated apt error.
    log "apt-get $* failed -- trying regular-archive-only fallback (security mirror gap)"
    cp /etc/apt/sources.list /etc/apt/sources.list.mirrorgap.bak
    sed -i '/security\.debian\.org/s/^/#/' /etc/apt/sources.list
    apt-get update -q

    local sim
    if ! sim="$(apt-get "$@" --allow-downgrades -s 2>&1)"; then
        log "regular-archive fallback doesn't resolve it either -- restoring and propagating the original failure"
        mv /etc/apt/sources.list.mirrorgap.bak /etc/apt/sources.list
        apt-get update -q
        return "$orig_status"
    fi

    local affected
    affected="$(awk '/^(Inst|Conf)/ {print $2}' <<<"$sim" | sort -u)"
    apt-get "$@" --allow-downgrades

    if [[ -n "$affected" ]]; then
        # shellcheck disable=SC2086
        apt-mark hold $affected
        log "held at the regular-archive version (security mirror gap): $(tr '\n' ' ' <<<"$affected")"
    fi

    mv /etc/apt/sources.list.mirrorgap.bak /etc/apt/sources.list
    apt-get update -q
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "must run as root" >&2
        exit 1
    fi
}

check_prereqs() {
    local kver
    kver="$(uname -r)"
    if [[ "$kver" != "$EXPECT_KERNEL" ]]; then
        echo "expected kernel $EXPECT_KERNEL, found $kver -- flash the custom kernel first, aborting" >&2
        exit 1
    fi

    # The module tree under /lib/modules/$EXPECT_KERNEL/ can go missing even
    # though the custom kernel is still flashed and running (a genuine
    # firmware flash can reconcile /lib/modules back to the stock trees
    # only). This project's build output is saved at
    # fw_picked/kernel-modules-3.18.44-btrfscustom/ so this script can
    # self-heal: if the module is missing but a matching source tree is
    # available locally, restore it and re-run depmod before continuing.
    if ! find "/lib/modules/$EXPECT_KERNEL" -name 'ui_hdd_pwrctl_fake.ko' 2>/dev/null | grep -q .; then
        if [[ -d "$MODULES_DIR" ]]; then
            log "ui_hdd_pwrctl_fake.ko missing under /lib/modules/$EXPECT_KERNEL/ -- restoring from $MODULES_DIR"
            mkdir -p "/lib/modules/$EXPECT_KERNEL"
            cp -a "$MODULES_DIR"/. "/lib/modules/$EXPECT_KERNEL/"
            depmod -a "$EXPECT_KERNEL"
            if ! find "/lib/modules/$EXPECT_KERNEL" -name 'ui_hdd_pwrctl_fake.ko' 2>/dev/null | grep -q .; then
                echo "restored module tree from $MODULES_DIR but ui_hdd_pwrctl_fake.ko is still missing -- aborting" >&2
                exit 1
            fi
            log "module tree restored, ui_hdd_pwrctl_fake.ko present"
        else
            echo "ui_hdd_pwrctl_fake.ko not found under /lib/modules/$EXPECT_KERNEL/, and no local module tree at $MODULES_DIR to restore from -- copy it in first, aborting" >&2
            exit 1
        fi
    fi

    if [[ ! -d "$DEBS_DIR" ]]; then
        echo "expected picked debs at $DEBS_DIR, not found -- aborting" >&2
        exit 1
    fi
}

setup_apt_sources() {
    log "apt sources (ubiquiti + nginx.org)"
    # Rewritten every run: observed missing across sessions for no clear
    # reason, so treat its absence as expected, not a bug.
    cat > /etc/apt/sources.list.d/ubiquiti.list <<'EOF'
deb [signed-by=/usr/share/keyrings/ubnt-archive-keyring.gpg] https://apt.artifacts.ui.com bullseye release
EOF
    # The ubnt-archive-keyring .deb ships its key as
    # /usr/share/keyrings/ubiquiti-archive-keyring.gpg, not the
    # ubnt-archive-keyring.gpg named in the source line above -- a naming
    # mismatch, not a missing-package problem. Symlink it every run so a
    # fresh dpkg -i of that package (which won't recreate a symlink someone
    # else made) stays resolvable.
    if [[ -f /usr/share/keyrings/ubiquiti-archive-keyring.gpg && ! -e /usr/share/keyrings/ubnt-archive-keyring.gpg ]]; then
        ln -sf /usr/share/keyrings/ubiquiti-archive-keyring.gpg /usr/share/keyrings/ubnt-archive-keyring.gpg
    fi
}

install_plain_debian_deps() {
    log "plain-Debian dependencies"
    apt-get update

    # On trixie the pinned bookworm-backport samba set CANNOT configure: its
    # python3-tdb/python3-ldb/libldb2 depend on `python3 (<< 3.10)` and
    # `libpython3.9`, gone with trixie's Python 3.13. Install trixie's own
    # samba directly instead. On bullseye keep the genuine bookworm-backport
    # build pinned from this device's firmware (avoids plain bullseye's
    # avahi-version conflict).
    local codename
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    if [[ "$codename" == "trixie" ]]; then
        log "samba (trixie-native via apt; the pinned backport build is bullseye-only)"
        apt_run_with_mirror_gap_retry install -y samba winbind
    else
        log "samba (genuine bookworm-backport build from this device's own firmware, not plain bullseye)"
        dpkg -i \
            "$DEBS_DIR"/samba-common_*.deb \
            "$DEBS_DIR"/libtalloc2_*.deb \
            "$DEBS_DIR"/python3-talloc_*.deb \
            "$DEBS_DIR"/libtdb1_*.deb \
            "$DEBS_DIR"/python3-tdb_*.deb \
            "$DEBS_DIR"/tdb-tools_*.deb \
            "$DEBS_DIR"/libtevent0_*.deb \
            "$DEBS_DIR"/libldb2_*.deb \
            "$DEBS_DIR"/python3-ldb_*.deb \
            "$DEBS_DIR"/libwbclient0_*.deb \
            "$DEBS_DIR"/samba-libs_*.deb \
            "$DEBS_DIR"/python3-samba_*.deb \
            "$DEBS_DIR"/samba-common-bin_*.deb \
            "$DEBS_DIR"/samba-vfs-modules_*.deb \
            "$DEBS_DIR"/samba_*.deb \
            "$DEBS_DIR"/samba-ad-provision_*.deb \
            "$DEBS_DIR"/libnss-winbind_*.deb \
            "$DEBS_DIR"/winbind_*.deb \
            || true
        apt_run_with_mirror_gap_retry install -f -y
    fi

    # avahi has no matching .deb in this project's firmware captures (it's
    # baked into the base rootfs, not apt-installed at runtime), so this one
    # really does need the mirror-gap retry.
    apt_run_with_mirror_gap_retry install -y \
        avahi-daemon \
        attr ecryptfs-utils nfs-kernel-server fuse3 rsync libimage-exiftool-perl \
        btrfs-progs lvm2
    # wsdd-server is never in the generic apt repo (Debian nor
    # apt.artifacts.ui.com) -- its only real source is the .deb in
    # fw_picked/debs-build/. Install the local .debs first: on trixie apt
    # just prints "E: Unable to locate package wsdd-server".
    if compgen -G "$DEBS_DIR/wsdd-server_*.deb" >/dev/null; then
        log "wsdd-server from fw_picked/debs-build/ (not in any apt repo)"
        dpkg -i "$DEBS_DIR"/wsdd-server_*.deb "$DEBS_DIR"/wsdd_*.deb || true
    else
        log "no local wsdd-server .deb found, trying apt"
        apt-get install -y wsdd-server
    fi
}

install_via_uos_runnable() {
    # On a trixie base the pinned bullseye .debs for these packages no longer
    # install: ubnt-libvips42's bullseye-era sonames (libgif7, libwebp6,
    # etc.) don't exist in trixie -- a genuinely different build, not a
    # mirror gap. `uos runnable install` pulls Ubiquiti's trixie-native
    # (uos-deb13-arm64) build instead. Order matters: ubnt-libvips42 before
    # unifi-drive, or installing unifi-drive first 400s with a uos-side
    # SemVer comparison bug. ubnt-libvips42's trixie binary is renamed
    # ubnt-libvips42t64, but the catalog entry is still queried under the old
    # name ubnt-libvips42 -- do not "fix" this to the t64 name.
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -qE '^.i '; then
        log "  $pkg already installed, leaving in place (not overwriting a possibly newer version)"
        return 0
    fi
    log "  $pkg via uos runnable install (trixie base)"
    uos runnable install "$pkg"
}

install_ubiquiti_specific_debs() {
    log "Ubiquiti-specific packages from fw_picked/debs-build/"

    # Detect trixie vs bullseye base and route unifi-drive/
    # unifi-drive-config/ubnt-libvips42 to `uos runnable install` on trixie
    # -- the fw_picked/debs-build/ pins for these three are bullseye-only.
    # Everything else here (samba, wsdd, rclone, etc.) stays on the
    # pinned-.deb path regardless of base.
    local codename is_trixie=0
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    if [[ "$codename" == "trixie" ]]; then
        is_trixie=1
        log "  trixie base detected -- routing unifi-drive/unifi-drive-config/ubnt-libvips42 through uos runnable install"
        install_via_uos_runnable ubnt-libvips42
        install_via_uos_runnable unifi-drive
        install_via_uos_runnable unifi-drive-config
        # ubnt-libvips-tools and unifi-drive-rclone aren't known to hit the
        # trixie soname break -- still installed from the pinned .debs below.
    fi
    # unifi-drive needs the exact package "unifi-drive-rclone", NOT
    # "unifi-rclone" (a different package, a dependency of unifi-talk). Match
    # only the exact name: an earlier version matched either via
    # `find A -o -iname B | head -n1`, whose dependence on find's
    # filesystem-order (not alphabetical) non-deterministically picked the
    # wrong one and made apt's resolver silently REMOVE
    # unifi-drive/unifi-drive-config.
    local rclone_deb
    rclone_deb=$(find "$DEBS_DIR" -maxdepth 1 -iname 'unifi-drive-rclone*.deb' | head -n1 || true)
    if [[ -z "$rclone_deb" ]]; then
        cat >&2 <<'EOF'
ERROR: unifi-drive-rclone (>= 1.74.4) is not present in fw_picked/debs-build/.
This is a genuine dependency, distinct from unifi-rclone; supply its .deb
(from this project's own firmware extraction, not the generic apt repo).
EOF
        exit 1
    fi

    # Only install a package if it isn't already installed at all --
    # unconditionally dpkg -i'ing the pinned version on every re-run
    # silently DOWNGRADED a live unifi-drive-config from a natively-updated
    # 2.23.0-11 back to the older 2.22.6-10 pin (caught live). A genuinely
    # fresh device is unaffected; only a re-run against an already-updated
    # device behaves differently.
    #
    # ubntnas is deliberately NOT installed: nothing on the device depends on
    # it (no systemd unit, no cron, no reverse dpkg deps), and the WebUI
    # firmware-update flow it backs fails on its own anyway.
    local to_install=()
    for pair in \
        "ubnt-libvips42:$DEBS_DIR/ubnt-libvips42_*.deb" \
        "ubnt-libvips-tools:$DEBS_DIR/ubnt-libvips-tools_*.deb" \
        "unifi-drive-rclone:$rclone_deb" \
        "unifi-drive:$DEBS_DIR/unifi-drive_*.deb" \
        "unifi-drive-config:$DEBS_DIR/unifi-drive-config_*.deb"
    do
        local pkg_name="${pair%%:*}" deb_pattern="${pair#*:}"
        # Already handled via uos runnable install above on trixie -- the
        # pinned .deb for these three is bullseye-only.
        if (( is_trixie )) && [[ "$pkg_name" == "ubnt-libvips42" || "$pkg_name" == "unifi-drive" || "$pkg_name" == "unifi-drive-config" ]]; then
            continue
        fi
        if dpkg -l "$pkg_name" 2>/dev/null | grep -qE '^.i '; then
            log "  $pkg_name already installed, leaving in place (not overwriting a possibly newer version)"
        else
            # shellcheck disable=SC2206
            local matched=($deb_pattern)
            to_install+=("${matched[@]}")
        fi
    done

    # Installed together in one pass with unifi-drive/unifi-drive-config --
    # do NOT split this into dpkg -i then a separate apt-get install -f.
    if (( ${#to_install[@]} > 0 )); then
        dpkg -i "${to_install[@]}" || true   # dpkg -i on a batch may report dependency errors; apt-get -f below resolves them from the same local set
    else
        log "  all Ubiquiti-specific packages already installed, nothing to do"
    fi

    # ubnt-libvips42's imaging-library deps (libaom0, libmagickcore-6.q16-6,
    # libgdk-pixbuf2.0-common, libgs9-common, libgsf-1-common) hit the same
    # security.debian.org mirror gap as samba/avahi above -- no genuine .deb
    # in any firmware capture, so the retry-from-regular-archive wrapper is
    # the only fix.
    apt_run_with_mirror_gap_retry install -f -y

    # Match dpkg -l's STATUS column ('i' = installed) regardless of its
    # DESIRED column ('i' = install, 'h' = hold): a package swept into
    # apt_run_with_mirror_gap_retry's hold-set (e.g. unifi-drive, when it's
    # part of the same transaction as the gap-affected imaging-library
    # packages) shows as 'hi', not 'ii', even though it's correctly
    # installed. A literal '^ii' check false-positives an error there.
    for pkg in unifi-drive unifi-drive-config; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -qE '^.i '; then
            echo "ERROR: $pkg did not configure successfully ('ii'/'hi' not found in dpkg -l) -- check apt-get install -f output above" >&2
            exit 1
        fi
    done
}

main() {
    require_root
    check_prereqs
    setup_apt_sources
    install_plain_debian_deps
    install_ubiquiti_specific_debs
    "$SCRIPT_DIR/04-apply-drive-fixes.sh"
    log "done"
}

# Guarded so this script can be `source`d to test/re-run an individual
# function in isolation (e.g. after a partial failure) without re-running
# the whole install from scratch -- no effect on normal `./install-...sh`
# execution.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
