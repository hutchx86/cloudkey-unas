#!/bin/bash
# apply-cloudkey-drive-fixes.sh
#
# Idempotent fix layer for a genuine UniFi Cloud Key G2 Plus running the
# real UniFi Drive stack. Assumes unifi-drive, unifi-drive-config, nginx,
# smartmontools, and the ui_hdd_pwrctl_fake kernel module are ALREADY
# installed (see install-unifi-drive-stack.sh). Safe to re-run any time --
# every step below checks state before changing anything.
#
# Step 4b installs a caller-differentiated ubnt-tools wrapper: unifi-core/
# uos/ulp-go see genuine Cloud Key identity (unlocking the WebUI update flow
# and native app installs), while unifi-drive gets the NAS-spoofed default.
# **4b and 4c are a package deal -- installing the wrapper without 4c's
# relay breaks unifi-drive's networkInterfaces field (proven live).** 4c
# deploys a frame-aware network relay for unifi-drive's own connection to
# unifi-core, rewriting just the hardware/model fields back to NAS-spoofed.
#
# The old "leave ubnt-tools genuine" split made unifi-drive's per-model
# lookup see console.model:"UCKP" and crash PoolEditor + silently default
# new pools to ext4; matching ubnt-tools id to the same UNAS2B/0xea72
# identity as the kernel/HAL layer fixes both.
#
# A firmware-update /etc/hosts block was considered and deliberately
# rejected: a genuine OTA wiping the custom kernel is an accepted outcome,
# since this project's own scripts are the recovery path for exactly that.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[apply-cloudkey-drive-fixes] $*"; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "must run as root" >&2
        exit 1
    fi
}

# --- 1. mkfs.btrfs sectorsize wrapper ---------------------------------------
fix_mkfs_btrfs_wrapper() {
    log "mkfs.btrfs sectorsize wrapper"
    if [[ ! -f /sbin/mkfs.btrfs.real ]]; then
        cp -a /sbin/mkfs.btrfs /sbin/mkfs.btrfs.real
    fi
    install -m 0755 "$SCRIPT_DIR/lib/wrappers/mkfs-btrfs-wrapper.sh" /sbin/mkfs.btrfs
}

# --- 2. mount space_cache=v2 wrapper -----------------------------------------
fix_mount_wrapper() {
    log "mount space_cache=v2-stripping wrapper"
    if [[ ! -f /bin/mount.real ]]; then
        cp -a /bin/mount /bin/mount.real
    fi
    install -m 0755 "$SCRIPT_DIR/lib/wrappers/mount-wrapper.sh" /bin/mount
}

