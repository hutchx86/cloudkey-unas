#!/bin/bash
# install-unifi-drive-stack.sh
#
# Fresh-install path: assumes the custom 3.18.44-btrfscustom kernel and
# ui_hdd_pwrctl_fake.ko are already present (aborts otherwise). Installs the
# real 4.x NAS/Drive app + deps in ONE apt/dpkg pass (a corrective
# `apt-get install -f` had apt's resolver REMOVE unifi-drive entirely) from
# fw_picked/debs-build/, then runs 04-apply-drive-fixes.sh (same directory).
# Runs on the device as root. Missing unifi-drive-rclone (>= 1.74.4) hard-fails.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS_DIR="${DEBS_DIR:-$SCRIPT_DIR/../fw_picked/debs-build}"
MODULES_DIR="${MODULES_DIR:-$SCRIPT_DIR/../fw_picked/kernel-modules-3.18.44-btrfscustom}"
EXPECT_KERNEL="3.18.44-btrfscustom"

log() { echo "[install-unifi-drive-stack] $*"; }

# Security-mirror gap: some bullseye-security point releases were pruned (real 404s; hit by samba/avahi/ubnt-libvips42-deps). On ANY apt-get failure, retry from the regular archive with --allow-downgrades and `apt-mark hold` what apt touched, so security updates don't re-fetch the missing version.
# The fallback's own dry-run decides, so it can't mask an unrelated apt error.
apt_run_with_mirror_gap_retry() {
    local out orig_status
    if out=$(apt-get "$@" 2>&1); then
        printf '%s\n' "$out"
        return 0
    fi
    orig_status=$?
    printf '%s\n' "$out" >&2

    # Don't gate on an error signature: the gap surfaces as a fetch 404 OR as an "unmet dependencies / held broken packages" resolver error, so a narrow grep misses the second shape.
    # Always attempt the fallback on any failure and let its own dry-run be the signal.
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

    # /lib/modules/$EXPECT_KERNEL/ can go missing while the custom kernel still runs (a flash can reconcile it to stock trees only); self-heal from the local fw_picked module tree and re-run depmod.
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
    # Rewritten every run: its absence was observed across sessions for no clear reason, so treat it as expected, not a bug.
    cat > /etc/apt/sources.list.d/ubiquiti.list <<'EOF'
deb [signed-by=/usr/share/keyrings/ubnt-archive-keyring.gpg] https://apt.artifacts.ui.com bullseye release
EOF
    # The ubnt-archive-keyring .deb ships its key as ubiquiti-archive-keyring.gpg,
    # not the ubnt-archive-keyring.gpg named above -- symlink it every run.
    if [[ -f /usr/share/keyrings/ubiquiti-archive-keyring.gpg && ! -e /usr/share/keyrings/ubnt-archive-keyring.gpg ]]; then
        ln -sf /usr/share/keyrings/ubiquiti-archive-keyring.gpg /usr/share/keyrings/ubnt-archive-keyring.gpg
    fi
}

install_plain_debian_deps() {
    log "plain-Debian dependencies"
    apt-get update

    # On trixie the pinned bookworm-backport samba CANNOT configure (its tdb/ldb deps
    # need python3.9, gone with Python 3.13), so use trixie's own; on bullseye keep the firmware pin.
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

    # avahi has no matching .deb in the firmware captures (baked into the base rootfs, not apt-installed), so it genuinely needs the mirror-gap retry.
    apt_run_with_mirror_gap_retry install -y \
        avahi-daemon \
        attr ecryptfs-utils nfs-kernel-server fuse3 rsync libimage-exiftool-perl \
        btrfs-progs lvm2
    # wsdd-server/wsdd are in no apt repo, so they come from fw_picked/. The
    # firmware's wsdd is a thin wrapper that Depends: wsdd2 (the daemon), which is
    # not pinned -- install wsdd2 from apt (trixie ships it) so wsdd configures
    # before the uos step below (uos needs wsdd).
    if compgen -G "$DEBS_DIR/wsdd-server_*.deb" >/dev/null; then
        log "wsdd-server + wsdd from fw_picked/debs-build/ (wsdd2 from apt)"
        apt_run_with_mirror_gap_retry install -y wsdd2
        dpkg -i "$DEBS_DIR"/wsdd-server_*.deb "$DEBS_DIR"/wsdd_*.deb || true
        apt_run_with_mirror_gap_retry install -f -y
    else
        log "no local wsdd-server .deb found, trying apt"
        apt-get install -y wsdd-server
    fi
}

