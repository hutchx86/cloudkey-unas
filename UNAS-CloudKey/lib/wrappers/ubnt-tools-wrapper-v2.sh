#!/bin/bash
# Caller-differentiated ubnt-tools `id` wrapper, installed as /sbin/ubnt-tools
# (real binary at /sbin/ubnt-tools.real). Requires the frame-aware relay too,
# or unifi-drive's networkInterfaces goes null.
#
# unifi-drive needs NAS (UNAS2B) spoofing; unifi-core, ucs-update, ulp-go and
# uos need genuine identity or firmware updates/apps break. Answer by caller.

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

    # ulp-go (identity/SSO, port 9080): own sudoers grant; genuine to keep its
    # /api/v2/info board.sysid consistent with unifi-core.
    if [[ "$SUDO_USER" == "ulp-go" ]]; then
        echo "$real_out"
        exit 0
    fi

    # unifi-core: cap.conf sets User=root, so no SUDO_USER (or root). Match via
    # systemd cgroup -- `comm` is a timing trap, as Node renames its process title.
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
