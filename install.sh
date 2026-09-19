#!/bin/bash
# install.sh -- put Ubiquiti's genuine UniFi Drive stack onto a Cloud Key Gen 2
# Plus, driven end to end from a Debian build host. Every stage is idempotent;
# the kernel stages (00/01/02) are skipped when the device already runs the
# custom kernel unless --rebuild-kernel is given.
#
# Usage:
#   ./install.sh [--rebuild-kernel] [--no-flash] [--yes]
#
# Options:
#   --rebuild-kernel   Force 00/01/02 even if the device already runs the
#                      custom kernel.
#   --no-flash         Run everything up to (but not including) the flash,
#                      then stop. The built image + modules are saved under
#                      fw_picked/ for a later manual 02.
#   --yes              Non-interactive. Requires DEVICE_HOST and
#                      DEVICE_PASSWORD in the environment; implies
#                      FLASH_CONFIRM=yes (no flash confirmation). Do not use
#                      on hardware whose recovery you are not prepared for.
#   -h, --help         Show this text.
#
# Environment overrides (all optional):
#   DEVICE_HOST          e.g. root@<cloudkey-ip> (bare IP is accepted; prompted if unset)
#   DEVICE_PASSWORD      the device's root password (prompted if unset)
#   KERNEL_SRC_REPO      kernel source repo to clone; defaults to the
#                        ckg2plus-kernel-src companion repo
#   BOOT_PARTITION       device boot partition (default /dev/mmcblk0p42)
#   BUILD_DIR            kernel staging dir (default $HOME/ck-kernel-build)
#   CHROOT_PATH          bullseye chroot (default $HOME/bullseye-chroot)
#   SSH_CONTROL_SOCKET   SSH ControlMaster socket (default /tmp/ck_ssh_ctrl.sock)
#   FLASH_CONFIRM        yes to skip 02's typed confirmation
#   REBOOT_WAIT_MAX_SECS / REBOOT_WAIT_BEFORE_POLLING_SECS / REBOOT_POLL_INTERVAL_SECS
#                        reboot-wait tuning (defaults 900 / 20 / 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNAS_DIR="$SCRIPT_DIR/UNAS-CloudKey"

EXPECT_KERNEL="3.18.44-btrfscustom"
DEFAULT_KERNEL_SRC_REPO="https://github.com/hutchx86/ckg2plus-kernel-src.git"
HOST_APT_PACKAGES=(debootstrap wget ca-certificates python3 squashfs-tools abootimg rsync openssh-client git)

REBUILD_KERNEL=0
NO_FLASH=0
ASSUME_YES="${ASSUME_YES:-0}"

log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

usage() {
    # Print the leading comment block (everything after the shebang, up to
    # the first non-comment line).
    awk 'NR==1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "$0"
}

while (($#)); do
    case "$1" in
        --rebuild-kernel) REBUILD_KERNEL=1 ;;
        --no-flash)       NO_FLASH=1 ;;
        --yes|-y)         ASSUME_YES=1 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

if (( ASSUME_YES )); then
    export FLASH_CONFIRM=yes
fi

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

require_repo_layout() {
    if [[ ! -f "$UNAS_DIR/provision-all.sh" || ! -f "$UNAS_DIR/lib/ssh_master.py" ]]; then
        die "run this from the repository root (expected $UNAS_DIR/provision-all.sh and $UNAS_DIR/lib/ssh_master.py)"
    fi
}

ensure_sudo_available() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 \
        || die "not root and 'sudo' is not installed -- either run as root or install sudo"
    log "requesting sudo (needed for host packages, the chroot, and the kernel build)"
    "${SUDO[@]}" -v || die "sudo authentication failed"
}

ensure_host_deps() {
    # command -> Debian package, for the tools the host-side scripts need.
    local -A pkg_for=(
        [debootstrap]=debootstrap
        [wget]=wget
        [python3]=python3
        [unsquashfs]=squashfs-tools
        [abootimg]=abootimg
        [rsync]=rsync
        [ssh]=openssh-client
        [scp]=openssh-client
        [git]=git
    )
    local missing=0 cmd
    for cmd in "${!pkg_for[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "missing host tool: $cmd (package: ${pkg_for[$cmd]})"
            missing=1
        fi
    done
    if (( missing == 0 )); then
        log "host dependencies present"
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 \
        || die "missing host tools and apt-get is not available -- install these first: ${HOST_APT_PACKAGES[*]}"
    log "installing host dependencies: ${HOST_APT_PACKAGES[*]}"
    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${HOST_APT_PACKAGES[@]}"
    for cmd in "${!pkg_for[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "host tool still missing after install: $cmd"
    done
}