install_via_uos_runnable() {
    # On trixie the pinned bullseye .debs won't install (ubnt-libvips42's sonames like libgif7/libwebp6 are gone), so `uos runnable install` pulls Ubiquiti's trixie-native uos-deb13-arm64 build instead.
    # Order matters: ubnt-libvips42 before unifi-drive (reverse 400s on a uos SemVer bug); query ubnt-libvips42 by that name even though its trixie binary is ubnt-libvips42t64.
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

    # On trixie route unifi-drive/unifi-drive-config/ubnt-libvips42 to `uos runnable
    # install` (their fw_picked .debs are bullseye-only); everything else stays pinned.
    local codename is_trixie=0
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    if [[ "$codename" == "trixie" ]]; then
        is_trixie=1
        log "  trixie base detected -- routing unifi-drive/unifi-drive-config/ubnt-libvips42 through uos runnable install"
        install_via_uos_runnable ubnt-libvips42
        install_via_uos_runnable unifi-drive
        install_via_uos_runnable unifi-drive-config
        # ubnt-libvips-tools/unifi-drive-rclone don't hit the trixie soname break; keep the pinned .debs below.
    fi
    # unifi-drive-rclone depends on unifi-rclone (>= 1.74.4), which is only in
    # fw_picked/debs-build/ (never in apt), so install it first. Match the exact
    # name "unifi-drive-rclone", NOT "unifi-rclone": a looser `find A -o -iname B`
    # picked the wrong .deb by filesystem order and made apt REMOVE unifi-drive.
    local rclone_deb unifi_rclone_deb
    rclone_deb=$(find "$DEBS_DIR" -maxdepth 1 -iname 'unifi-drive-rclone*.deb' | head -n1 || true)
    unifi_rclone_deb=$(find "$DEBS_DIR" -maxdepth 1 -iname 'unifi-rclone_*.deb' | head -n1 || true)
    if [[ -z "$rclone_deb" ]]; then
        cat >&2 <<'EOF'
ERROR: unifi-drive-rclone (>= 1.74.4) is not present in fw_picked/debs-build/.
This is a genuine dependency, distinct from unifi-rclone; supply its .deb
(from this project's own firmware extraction, not the generic apt repo).
EOF
        exit 1
    fi
    if [[ -z "$unifi_rclone_deb" ]]; then
        echo "ERROR: unifi-rclone is not present in fw_picked/debs-build/ -- unifi-drive-rclone depends on it and it is in no apt repo." >&2
        exit 1
    fi

    # Only install if not already installed: unconditionally dpkg -i'ing the pin on every
    # re-run silently DOWNGRADED a live, natively-updated unifi-drive-config (2.23.0-11 -> 2.22.6-10); a fresh device is unaffected.
    # ubntnas is deliberately NOT installed: nothing depends on it and the WebUI firmware-update flow it backs fails on its own.
    local to_install=()
    for pair in \
        "ubnt-libvips42:$DEBS_DIR/ubnt-libvips42_*.deb" \
        "ubnt-libvips-tools:$DEBS_DIR/ubnt-libvips-tools_*.deb" \
        "unifi-rclone:$unifi_rclone_deb" \
        "unifi-drive-rclone:$rclone_deb" \
        "unifi-drive:$DEBS_DIR/unifi-drive_*.deb" \
        "unifi-drive-config:$DEBS_DIR/unifi-drive-config_*.deb"
    do
        local pkg_name="${pair%%:*}" deb_pattern="${pair#*:}"
        # Already handled via uos runnable install on trixie (the pinned .debs are bullseye-only).
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

    # One pass with unifi-drive/unifi-drive-config -- do NOT split into dpkg -i then a separate apt-get install -f.
    if (( ${#to_install[@]} > 0 )); then
        dpkg -i "${to_install[@]}" || true   # dpkg -i on a batch may report dependency errors; apt-get -f below resolves them from the same local set
    else
        log "  all Ubiquiti-specific packages already installed, nothing to do"
    fi

    # ubnt-libvips42's imaging-library deps hit the same security.debian.org mirror gap as samba/avahi above (no genuine .deb in any firmware capture), so the retry wrapper is the only fix.
    apt_run_with_mirror_gap_retry install -f -y

    # Match dpkg -l's STATUS column ('i'), not DESIRED: packages swept into the mirror-gap
    # hold-set (e.g. unifi-drive) show as 'hi', not 'ii', though correctly installed -- a literal '^ii' check false-positives.
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

# Guarded so the script can be `source`d to re-run one function in isolation
# (e.g. after a partial failure) without repeating the whole install.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
