#!/bin/bash
# Installed as /usr/local/sbin/ui-hdd-pwrctl-sync.sh.
#
# ui_hdd_pwrctl_fake defaults every configured slot to present=1 on load
# regardless of what's actually plugged in. This script makes bay presence
# reflect reality: enumerate USB-attached disks, assign them to slot-1..slot-N
# in a stable order, mark the rest absent.
#
# Run at boot (After=systemd-modules-load.service, Before=uhwd.service
# usd.service -- so the daemons see correct presence on their first scan) and
# on every block-device add/remove via a udev rule that fires this via
# `systemd-run --no-block`.
#
# SAFETY: never call `systemctl restart uhwd` synchronously from inside this
# script. The boot service is ordered Before=uhwd.service, so a synchronous
# restart deadlocks on its own start transaction (it can't return until uhwd
# starts, which can't happen until this script's service finishes). Always
# detach it via `systemd-run --no-block`, exactly like the udev rule already
# detaches invocations of this script itself -- a transient unit has no
# ordering relationship with whatever unit is running this script, so it can
# never deadlock on it.
#
# SAFETY: the unit that runs this script must set `DefaultDependencies=no`.
# Otherwise systemd's implicit After=sysinit.target/basic.target combines with
# this unit's Before=uhwd.service/usd.service to form an ordering cycle, and
# systemd breaks it by deleting usd.service/start -- usd never runs and the
# storage pool is never assembled.

set -euo pipefail

PWRCTL=/sys/devices/platform/ui-hdd-pwrctl
LOCK=/run/ui-hdd-pwrctl-sync.lock

exec 9>"$LOCK"
flock -n 9 || exit 0

[[ -d "$PWRCTL" ]] || { echo "ui-hdd-pwrctl-sync: $PWRCTL missing, is ui_hdd_pwrctl_fake loaded?" >&2; exit 1; }

max_slots=$(find "$PWRCTL" -maxdepth 1 -name 'slot-*' | wc -l)
(( max_slots > 0 )) || { echo "ui-hdd-pwrctl-sync: no slot-* entries under $PWRCTL" >&2; exit 1; }

# Enumerate USB-attached disks, sorted by udev ID_PATH for a stable
# per-USB-port ordering. Excludes mmcblk0/zram automatically since neither
# matches sd*, and internal SATA/eMMC disks won't have "-usb-" in ID_PATH.
mapfile -t usb_disks < <(
    for dev in /sys/block/sd*; do
        [[ -e "$dev" ]] || continue
        name=$(basename "$dev")
        id_path=$(udevadm info -q property -n "$name" 2>/dev/null | sed -n 's/^ID_PATH=//p')
        [[ "$id_path" == *-usb-* ]] || continue
        echo "$id_path $name"
    done | sort | awk '{print $2}'
)

changed=0
for ((n=1; n<=max_slots; n++)); do
    slot="$PWRCTL/slot-$n"
    [[ -d "$slot" ]] || continue
    dev="${usb_disks[$((n-1))]:-}"
    want=$([[ -n "$dev" ]] && echo 1 || echo 0)
    have=$(cat "$slot/present" 2>/dev/null || echo "")
    if [[ "$have" != "$want" ]]; then
        echo "$want" > "$slot/present"
        changed=1
    fi
done

if (( changed )) && systemctl is-active --quiet uhwd; then
    systemd-run --no-block --quiet --unit=ui-hdd-pwrctl-sync-uhwd-restart -- systemctl restart uhwd
fi