# --- 3. ui_hdd_pwrctl_fake module config + live sync + units ---------------
fix_bay_presence() {
    log "ui_hdd_pwrctl_fake config + bay-presence sync"

    install -m 0755 "$SCRIPT_DIR/lib/ui-hdd-pwrctl-sync.sh" /usr/local/sbin/ui-hdd-pwrctl-sync.sh

    # num_slots was previously 2 to match usd's hardcoded UNAS2B bay-count
    # table, but usd/Drive reports its bay count from a separate hardcoded
    # table keyed by board identity, unaffected by num_slots. The stock
    # uscsi-disk-ready.service does read this module's slot count and waits
    # up to 300s per empty configured slot, so num_slots=2 cost ~5 minutes
    # on every cold boot on this single-bay hardware. num_slots=1 matches
    # the real hardware and cut boot from ~6m20s to ~51s, with no effect on
    # Drive (still reports 2 bays via the identity spoof below).
    cat > /etc/modprobe.d/ui-hdd-pwrctl-fake.conf <<'EOF'
options ui_hdd_pwrctl_fake num_slots=1
EOF

    # /etc/modules-load.d/ does NOT persist across reboots on this device;
    # the stock autoload conf files live in /lib/modules-load.d/ instead.
    # Use that, matching the format of the neighboring ubnthal.conf.
    cat > /lib/modules-load.d/ui-hdd-pwrctl-fake.conf <<'EOF'
ui_hdd_pwrctl_fake
EOF

    if ! lsmod | grep -q '^ui_hdd_pwrctl_fake'; then
        depmod -a
        modprobe ui_hdd_pwrctl_fake || log "WARNING: modprobe ui_hdd_pwrctl_fake failed -- is the .ko present under /lib/modules/$(uname -r)/?"
    fi

    # DefaultDependencies=no is REQUIRED, not cosmetic: with the default
    # (yes), systemd adds After=sysinit.target + After=basic.target to this
    # unit, but it is Before=uhwd.service/usd.service -- and those run
    # Before=local-fs.target, which is Before=sysinit.target/basic.target.
    # That closes an ordering cycle at boot, so systemd deletes the
    # usd.service/start job to break it: usd never runs, the md/LVM/btrfs
    # pool is never assembled, and Drive reports no storage until usd is
    # started by hand. CONFIRMED live 2026-09-14 (device up 7h with usd
    # dead and /proc/mdstat empty).
    cat > /etc/systemd/system/ui-hdd-pwrctl-sync.service <<'EOF'
[Unit]
Description=Sync ui_hdd_pwrctl_fake bay presence to real attached USB disks
DefaultDependencies=no
After=systemd-modules-load.service
Before=uhwd.service usd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ui-hdd-pwrctl-sync.sh

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/udev/rules.d/99-ui-hdd-pwrctl-sync.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{DEVTYPE}=="disk", RUN+="/bin/systemd-run --no-block /usr/local/sbin/ui-hdd-pwrctl-sync.sh"
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{DEVTYPE}=="disk", RUN+="/bin/systemd-run --no-block /usr/local/sbin/ui-hdd-pwrctl-sync.sh"
EOF

    udevadm control --reload-rules
    systemctl daemon-reload
    systemctl enable --now ui-hdd-pwrctl-sync.service
}

# --- 3b. ubnthal module autoload (changed from =y to =m 2026-09-05) --------
# ubnthal was built into the kernel image (=y) and needed no autoload config.
# It is now a loadable module (=m) so it can be rmmod'd on demand ahead of a
# genuine Cloud Key OS update via the WebUI -- with it unloaded, /proc/ubnthal
# disappears (matching real Cloud Key hardware) and unifi-core's update-check
# falls through to genuine ubnt-tools identity. This function only restores
# the *normal* always-on autoload; actually rmmod'ing it for an update is a
# separate, deliberate manual step, never something this fix script does on
# its own.
fix_ubnthal_module_autoload() {
    log "ubnthal module autoload (matches its old =y always-on behavior)"

    # Same non-persistence caveat as ui_hdd_pwrctl_fake -- /etc/modules-load.d/
    # does not survive a reboot on this device, /lib/modules-load.d/ does.
    cat > /lib/modules-load.d/ubnthal.conf <<'EOF'
ubnthal
EOF

    if ! lsmod | grep -q '^ubnthal'; then
        depmod -a
        modprobe ubnthal || log "WARNING: modprobe ubnthal failed -- is the .ko present under /lib/modules/$(uname -r)/? usd/uhwd will not see identity until this is fixed."
    fi
}