prompt_device() {
    if (( ASSUME_YES )); then
        [[ -n "${DEVICE_HOST:-}" ]] || die "--yes requires DEVICE_HOST in the environment"
        [[ -n "${DEVICE_PASSWORD:-}" ]] || die "--yes requires DEVICE_PASSWORD in the environment"
    fi

    if [[ -z "${DEVICE_HOST:-}" ]]; then
        [[ -r /dev/tty ]] || die "DEVICE_HOST is not set and there is no terminal to prompt on"
        read -r -p "Cloud Key address (e.g. root@<cloudkey-ip>): " DEVICE_HOST < /dev/tty
    fi
    [[ -n "$DEVICE_HOST" ]] || die "no device address given"
    # Accept a bare IP/hostname and default to the root user the pipeline expects.
    [[ "$DEVICE_HOST" == *@* ]] || DEVICE_HOST="root@$DEVICE_HOST"

    if [[ -z "${DEVICE_PASSWORD:-}" ]]; then
        [[ -r /dev/tty ]] || die "DEVICE_PASSWORD is not set and there is no terminal to prompt on"
        local p1 p2
        while :; do
            read -r -s -p "Root password for ${DEVICE_HOST}: " p1 < /dev/tty
            printf '\n' >&2
            read -r -s -p "Confirm password: " p2 < /dev/tty
            printf '\n' >&2
            if [[ -n "$p1" && "$p1" == "$p2" ]]; then
                DEVICE_PASSWORD="$p1"
                break
            fi
            warn "passwords did not match (or were empty), try again"
        done
    fi

    export DEVICE_HOST DEVICE_PASSWORD
    log "device: $DEVICE_HOST"
}

SSH_CONTROL_SOCKET="${SSH_CONTROL_SOCKET:-/tmp/ck_ssh_ctrl.sock}"
export SSH_CONTROL_SOCKET

