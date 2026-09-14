#!/bin/bash
# Caller-differentiated ubnt-tools `id` wrapper. Installed as /sbin/ubnt-tools
# (real binary moved to /sbin/ubnt-tools.real).
#
# v1 reported spoofed NAS (UNAS2B) identity to every caller, which unifi-drive
# requires: an unrecognized "UCKP" model degrades PoolEditor and defaults new
# pools to ext4 instead of btrfs. But that also made unifi-core's console page,
# firmware update-check, and uos's app-installer catalog see NAS identity --
# blocking genuine Cloud Key firmware updates and native apps.
#
# v2 answers differently by caller. unifi-core caches identity once at its own
# process startup; unifi-drive and uos re-read it fresh per call. Serving
# genuine identity to everyone except unifi-drive is therefore invisible to
# unifi-drive.
#
# **This wrapper requires the frame-aware relay
# (drive-hardware-relay-v3-frameaware.py) to be installed too**, or
# unifi-drive's networkInterfaces goes null.
#
# CALLER DETECTION: unifi-drive, ucs-update and ulp-go invoke `ubnt-tools id`
# via `sudo -u root` as their own service user, so `$SUDO_USER` identifies
# them. unifi-core is the trap: its cap.conf drop-in sets User=root, so it is
# already root and $SUDO_USER is "root" or empty. Checking the grandparent's
# `comm` is a timing trap -- Node.js renames its process title after this call
# fires, so at call-time it still reads "MainThread". Check the grandparent's
# `cmdline` ("/usr/share/unifi-core/app/service.js") or, more robustly, the
# calling PID's systemd cgroup ("/uos.slice/unifi-core.service"), which is
# stable for the process's whole life and covers both the sudo and direct-exec
# call patterns.
#
# WHO SEES WHAT:
#   - unifi-drive (SUDO_USER=unifi-drive): NAS-spoofed, load-bearing. Do not
#     change this branch without understanding the PoolEditor crash it fixes.
#   - unifi-core (SUDO_USER=root and grandparent cmdline service.js, or
#     unifi-core.service cgroup): genuine.
#   - ucs-update (SUDO_USER=ucs-update, or no SUDO_USER with parent comm
#     unifi-identity-update-app): genuine; a pure component auto-update checker
#     (credential-server/ucs-agent/unifi-directory) with no references to
#     /opt/ubnthal or the kernel/HAL layer.
#   - ulp-go (SUDO_USER=ulp-go, its own sudoers grant): genuine, so its
#     /api/v2/info board.sysid stays consistent with unifi-core.
#   - uos, called directly as root with no SUDO_USER: genuine; this is what
#     makes `uos runnable install`/`latest-versions` see real entitlements.
#   - Everything else, including interactive root `sudo ubnt-tools id` or an
#     unrecognized parent: NAS-spoofed (the safe default matching this
#     project's tooling assumptions).
#
# The four substituted lines MUST match the kernel/HAL layer
# (/opt/ubnthal/{board,system.info}, currently 0xea72/UNAS2B/UNAS-2-B) for the
# NAS branch; a mismatch is exactly the WebSocket/render crash this wrapper
# fixes. If the kernel-layer spoof changes sysid, update the sed substitutions
# in the same session. Genuine values are always the real binary's own
# unmodified output, never hand-typed, so a dropped-field crash-loop cannot
# recur on that branch.

CMD=$(basename "$0")
if [[ "$CMD" == "ubnt-tools" && "$1" == "id" ]]; then
    real_out=$(exec -a ubnt-tools /sbin/ubnt-tools.real id) || exit $?

    if [[ "$SUDO_USER" == "unifi-drive" ]]; then
        echo "$real_out" | sed \
            -e 's/^board\.sysid=.*/board.sysid=0xea72/' \
            -e 's/^board\.name=.*/board.name=UNAS 2/' \
            -e 's/^board\.shortname=.*/board.shortname=UNAS2B/' \
            -e 's/^board\.storename=.*/board.storename=UNAS-2-B/'
        exit 0
    fi

    if [[ "$SUDO_USER" == "ucs-update" ]]; then
        echo "$real_out"
        exit 0
    fi

    # ulp-go (identity/SSO service, port 9080) has its own sudoers grant and
    # calls this directly as its service user. Treat it as genuine so its
    # /api/v2/info board.sysid stays consistent with unifi-core.
    if [[ "$SUDO_USER" == "ulp-go" ]]; then
        echo "$real_out"
        exit 0
    fi

    # unifi-core: its cap.conf drop-in sets User=root, so it calls this either
    # directly (no SUDO_USER) or through sudo as "root". `comm` is a timing
    # trap because Node.js renames its process title after this startup call.
    # Match via systemd cgroup instead -- stable for the process's whole life
    # and covering both call patterns.
    is_unifi_core_cgroup() {
        local pid="$1"
        [[ -n "$pid" ]] || return 1
        grep -q 'unifi-core\.service' "/proc/$pid/cgroup" 2>/dev/null
    }

    if [[ -z "$SUDO_USER" ]]; then
        PARENT_COMM=$(cat "/proc/$PPID/comm" 2>/dev/null)
        if [[ "$PARENT_COMM" == "uos" || "$PARENT_COMM" == unifi-identity-update* ]]; then
            echo "$real_out"
            exit 0
        fi
        if is_unifi_core_cgroup "$PPID"; then
            echo "$real_out"
            exit 0
        fi
    fi

    if [[ "$SUDO_USER" == "root" ]]; then
        GPPID=$(awk '{print $4}' "/proc/$PPID/stat" 2>/dev/null)
        GP_CMDLINE=$(tr '\0' ' ' < "/proc/$GPPID/cmdline" 2>/dev/null)
        if [[ "$GP_CMDLINE" == *"/usr/share/unifi-core/app/service.js"* ]] \
            || is_unifi_core_cgroup "$GPPID"; then
            echo "$real_out"
            exit 0
        fi
    fi

    # Default (safe): NAS-spoofed for every unrecognized caller.
    echo "$real_out" | sed \
        -e 's/^board\.sysid=.*/board.sysid=0xea72/' \
        -e 's/^board\.name=.*/board.name=UNAS 2/' \
        -e 's/^board\.shortname=.*/board.shortname=UNAS2B/' \
        -e 's/^board\.storename=.*/board.storename=UNAS-2-B/'
    exit 0
fi
exec -a "$CMD" /sbin/ubnt-tools.real "$@"