# --- 4. kernel/HAL identity spoof (leaves /sbin/ubnt-tools genuine) --------
# IMPORTANT: system.info's serialno/qrid get baked directly into usd's
# on-disk disk_super at pool creation time -- the values below match what
# this project's current pool has on-disk. If this function only touched
# sysid/shortname (as it used to), re-running it after ANYTHING resets
# serialno/qrid (a genuine-identity revert, a firmware update's own
# provisioning step) would silently leave the wrong values and risk a
# FOREIGN mismatch on the existing pool. Pin them explicitly for a complete,
# deterministic restoration of the exact identity this pool was created
# under.
#
# If a *different* pool is ever created after these values change
# deliberately, update SYSINFO_SERIALNO/SYSINFO_QRID here to match. These
# are NOT this device's genuine hardware values (board.serialno/board.qrid in
# the board file ARE genuine and untouched); system.info's are a legacy
# fabricated value carried forward since early in this project.
fix_kernel_hal_identity() {
    log "kernel/HAL identity spoof (UNAS2B, sysid 0xea72)"
    local board=/opt/ubnthal/board
    local sysinfo=/opt/ubnthal/system.info
    local sysinfo_serialno=9c05d6417ccd
    local sysinfo_qrid=HzQWwv

    if [[ ! -f "$board" || ! -f "$sysinfo" ]]; then
        log "WARNING: $board or $sysinfo missing -- skipping kernel/HAL identity spoof."
        log "         A firmware update that removes /opt/ubnthal (observed 2026-09-14 on a"
        log "         genuine UCKP v6.0.7 re-flash) leaves /proc/ubnthal/{board,system.info}"
        log "         empty. Drive still works because the userspace ubnt-tools wrapper spoofs"
        log "         NAS2B on its own, but the kernel/HAL identity source is"
        log "         gone -- restore /opt/ubnthal/ from a backup if it matters."
        return 0
    fi

    sed -i \
        -e 's/^board\.sysid=.*/board.sysid=0xea72/' \
        -e 's/^board\.name=.*/board.name=UNAS 2/' \
        -e 's/^board\.shortname=.*/board.shortname=UNAS2B/' \
        "$board"
    sed -i \
        -e 's/^systemid=.*/systemid=ea72/' \
        -e 's/^shortname=.*/shortname=UNAS2B/' \
        "$sysinfo"

    if grep -q '^serialno=' "$sysinfo"; then
        sed -i "s/^serialno=.*/serialno=${sysinfo_serialno}/" "$sysinfo"
    else
        echo "serialno=${sysinfo_serialno}" >> "$sysinfo"
    fi
    if grep -q '^qrid=' "$sysinfo"; then
        sed -i "s/^qrid=.*/qrid=${sysinfo_qrid}/" "$sysinfo"
    else
        echo "qrid=${sysinfo_qrid}" >> "$sysinfo"
    fi

    local actual_serialno actual_qrid
    actual_serialno=$(grep '^serialno=' "$sysinfo" | cut -d= -f2)
    actual_qrid=$(grep '^qrid=' "$sysinfo" | cut -d= -f2)
    if [[ "$actual_serialno" != "$sysinfo_serialno" || "$actual_qrid" != "$sysinfo_qrid" ]]; then
        log "ERROR: system.info serialno/qrid did not end up as expected after patch -- pool import may break, investigate before proceeding"
        return 1
    fi
}

# --- 4b. userspace identity spoof (ubnt-tools id -> caller-differentiated) --
# Installs the v2 wrapper (see lib/wrappers/ubnt-tools-wrapper-v2.sh for the
# caller-detection design): unifi-core/uos/ulp-go/ucs-update see genuine
# Cloud Key identity, unifi-drive and unrecognized callers see the
# NAS-spoofed default. v2 REQUIRES step 4c's relay too, or unifi-drive's
# networkInterfaces breaks -- main() below always runs both together.
fix_userspace_identity() {
    log "userspace identity spoof (ubnt-tools id -> caller-differentiated v2)"
    local real=/sbin/ubnt-tools.real

    if [[ -f "$real" ]]; then
        log "  /sbin/ubnt-tools.real already present, wrapper likely already installed -- reinstalling wrapper only"
    else
        cp -a /sbin/ubnt-tools "$real"
    fi

    install -m 0755 "$SCRIPT_DIR/lib/wrappers/ubnt-tools-wrapper-v2.sh" /sbin/ubnt-tools

    # Sanity check before returning control: the same two bugs v1 hit live
    # (missing fields crash-looping unifi-core, and argv0 dispatch on the
    # real binary) apply to v2's passthrough -- do not remove. This only
    # exercises the safe-default (NAS-spoofed) branch; confirming unifi-core/
    # uos receive genuine identity requires restarting them and checking
    # their own APIs (/api/system, ulp-go's /api/v2/info).
    local out
    out=$(/sbin/ubnt-tools id 2>&1) || { log "ERROR: ubnt-tools id failed after wrapper install: $out"; return 1; }
    if ! grep -q '^board\.serialno=' <<<"$out"; then
        log "ERROR: wrapper output missing board.serialno -- this crash-loops unifi-core, reverting"
        cp -a "$real" /sbin/ubnt-tools
        return 1
    fi
    if ! grep -q '^board\.sysid=0xea72$' <<<"$out"; then
        log "ERROR: wrapper output has wrong sysid (safe-default branch), reverting"
        cp -a "$real" /sbin/ubnt-tools
        return 1
    fi
}

