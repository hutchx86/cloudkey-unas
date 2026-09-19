#!/bin/bash
# 02-flash-kernel.sh -- back up the current boot partition (checksummed), transfer and
# hash-verify the new image BEFORE flashing, flash with sync, read back and verify, then
# install the module tree. Run from this project's environment (ssh/scp + local outputs).
# Usage: DEVICE_HOST=root@<ip> DEVICE_PASSWORD='...' \
#   ./02-flash-kernel.sh <new-boot.img> <modules-staging-dir>
# Env: SSH_CONTROL_SOCKET, BACKUP_DIR, KERNEL_VERSION, FLASH_CONFIRM=yes, BOOT_PARTITION
# (default /dev/mmcblk0p42 "boot"; NEVER /dev/mmcblk0p43 "recovery").
# Driven by install.sh (flash -> reboot -> provision); the "yes" prompt below is the one
# interactive step. Still NOT automated here: driver-safety review and loading the new
# module (files are installed but never insmod'd/modprobe'd).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NEW_BOOT_IMG="${1:?usage: $0 <path-to-new-boot.img> <modules-staging-dir>}"
MODULES_STAGING_DIR="${2:?usage: $0 <path-to-new-boot.img> <modules-staging-dir>}"

DEVICE_HOST="${DEVICE_HOST:?set DEVICE_HOST, e.g. root@<cloudkey-ip>}"
DEVICE_PASSWORD="${DEVICE_PASSWORD:?set DEVICE_PASSWORD (used only to establish the SSH ControlMaster)}"
SSH_CONTROL_SOCKET="${SSH_CONTROL_SOCKET:-/tmp/ck_ssh_ctrl.sock}"
BOOT_PARTITION="${BOOT_PARTITION:-/dev/mmcblk0p42}"
BACKUP_DIR="${BACKUP_DIR:-$(pwd)}"

log() { echo "[flash-kernel] $*"; }
fail() { echo "[flash-kernel] ERROR: $*" >&2; exit 1; }

