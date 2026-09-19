#!/bin/bash
# provision-all.sh -- orchestrator, run from this project's environment after the custom
# 3.18.44-btrfscustom kernel has been built (01) and flashed (02) BY HAND. A bad =y build
# already bricked this device once, so building/flashing is never automated here.
# Syncs 03/04 + lib/ + fw_picked/ to the device, runs 03 remotely (which calls 04), reboots,
# waits for a confirmed fresh boot, then verifies with 05. Auth uses lib/ssh_master.py
# (pty ControlMaster) since this environment has no sshpass/expect.
# Usage: DEVICE_HOST=root@<ip> DEVICE_PASSWORD='...' UNAS-CloudKey/provision-all.sh
# Env: SSH_CONTROL_SOCKET (default /tmp/ck_ssh_ctrl.sock), REMOTE_DIR (default
# /root/cloudkey-unas-provision). Does NOT create the first pool (WebUI action).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE_HOST="${DEVICE_HOST:?set DEVICE_HOST, e.g. root@<cloudkey-ip>}"
DEVICE_PASSWORD="${DEVICE_PASSWORD:?set DEVICE_PASSWORD (used only to (re-)establish the SSH ControlMaster)}"
SSH_CONTROL_SOCKET="${SSH_CONTROL_SOCKET:-/tmp/ck_ssh_ctrl.sock}"
REMOTE_DIR="${REMOTE_DIR:-/root/cloudkey-unas-provision}"
EXPECT_KERNEL="3.18.44-btrfscustom"

# A full boot takes ~40-50s until unifi-core/nginx are ready; polling early is safe (a down
# device refuses at TCP level, before sshd auth, so it can't trigger PerSourcePenalties).
REBOOT_WAIT_BEFORE_POLLING_SECS=20
REBOOT_WAIT_MAX_SECS=900
REBOOT_POLL_INTERVAL_SECS=10
# REBOOT_WAIT_BEFORE_POLLING_SECS lets `reboot` take effect before polling; a reconnect
# is only trusted as a fresh boot if /proc/uptime is below this (catches the OLD session).
FRESH_BOOT_MAX_UPTIME_SECS=600

log() { echo "[provision-all] $*"; }
fail() { echo "[provision-all] ERROR: $*" >&2; exit 1; }