# --- 4c. frame-aware relay for unifi-drive's connection to unifi-core ------
# Companion to 4b's v2 wrapper -- see
# lib/wrappers/drive-hardware-relay-v3-frameaware.py for the wire-protocol
# decode and why the relay must actually parse WS frames (a naive
# byte-substitution version corrupted the connection live). The systemd unit
# owns its own iptables rule's lifecycle (added on start, removed on stop)
# so the two can never be out of sync.
fix_drive_hardware_relay() {
    log "frame-aware Drive hardware-identity relay + iptables redirect"

    install -m 0755 "$SCRIPT_DIR/lib/wrappers/drive-hardware-relay-v3-frameaware.py" \
        /usr/local/sbin/drive-hardware-relay-v3.py
    install -m 0644 "$SCRIPT_DIR/lib/wrappers/drive-hardware-relay-v3.service" \
        /lib/systemd/system/drive-hardware-relay-v3.service

    # Ordering drop-in so unifi-drive doesn't race the relay/redirect at
    # boot (it would self-heal via its own reconnect loop either way).
    mkdir -p /lib/systemd/system/unifi-drive.service.d
    cat > /lib/systemd/system/unifi-drive.service.d/drive-hardware-relay-order.conf <<'EOF'
[Unit]
After=drive-hardware-relay-v3.service
Wants=drive-hardware-relay-v3.service
EOF

    systemctl daemon-reload
    systemctl enable --now drive-hardware-relay-v3.service

    if ! systemctl is-active --quiet drive-hardware-relay-v3.service; then
        log "ERROR: drive-hardware-relay-v3.service did not come up active"
        return 1
    fi
    if ! iptables -t nat -C OUTPUT -p tcp -m owner --uid-owner unifi-drive --dport 11081 -j REDIRECT --to-port 11090 2>/dev/null; then
        log "ERROR: expected iptables NAT redirect rule not present after relay start"
        return 1
    fi
}

# --- 5. nginx sub_filter compat patch + self-healing path-watcher ---------
fix_nginx_drive_proxy() {
    log "nginx Drive sub_filter compat patch + self-healing watcher"
    install -m 0755 "$SCRIPT_DIR/lib/patch-drive-ws-conf.sh" /usr/local/sbin/patch-drive-ws-conf.sh

    /usr/local/sbin/patch-drive-ws-conf.sh

    cat > /etc/systemd/system/drive-ws-conf-watch.path <<'EOF'
[Unit]
Description=Watch shared-runnable-drive.conf for unifi-core regeneration

[Path]
PathModified=/data/unifi-core/config/http/shared-runnable-drive.conf

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/drive-ws-conf-watch.service <<'EOF'
[Unit]
Description=Reapply Drive nginx compat patch after unifi-core regenerates its conf

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/patch-drive-ws-conf.sh
EOF

    systemctl daemon-reload
    systemctl enable --now drive-ws-conf-watch.path
}

# --- 6. missing unifi-drive-user-blocklist file -----------------------------
fix_missing_blocklist_file() {
    log "unifi-drive-user-blocklist placeholder file"
    mkdir -p /usr/share/unifi-os
    touch /usr/share/unifi-os/unifi-drive-user-blocklist
    chown root:root /usr/share/unifi-os/unifi-drive-user-blocklist
    chmod 644 /usr/share/unifi-os/unifi-drive-user-blocklist
}

# --- 7. smartctl drivedb USB-bridge patches ---------------------------------
# The exact genuine neighboring-entry format was fetched from a real
# device's own drivedb.h (a hand-maintained C array of struct literals), so
# the two entries below are built from that real structure, not guessed.
# Both VID:PID -> -d sat mappings are confirmed working on real hardware.
#
# Never edits the real file directly: stages the insertion into a /tmp copy,
# verifies with `smartctl -B <copy> -P showall` that the result still parses
# cleanly, and only then copies the verified result over the real file. If
# the anchor entry this looks for (RTL9210 / JMS561, from smartmontools'
# shipped drivedb.h) is missing or the post-edit parse check fails, the real
# file is left untouched and a specific warning is logged.
_drivedb_insert_after_anchor() {
    local file="$1" anchor="$2" block_file="$3"
    local anchor_line close_line
    anchor_line="$(grep -n -F "$anchor" "$file" | head -n1 | cut -d: -f1)"
    [[ -n "$anchor_line" ]] || return 1
    close_line="$(awk -v start="$anchor_line" 'NR>=start && /^  \},[[:space:]]*$/ {print NR; exit}' "$file")"
    [[ -n "$close_line" ]] || return 1
    sed -i "${close_line}r $block_file" "$file"
}