ssh_dev() { ssh -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" "$@"; }

establish_socket() {
    log "connecting to $DEVICE_HOST"
    python3 "$UNAS_DIR/lib/ssh_master.py" "$DEVICE_HOST" "$DEVICE_PASSWORD" "$SSH_CONTROL_SOCKET" >/dev/null \
        || die "could not establish SSH to $DEVICE_HOST -- check the address and root password"
}

device_kernel() {
    ssh_dev uname -r 2>/dev/null || true
}

ensure_debs() {
    if compgen -G "$SCRIPT_DIR/fw_picked/debs-build/*.deb" >/dev/null; then
        log "pinned Ubiquiti packages already present in fw_picked/debs-build/ -- skipping fetch"
        return 0
    fi
    log "regenerating pinned Ubiquiti packages (downloads and verifies the firmware)"
    "$SCRIPT_DIR/scripts/fetch-firmware-debs.sh"
}

fetch_device_artifacts() {
    : "${BOOT_PARTITION:=/dev/mmcblk0p42}"
    : "${BUILD_DIR:=$HOME/ck-kernel-build}"
    export BOOT_PARTITION BUILD_DIR
    mkdir -p "$BUILD_DIR"

    log "pulling device-derived kernel inputs into $BUILD_DIR"
    ssh_dev "zcat /proc/config.gz" > "$BUILD_DIR/verified-running.config"
    [[ -s "$BUILD_DIR/verified-running.config" ]] \
        || die "could not read /proc/config.gz from $DEVICE_HOST (is it a stock Cloud Key OS?)"

    ssh_dev "cat /sys/firmware/fdt" > "$BUILD_DIR/cloudkey-live.dtb"
    [[ -s "$BUILD_DIR/cloudkey-live.dtb" ]] \
        || die "could not read /sys/firmware/fdt from $DEVICE_HOST"

    log "backing up the current boot partition ($BOOT_PARTITION) for abootimg -x"
    ssh_dev "cat '$BOOT_PARTITION'" > "$BUILD_DIR/original-boot.img"
    [[ -s "$BUILD_DIR/original-boot.img" ]] \
        || die "could not read $BOOT_PARTITION from $DEVICE_HOST"
    ( cd "$BUILD_DIR" && abootimg -x original-boot.img ) \
        || die "abootimg -x failed on the boot-partition backup"
    [[ -f "$BUILD_DIR/bootimg.cfg" && -f "$BUILD_DIR/initrd.img" ]] \
        || die "abootimg -x did not produce bootimg.cfg and initrd.img"
}

create_chroot() {
    : "${CHROOT_PATH:=$HOME/bullseye-chroot}"
    export CHROOT_PATH
    log "creating/updating the bullseye kernel-build chroot ($CHROOT_PATH)"
    "${SUDO[@]}" "$UNAS_DIR/00-create-chroot.sh" "$CHROOT_PATH" "$BUILD_DIR"
}

build_kernel() {
    log "staging UNAS-CloudKey/ into $BUILD_DIR"
    "${SUDO[@]}" rsync -a --delete "$UNAS_DIR/" "$BUILD_DIR/UNAS-CloudKey/"
    log "building the custom kernel inside the chroot (this takes a while)"
    "${SUDO[@]}" chroot "$CHROOT_PATH" /usr/bin/env \
        "KERNEL_SRC_REPO=${KERNEL_SRC_REPO:-$DEFAULT_KERNEL_SRC_REPO}" \
        /bin/bash -c 'cd /build && ./UNAS-CloudKey/01-build-kernel.sh'
    [[ -f "$BUILD_DIR/new-boot.img" ]] || die "kernel build produced no $BUILD_DIR/new-boot.img"
}

save_build_outputs() {
    local modules_src="$BUILD_DIR/modules-staging/lib/modules/$EXPECT_KERNEL"
    [[ -d "$modules_src" ]] || die "no module tree at $modules_src"
    log "saving canonical build outputs into fw_picked/"
    "${SUDO[@]}" rm -rf "$SCRIPT_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL"
    "${SUDO[@]}" mkdir -p "$SCRIPT_DIR/fw_picked/cloudkey-kernel-build" "$SCRIPT_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL"
    "${SUDO[@]}" cp -a "$BUILD_DIR/new-boot.img" "$SCRIPT_DIR/fw_picked/cloudkey-kernel-build/new-boot.img"
    "${SUDO[@]}" cp -a "$modules_src/." "$SCRIPT_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL/"
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" \
        "$SCRIPT_DIR/fw_picked/cloudkey-kernel-build" "$SCRIPT_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL"
}

flash_kernel() {
    local boot_img="$SCRIPT_DIR/fw_picked/cloudkey-kernel-build/new-boot.img"
    local modules_dir="$SCRIPT_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL"
    log "flashing the custom kernel -- 02 will ask you to confirm before writing"
    "$UNAS_DIR/02-flash-kernel.sh" "$boot_img" "$modules_dir"
}

reboot_and_wait_for_kernel() {
    local before="${REBOOT_WAIT_BEFORE_POLLING_SECS:-20}"
    local max="${REBOOT_WAIT_MAX_SECS:-900}"
    local interval="${REBOOT_POLL_INTERVAL_SECS:-10}"

    log "rebooting $DEVICE_HOST to activate the new kernel"
    ssh_dev "nohup reboot >/dev/null 2>&1 & sleep 1" || true
    ssh -O exit -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" 2>/dev/null || true

    sleep "$before"
    local waited="$before" kver=""
    while (( waited < max )); do
        if python3 "$UNAS_DIR/lib/ssh_master.py" "$DEVICE_HOST" "$DEVICE_PASSWORD" "$SSH_CONTROL_SOCKET" >/dev/null 2>&1; then
            kver="$(ssh_dev uname -r 2>/dev/null || true)"
            if [[ "$kver" == "$EXPECT_KERNEL" ]]; then
                log "  device is back on $kver after ~${waited}s"
                return 0
            fi
            log "  device is up but still running '$kver' -- waiting for the new kernel"
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
    die "device did not come back on $EXPECT_KERNEL within ${max}s -- do not retry SSH rapidly; check the console"
}

provision() {
    log "provisioning and verifying the Drive stack (03/04/05 via provision-all.sh)"
    "$UNAS_DIR/provision-all.sh"
}

main() {
    require_repo_layout
    ensure_sudo_available
    ensure_host_deps
    prompt_device
    establish_socket

    local kver
    kver="$(device_kernel)"
    log "device is running kernel: ${kver:-<unknown>}"

    # Fetch packages early so a firmware-API failure precedes the long kernel build.
    ensure_debs

    if [[ "$kver" == "$EXPECT_KERNEL" && $REBUILD_KERNEL -eq 0 ]]; then
        log "device already runs $EXPECT_KERNEL -- skipping kernel build + flash"
        log "  (pass --rebuild-kernel to force a rebuild/reflash)"
    else
        fetch_device_artifacts
        create_chroot
        build_kernel
        save_build_outputs
        if (( NO_FLASH )); then
            log "--no-flash: stopping before flash"
            log "  image:   $SCRIPT_DIR/fw_picked/cloudkey-kernel-build/new-boot.img"
            log "  modules: $SCRIPT_DIR/fw_picked/kernel-modules-$EXPECT_KERNEL"
            return 0
        fi
        flash_kernel
        reboot_and_wait_for_kernel
    fi

    provision
    log "done."
}

main "$@"
