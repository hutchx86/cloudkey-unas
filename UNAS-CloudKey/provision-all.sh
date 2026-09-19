#!/bin/bash
# provision-all.sh
#
# Orchestrator: run from THIS PROJECT'S OWN environment (not on the device
# itself) once the custom 3.18.44-btrfscustom kernel has ALREADY been built
# (01-build-kernel.sh) and flashed (02-flash-kernel.sh) by hand -- that stays
# the one deliberate manual step: a bad =y build already bricked this device
# once, so this script never automates building/flashing it. Everything else
# after that is this one command: sync 03-install-drive-stack.sh +
# 04-apply-drive-fixes.sh + lib/ + fw_picked/ onto the device, run
# 03-install-drive-stack.sh remotely (which itself calls
# 04-apply-drive-fixes.sh at the end), reboot, wait for the device to come
# back, and verify the final state via 05-verify.sh.
#
# This environment has no sshpass/expect/pexpect, so authentication goes
# through lib/ssh_master.py's pty-based ControlMaster helper -- this script
# drives that itself (establishing it fresh before syncing, and again after
# the reboot, since the control socket dies with the device). You still need
# the device's root password.
#
# Usage:
#   DEVICE_HOST=root@10.10.10.61 DEVICE_PASSWORD='...' \
#       UNAS-CloudKey/provision-all.sh
#
# Optional env vars: SSH_CONTROL_SOCKET (default /tmp/ck_ssh_ctrl.sock --
# keep it short, AF_UNIX path limit, see lib/ssh_master.py), REMOTE_DIR
# (default /root/cloudkey-unas-provision).
#
# Does NOT do: build/flash the kernel (manual, see above -- 01/02), or
# first-time pool creation (a WebUI action for a device with no existing
# pool -- "Add Drives"/PoolEditor has to be clicked through once by a human;
# there is no pool yet to verify on a truly fresh device, see 05-verify.sh's
# pool-mount check).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE_HOST="${DEVICE_HOST:?set DEVICE_HOST, e.g. root@10.10.10.61}"
DEVICE_PASSWORD="${DEVICE_PASSWORD:?set DEVICE_PASSWORD (used only to (re-)establish the SSH ControlMaster)}"
SSH_CONTROL_SOCKET="${SSH_CONTROL_SOCKET:-/tmp/ck_ssh_ctrl.sock}"
REMOTE_DIR="${REMOTE_DIR:-/root/cloudkey-unas-provision}"
EXPECT_KERNEL="3.18.44-btrfscustom"

# A full boot under the UNAS2B kernel/HAL identity spoof normally takes
# ~40-50s until unifi-core/nginx are ready (was ~5-7 min before the
# num_slots=1 boot-time fix in 04-apply-drive-fixes.sh). Polling early is
# safe: a connection attempt against a device that's still down is refused at
# the TCP level and never reaches sshd's auth stage, so it can't trigger
# sshd's PerSourcePenalties backoff (which only tracks failed auth attempts
# against a live sshd). REBOOT_WAIT_BEFORE_POLLING_SECS is a short grace
# period for the `reboot` command to take effect -- without it, an immediate
# poll can reconnect to the OLD, not-yet-dead SSH session and falsely report
# "it's back". reboot_and_wait() also checks /proc/uptime to confirm a
# genuinely fresh boot. Give up well past the high end of the normal range so
# a genuinely stuck boot is reported as a real problem.
REBOOT_WAIT_BEFORE_POLLING_SECS=20
REBOOT_WAIT_MAX_SECS=900
REBOOT_POLL_INTERVAL_SECS=10
# A fresh boot's /proc/uptime must be below this to be trusted as genuine.
# Wide on purpose: only needs to catch a reconnect to a session up for
# hours/days, not tightly bound the normal boot window.
FRESH_BOOT_MAX_UPTIME_SECS=600

log() { echo "[provision-all] $*"; }
fail() { echo "[provision-all] ERROR: $*" >&2; exit 1; }

ssh_dev() { ssh -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" "$@"; }

# Idempotent: ssh_master.py always removes a stale socket file first and
# re-authenticates fresh, so this is safe to call whether or not a socket
# already exists. Non-fatal on its own -- returns the underlying exit
# status so a caller in a polling loop (the device isn't up yet, which is
# expected and NOT an error) can tell that apart from establish_control_socket()
# below's fatal use at the start of the run.
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
    # Stock UniFi firmware does NOT ship rsync. This script's artifact sync,
    # 03's module restore, and 02-flash-kernel.sh's module install all use it,
    # so a genuinely fresh device would otherwise fail here.
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
    # --chown=root:root: rsync -a otherwise preserves the source's numeric
    # uid/gid, which on the device can coincidentally map to a real, unrelated
    # Drive user account. Harmless over ssh (always root), but avoid leaving
    # misleading ownership on the device. Mirror the local sibling layout
    # (UNAS-CloudKey/ + fw_picked/ under $REMOTE_DIR) so 03's
    # $SCRIPT_DIR/../fw_picked/... defaults resolve correctly.
    rsync -e "ssh -S $SSH_CONTROL_SOCKET" -a --chown=root:root --exclude 'ssh_master.py' \
        "$SCRIPT_DIR/" "$DEVICE_HOST:$REMOTE_DIR/UNAS-CloudKey/"
    rsync -e "ssh -S $SSH_CONTROL_SOCKET" -a --chown=root:root \
        "$PROJECT_DIR/fw_picked/debs-build/" "$DEVICE_HOST:$REMOTE_DIR/fw_picked/debs-build/"
    # The kernel module tree is optional: it only exists after a kernel build
    # in this checkout. On a re-provision of an already-flashed device from a
    # fresh clone there is nothing local to send, and 03 uses whatever is
    # already under the device's /lib/modules/$EXPECT_KERNEL/ (it only needs
    # the local tree as a self-heal source when that is missing). Syncing a
    # non-existent dir would otherwise abort the whole run under `set -e`.
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
    # backgrounded on the remote end so the reboot itself doesn't race the
    # ssh command's own connection teardown.
    ssh_dev "nohup reboot >/dev/null 2>&1 & sleep 1" || true
    ssh -O exit -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" 2>/dev/null || true

    log "waiting ${REBOOT_WAIT_BEFORE_POLLING_SECS}s grace period for the reboot command to actually take effect"
    sleep "$REBOOT_WAIT_BEFORE_POLLING_SECS"

    local waited=$REBOOT_WAIT_BEFORE_POLLING_SECS
    local uptime_secs
    while (( waited < REBOOT_WAIT_MAX_SECS )); do
        if try_establish_control_socket; then
            # A successful connection alone isn't proof of a genuine fresh
            # boot -- it could be a reconnect to the OLD session if the
            # `reboot` command hadn't actually torn it down yet. Confirm via
            # /proc/uptime: a stale old session shows hours/days, an easy,
            # huge gap against any plausible fresh-boot uptime.
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
    # Reuse the control socket we already have -- source 05-verify.sh
    # rather than exec-ing it, so its verify_final_state() call runs
    # against the same DEVICE_HOST/SSH_CONTROL_SOCKET without needing to
    # re-establish a connection (and without needing DEVICE_PASSWORD again).
    # shellcheck source=05-verify.sh
    source "$SCRIPT_DIR/05-verify.sh"
    verify_final_state
}

# Guarded so this script can be `source`d to test/re-run an individual
# step in isolation without running the whole provisioning flow -- no
# effect on normal `./provision-all.sh` execution, same pattern as
# 03-install-drive-stack.sh and 04-apply-drive-fixes.sh.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