fix_smartctl_drivedb() {
    log "smartctl drivedb USB-bridge entries"
    local realtek_block jmicron_block
    realtek_block="$(mktemp)"
    jmicron_block="$(mktemp)"
    cat > "$realtek_block" <<'EOF'
  { "USB: ; Realtek RTL9201R",
    "0x0bda:0x9201",
    "",
    "",
    "-d sat"
  },
EOF
    cat > "$jmicron_block" <<'EOF'
  { "USB: ; JMicron",
    "0x152d:0xa580",
    "",
    "",
    "-d sat"
  },
EOF

    for db in /usr/share/smartmontools/drivedb.h /var/lib/smartmontools/drivedb/drivedb.h; do
        [[ -f "$db" ]] || continue

        local need_realtek=1 need_jmicron=1
        grep -q '"0x0bda:0x9201"' "$db" && need_realtek=0
        grep -q '"0x152d:0xa580"' "$db" && need_jmicron=0
        if [[ "$need_realtek" -eq 0 && "$need_jmicron" -eq 0 ]]; then
            log "  $db: both entries already present"
            continue
        fi

        local tmp ok=1
        tmp="$(mktemp)"
        cp "$db" "$tmp"

        if [[ "$need_realtek" -eq 1 ]]; then
            if _drivedb_insert_after_anchor "$tmp" '"0x0bda:0x9210"' "$realtek_block"; then
                log "  $db: staged Realtek RTL9201R (0x0bda:0x9201) entry"
            else
                log "  $db: WARNING RTL9210 anchor entry not found -- add the Realtek RTL9201R (0x0bda:0x9201 -> -d sat) entry manually"
                ok=0
            fi
        fi
        if [[ "$need_jmicron" -eq 1 ]]; then
            if _drivedb_insert_after_anchor "$tmp" '"0x152d:0x[8a]561"' "$jmicron_block"; then
                log "  $db: staged JMicron (0x152d:0xa580) entry"
            else
                log "  $db: WARNING JMS561 anchor entry not found -- add the JMicron (0x152d:0xa580 -> -d sat) entry manually"
                ok=0
            fi
        fi

        if [[ "$ok" -eq 1 ]] && ! smartctl -B "$tmp" -P showall >/dev/null 2>&1; then
            log "  $db: WARNING edited drivedb failed to parse with smartctl -- leaving the real file untouched"
            ok=0
        fi

        if [[ "$ok" -eq 1 ]]; then
            cp "$tmp" "$db"
            log "  $db: updated"
        fi
        rm -f "$tmp"
    done
    rm -f "$realtek_block" "$jmicron_block"
}

