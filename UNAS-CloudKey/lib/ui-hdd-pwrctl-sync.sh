#!/bin/bash
# Installed as /usr/local/sbin/ui-hdd-pwrctl-sync.sh: reconciles ui_hdd_pwrctl_fake's
# all-present slots with real USB bay presence (stable slot-1..N by ID_PATH); runs
# at boot before uhwd/usd and on udev add/remove.
# SAFETY: restart uhwd only via `systemd-run --no-block` (a synchronous restart
# deadlocks on boot ordering); set DefaultDependencies=no or cycles delete usd.service/start.

set -euo pipefail

PWRCTL=/sys/devices/platform/ui-hdd-pwrctl
LOCK=/run/ui-hdd-pwrctl-sync.lock

exec 9>"$LOCK"
flock -n 9 || exit 0

[[ -d "$PWRCTL" ]] || { echo "ui-hdd-pwrctl-sync: $PWRCTL missing, is ui_hdd_pwrctl_fake loaded?" >&2; exit 1; }

max_slots=$(find "$PWRCTL" -maxdepth 1 -name 'slot-*' | wc -l)
(( max_slots > 0 )) || { echo "ui-hdd-pwrctl-sync: no slot-* entries under $PWRCTL" >&2; exit 1; }

# USB disks, stable per-port order via ID_PATH; sd* and "-usb-" filter out mmcblk/zram/SATA.
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