ssh_dev() { ssh -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" "$@"; }

# Idempotent: ssh_master.py removes a stale socket and re-authenticates fresh. Non-fatal --
# returns the underlying status so a polling caller can tell "not up yet" from a real failure.
try_establish_control_socket() {
    python3 "$SCRIPT_DIR/lib/ssh_master.py" "$DEVICE_HOST" "$DEVICE_PASSWORD" "$SSH_CONTROL_SOCKET" >/dev/null 2>&1
}

establish_control_socket() {
    log "establishing SSH ControlMaster to $DEVICE_HOST"
    if ! try_establish_control_socket; then
        fail "could not establish SSH ControlMaster to $DEVICE_HOST -- if this just followed a dropped connection, do NOT retry rapidly (sshd's PerSourcePenalties can lock out both this and the user's own session at once); wait it out or power-cycle the device's PoE port instead."
    fi
}

check_kernel_already_flashed() {
    log "checking the custom kernel is already flashed on $DEVICE_HOST"
    local kver
    kver="$(ssh_dev uname -r)"
    if [[ "$kver" != "$EXPECT_KERNEL" ]]; then
        cat >&2 <<EOF
ERROR: $DEVICE_HOST is running kernel '$kver', expected '$EXPECT_KERNEL'.
Building and flashing the custom kernel is a deliberate manual step in
this project, not something this script automates (a bad =y build already
bricked this device once). Run 01-build-kernel.sh (inside the chroot, see
00-create-chroot.sh) and 02-flash-kernel.sh by hand, then re-run this script.
EOF
        exit 1
    fi
    log "  OK: $kver"
}

ensure_remote_rsync() {
    # Stock UniFi firmware lacks rsync, needed by this script's sync, 03's module restore, and 02's install.
    if ssh_dev "command -v rsync >/dev/null 2>&1"; then
        return 0
    fi
    log "rsync missing on $DEVICE_HOST (stock firmware lacks it) -- installing via apt"
    ssh_dev "apt-get update -qq && apt-get install -y rsync" || fail "could not install rsync on $DEVICE_HOST"
}

sync_artifacts() {
    local modules_dir="$PROJECT_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL"
    log "syncing UNAS-CloudKey/ + fw_picked/debs-build/ to $DEVICE_HOST:$REMOTE_DIR"
    ssh_dev "mkdir -p '$REMOTE_DIR/UNAS-CloudKey/lib/wrappers' '$REMOTE_DIR/fw_picked/debs-build'"
    # --chown=root:root avoids preserving source numeric uid/gid (which can map to a real Drive
    # user); mirror the local layout so 03's $SCRIPT_DIR/../fw_picked/... defaults resolve.
    rsync -e "ssh -S $SSH_CONTROL_SOCKET" -a --chown=root:root --exclude 'ssh_master.py' \
        "$SCRIPT_DIR/" "$DEVICE_HOST:$REMOTE_DIR/UNAS-CloudKey/"
    rsync -e "ssh -S $SSH_CONTROL_SOCKET" -a --chown=root:root \
        "$PROJECT_DIR/fw_picked/debs-build/" "$DEVICE_HOST:$REMOTE_DIR/fw_picked/debs-build/"
    # The module tree only exists after a local kernel build; on a re-provision from a fresh
    # clone there's nothing to send, and 03 uses the device's existing /lib/modules/$EXPECT_KERNEL/.
    if [[ -d "$modules_dir" ]]; then
        log "syncing kernel module tree $modules_dir"
        ssh_dev "mkdir -p '$REMOTE_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL'"
        rsync -e "ssh -S $SSH_CONTROL_SOCKET" -a --chown=root:root \
            "$modules_dir/" "$DEVICE_HOST:$REMOTE_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL/"
    else
        log "  NOTE: no local $modules_dir -- skipping module-tree sync; 03 will use the device's existing /lib/modules/$EXPECT_KERNEL/ (and abort there if it is missing)"
    fi
    ssh_dev "chmod +x '$REMOTE_DIR'/UNAS-CloudKey/*.sh '$REMOTE_DIR'/UNAS-CloudKey/lib/*.sh '$REMOTE_DIR'/UNAS-CloudKey/lib/wrappers/*.sh '$REMOTE_DIR'/UNAS-CloudKey/lib/wrappers/*.py"
}

run_install() {
    log "running 03-install-drive-stack.sh on $DEVICE_HOST (this also calls 04-apply-drive-fixes.sh at the end)"
    ssh_dev "'$REMOTE_DIR/UNAS-CloudKey/03-install-drive-stack.sh'"
}

reboot_and_wait() {
    log "rebooting $DEVICE_HOST"
    # Backgrounded remotely so the reboot doesn't race the ssh command's own teardown.
    ssh_dev "nohup reboot >/dev/null 2>&1 & sleep 1" || true
    ssh -O exit -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" 2>/dev/null || true

    log "waiting ${REBOOT_WAIT_BEFORE_POLLING_SECS}s grace period for the reboot command to actually take effect"
    sleep "$REBOOT_WAIT_BEFORE_POLLING_SECS"

    local waited=$REBOOT_WAIT_BEFORE_POLLING_SECS
    local uptime_secs
    while (( waited < REBOOT_WAIT_MAX_SECS )); do
        if try_establish_control_socket; then
            # A successful connection isn't proof of a fresh boot -- it could be a reconnect to
            # the OLD session; confirm via /proc/uptime (a stale session shows hours/days).
            uptime_secs="$(ssh_dev "cut -d. -f1 /proc/uptime" 2>/dev/null || echo 999999)"
            if [[ "$uptime_secs" =~ ^[0-9]+$ ]] && (( uptime_secs < FRESH_BOOT_MAX_UPTIME_SECS )); then
                log "  SSH is back up after ~${waited}s (confirmed fresh boot, uptime ${uptime_secs}s)"
                return 0
            fi
            log "  connected, but uptime (${uptime_secs}s) looks like the pre-reboot session, not a fresh boot -- still waiting"
        fi
        sleep "$REBOOT_POLL_INTERVAL_SECS"
        waited=$((waited + REBOOT_POLL_INTERVAL_SECS))
    done

    fail "$DEVICE_HOST did not come back over SSH with a confirmed fresh boot within ${REBOOT_WAIT_MAX_SECS}s -- well past the established normal boot time, treat as a real problem, not just slow."
}

main() {
    establish_control_socket
    check_kernel_already_flashed
    ensure_remote_rsync
    sync_artifacts
    run_install
    reboot_and_wait
    # Reuse the existing control socket -- source 05-verify.sh rather than exec it, so
    # verify_final_state() runs against the same DEVICE_HOST/SSH_CONTROL_SOCKET without reconnecting.
    # shellcheck source=05-verify.sh
    source "$SCRIPT_DIR/05-verify.sh"
    verify_final_state
}

# Guarded so this script can be `source`d to re-run one step in isolation; no effect on normal execution.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