# unifi-core's bundled service.js hardcodes a per-console-model
# "controllers" table (one static object per hardware shortname, e.g.
# UCKP/Cloud Key Plus), and Cloud Key's entry never includes "drive" -- a
# stock Cloud Key was never meant to run it. This table is the ONLY source
# of the app list unifi-core accepts for whole-console backup RESTORE:
# `POST /api/backup/settings/restore/<id>`'s `applicationsToRestore` is a
# zod enum built from this exact array at request time. Restoring "drive"
# from a real backup 400'd with an "invalid_enum_value" naming the
# console's controllers list with "drive" absent -- NOT a
# version-compatibility check, and not fixable by matching app versions.
#
# Fix: add a {name:"drive",updatable:true} entry to that same array.
# Verified live end-to-end: after this patch + restarting unifi-core, a real
# backup's "drive" component restored successfully.
#
# FRAGILITY WARNING, more than this script's other fixes: service.js is a
# minified bundle Ubiquiti rebuilds (with fresh, non-deterministic minified
# variable names) on every unifi-core release. The literal 7-controller
# sequence below was confirmed unique (exactly one match) in the build live
# on this device at patch time; it will very likely need re-deriving
# (re-grep the live service.js for a controllers array containing
# "innerspace" and "apollo") after any future unifi-core update. Same
# safety pattern as fix_smartctl_drivedb(): stage on a temp copy, verify
# with `node24 --check` before ever touching the real file, warn and leave
# the real file untouched if the anchor isn't found or the patched file
# fails to parse.
fix_unifi_core_drive_controller() {
    log "unifi-core UCKP controllers table (drive backup-restore support)"
    local svc=/usr/share/unifi-core/app/service.js
    [[ -f "$svc" ]] || { log "  $svc not found -- skipping"; return; }

    if grep -q '{name:"apollo",updatable:true,hidden:true},{name:"drive",updatable:true}' "$svc"; then
        log "  already patched"
        return
    fi

    # Anchor/replacement written to temp FILES rather than interpolated
    # into a python -c string as bash variables -- both contain literal
    # double quotes ({name:"network",...}), which would otherwise break
    # out of the shell-quoted -c argument and corrupt the script.
    local anchor_file replacement_file
    anchor_file="$(mktemp)"
    replacement_file="$(mktemp)"
    printf '%s' '{name:"network",updatable:true},{name:"protect",updatable:true},{name:"access",updatable:true},{name:"talk",updatable:true},{name:"connect",updatable:true},{name:"innerspace",updatable:true},{name:"apollo",updatable:true,hidden:true}' > "$anchor_file"
    printf '%s' '{name:"network",updatable:true},{name:"protect",updatable:true},{name:"access",updatable:true},{name:"talk",updatable:true},{name:"connect",updatable:true},{name:"innerspace",updatable:true},{name:"apollo",updatable:true,hidden:true},{name:"drive",updatable:true}' > "$replacement_file"

    local count
    count="$(grep -o -F -f "$anchor_file" "$svc" | wc -l)"
    if [[ "$count" -ne 1 ]]; then
        log "  WARNING anchor controllers-array text found $count times (expected exactly 1, likely changed in a unifi-core update) -- leaving service.js untouched, patch drive support manually"
        rm -f "$anchor_file" "$replacement_file"
        return
    fi

    # node24 --check does ESM module-format detection by file EXTENSION, and
    # a bare `mktemp` filename has none -- it fails with
    # ERR_UNKNOWN_FILE_EXTENSION regardless of whether the JS content itself
    # is valid. `mktemp --suffix=.js` avoids it.
    local tmp
    tmp="$(mktemp --suffix=.js)"
    python3 - "$svc" "$anchor_file" "$replacement_file" "$tmp" <<'PYEOF'
import sys
svc_path, anchor_path, replacement_path, tmp_path = sys.argv[1:5]
with open(svc_path) as f:
    d = f.read()
with open(anchor_path) as f:
    anchor = f.read()
with open(replacement_path) as f:
    replacement = f.read()
d = d.replace(anchor, replacement, 1)
with open(tmp_path, 'w') as f:
    f.write(d)
PYEOF
    rm -f "$anchor_file" "$replacement_file"
    if ! node24 --check "$tmp" >/dev/null 2>&1; then
        log "  WARNING patched service.js failed to parse -- leaving the real file untouched"
        rm -f "$tmp"
        return
    fi

    cp "$svc" "$svc.backup-preDriveControllerPatch-$(date +%Y-%m-%d)"
    cp "$tmp" "$svc"
    rm -f "$tmp"
    log "  $svc: patched (backup saved alongside it), restart unifi-core to pick it up"
}

main() {
    require_root
    fix_mkfs_btrfs_wrapper
    fix_mount_wrapper
    fix_bay_presence
    fix_ubnthal_module_autoload
    fix_kernel_hal_identity
    fix_userspace_identity
    fix_drive_hardware_relay
    fix_nginx_drive_proxy
    fix_missing_blocklist_file
    fix_smartctl_drivedb
    fix_unifi_core_drive_controller
    log "done -- restart unifi-core, ulp-go, and unifi-drive (or reboot) for the identity changes to take effect"
}

# Guarded so this script can be `source`d to test/re-run an individual fix
# function in isolation without re-applying every fix -- no effect on
# normal `./apply-cloudkey-drive-fixes.sh` execution.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