ssh_dev() { ssh -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" "$@"; }

[[ -f "$NEW_BOOT_IMG" ]] || fail "$NEW_BOOT_IMG not found"

# <modules-staging-dir> is 01's MODULES_STAGING_DIR (lib/modules/<ver>/) or a saved
# kernel-modules-<ver> tree (itself the <ver> dir); override with KERNEL_VERSION.
KERNEL_VERSION="${KERNEL_VERSION:-}"
if [[ -d "$MODULES_STAGING_DIR/lib/modules" ]]; then
    MODULES_ROOT="$MODULES_STAGING_DIR/lib/modules"
    [[ -n "$KERNEL_VERSION" ]] || KERNEL_VERSION="$(basename "$(find "$MODULES_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n1)")"
    MODULES_SRC="$MODULES_ROOT/$KERNEL_VERSION"
elif [[ -d "$MODULES_STAGING_DIR/kernel" && -f "$MODULES_STAGING_DIR/modules.dep" ]]; then
    MODULES_ROOT="$MODULES_STAGING_DIR"
    [[ -n "$KERNEL_VERSION" ]] || KERNEL_VERSION="$(basename "$MODULES_ROOT" | sed -E 's/^kernel-modules-//')"
    MODULES_SRC="$MODULES_ROOT"
else
    fail "$MODULES_STAGING_DIR is neither a MODULES_STAGING_DIR (with lib/modules/<ver>/) nor a saved kernel-modules-<ver> tree"
fi
[[ -n "$KERNEL_VERSION" ]] || fail "could not determine kernel version -- set KERNEL_VERSION=<uname -r value>"
log "kernel version: $KERNEL_VERSION"

establish_control_socket() {
    log "establishing SSH ControlMaster to $DEVICE_HOST"
    if ! python3 "$SCRIPT_DIR/lib/ssh_master.py" "$DEVICE_HOST" "$DEVICE_PASSWORD" "$SSH_CONTROL_SOCKET"; then
        fail "could not establish SSH ControlMaster to $DEVICE_HOST -- do NOT retry rapidly if this just followed a dropped connection (sshd's PerSourcePenalties can lock out both this and the user's own session at once)"
    fi
}

backup_current_partition() {
    local backup_file
    backup_file="$BACKUP_DIR/boot-partition-backup-preflash-$(date +%Y-%m-%d-%H%M%S).img"
    log "backing up CURRENT boot partition ($BOOT_PARTITION) to $backup_file"
    ssh_dev "cat '$BOOT_PARTITION'" > "$backup_file"
    local sha
    sha="$(sha256sum "$backup_file" | awk '{print $1}')"
    log "  backup saved, sha256: $sha"
    echo "$backup_file"
}

transfer_and_verify() {
    log "transferring $NEW_BOOT_IMG to $DEVICE_HOST:/tmp/new-boot.img"
    scp -o ControlPath="$SSH_CONTROL_SOCKET" "$NEW_BOOT_IMG" "$DEVICE_HOST:/tmp/new-boot.img"

    local local_sha remote_sha
    local_sha="$(sha256sum "$NEW_BOOT_IMG" | awk '{print $1}')"
    remote_sha="$(ssh_dev sha256sum /tmp/new-boot.img | awk '{print $1}')"
    log "  local  sha256: $local_sha"
    log "  remote sha256: $remote_sha"
    if [[ "$local_sha" != "$remote_sha" ]]; then
        fail "transfer verification failed -- local and remote sha256 do not match, DO NOT FLASH. Re-transfer and try again."
    fi
    log "  transfer verified OK"
}

confirm_recovery_ready() {
    # Read from /dev/tty, not stdin: the ssh/scp calls above consume stdin, so a piped/heredoc
    # "yes" can never reach this prompt; FLASH_CONFIRM=yes skips it for scripted runs.
    cat <<EOF

=============================================================================
ABOUT TO FLASH: $BOOT_PARTITION on $DEVICE_HOST
This is the one operation that has already bricked this device for real.
Before continuing, confirm:
  - You have reviewed any new/changed driver source against this tree's
    ACTUAL headers (not remembered/general kernel knowledge).
  - Your recovery-mode procedure and/or serial console access is ready
    RIGHT NOW, not "I'll figure it out if it breaks" -- keep the device's
    telnet-recovery steps at hand.
  - The pre-flash backup just taken above is somewhere you can actually get
    back to it.
=============================================================================

EOF
    if [[ "${FLASH_CONFIRM:-}" == "yes" ]]; then
        log "FLASH_CONFIRM=yes -- proceeding without interactive confirmation"
        return 0
    fi
    local confirm=""
    if [[ -r /dev/tty ]]; then
        read -r -p "Type 'yes' to proceed with flashing, anything else aborts: " confirm < /dev/tty
    else
        fail "no controlling terminal for the flash confirmation -- set FLASH_CONFIRM=yes to run non-interactively"
    fi
    if [[ "$confirm" != "yes" ]]; then
        fail "flash aborted by user (did not type 'yes')"
    fi
}

flash_and_verify() {
    log "flashing $BOOT_PARTITION with explicit sync"
    ssh_dev "dd if=/tmp/new-boot.img of='$BOOT_PARTITION' bs=4096 conv=fsync && sync && sync"

    log "reading back and verifying the flash"
    local flashed_sha expected_sha
    expected_sha="$(sha256sum "$NEW_BOOT_IMG" | awk '{print $1}')"
    flashed_sha="$(ssh_dev "cat '$BOOT_PARTITION'" | sha256sum | awk '{print $1}')"
    if [[ "$flashed_sha" != "$expected_sha" ]]; then
        fail "POST-FLASH VERIFICATION FAILED -- flashed partition sha256 ($flashed_sha) does not match the image ($expected_sha). Do not reboot; restore from the pre-flash backup immediately."
    fi
    log "  flash verified OK, $BOOT_PARTITION now matches $NEW_BOOT_IMG exactly"
}

ensure_remote_rsync() {
    # Stock firmware does NOT ship rsync; install_kernel_modules below needs it.
    if ssh_dev "command -v rsync >/dev/null 2>&1"; then
        return 0
    fi
    log "rsync missing on $DEVICE_HOST (stock firmware lacks it) -- installing via apt"
    ssh_dev "apt-get update -qq && apt-get install -y rsync" || fail "could not install rsync on $DEVICE_HOST"
}

install_kernel_modules() {
    log "installing kernel modules for $KERNEL_VERSION (separate from the boot partition -- these live under /lib/modules/, not in the boot image)"
    # Remove any stale module tree first so depmod's index doesn't mix old and new.
    ssh_dev "rm -rf '/lib/modules/$KERNEL_VERSION'"
    rsync -e "ssh -S $SSH_CONTROL_SOCKET" -a --chown=root:root \
        "$MODULES_SRC/" \
        "$DEVICE_HOST:/lib/modules/$KERNEL_VERSION/"
    ssh_dev "depmod -a '$KERNEL_VERSION'"
    log "  modules installed, $(ssh_dev "find /lib/modules/$KERNEL_VERSION -name '*.ko' | wc -l") .ko files"
}

main() {
    establish_control_socket
    backup_current_partition
    transfer_and_verify
    confirm_recovery_ready
    flash_and_verify
    ensure_remote_rsync
    install_kernel_modules

    cat <<EOF

Done. Flash complete; $BOOT_PARTITION now matches $NEW_BOOT_IMG.
  - install.sh reboots and provisions (03/04/05) automatically after this.
  - Running 02 by hand: reboot (ssh root@<ip> reboot), confirm `uname -r`
    reports $KERNEL_VERSION, then run provision-all.sh (or
    03-install-drive-stack.sh) to bring up the Drive stack.
  - Either way: test any NEWLY-built driver over SSH before wiring it to
    load automatically at boot (insmod, dmesg, exercise, rmmod) -- see
    01-build-kernel.sh's NEXT STEPS output.
EOF
}

# Guarded so this script can be `source`d to re-run one step in isolation; no effect on ./02 execution.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
