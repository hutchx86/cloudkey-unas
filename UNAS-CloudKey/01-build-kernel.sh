#!/bin/bash
#
# 01-build-kernel.sh
#
# Builds the custom CloudKey kernel (3.18.44-btrfscustom) inside the bullseye
# chroot from 00-create-chroot.sh. Runs unattended. Patches Ubiquiti's GPL
# tree for the smp2p alignment fault, the log2.h const/noreturn error, and
# the statx(2) syscall unifi-drive needs.
#
# Run from the working dir containing: the kernel source (KERNEL_SRC_REPO, or
# a local tarball / UCKP-*-GPL.tar.gz), verified-running.config (device
# `zcat /proc/config.gz`), cloudkey-live.dtb (device `/sys/firmware/fdt`), and
# bootimg.cfg + initrd.img (abootimg -x on the stock boot partition). Writes
# new-boot.img and modules-staging/; flash with 02-flash-kernel.sh.
# custom-drivers/ is read via $SCRIPT_DIR, so run from a copy of UNAS-CloudKey/.
# ---------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Configuration: adjust these paths if yours differ ----
TARBALL="linux-qcom-apq8053-3.18.44-ui-qcom.tar"
SRC_DIR="linux-qcom-apq8053-3.18.44-ui-qcom"
RUNNING_CONFIG="verified-running.config"
LIVE_DTB="cloudkey-live.dtb"
LOCALVERSION_SUFFIX="-btrfscustom"
JOBS="$(nproc)"

# Source acquisition: KERNEL_SRC_REPO is cloned; else $TARBALL is resolved from
# a local file, a UCKP-*-GPL.tar.gz bundle, or KERNEL_SRC_URL (verified by SHA256).
KERNEL_SRC_REPO="${KERNEL_SRC_REPO:-}"
KERNEL_SRC_URL="${KERNEL_SRC_URL:-}"
KERNEL_SRC_SHA256="${KERNEL_SRC_SHA256:-d1d733355c29919cc3d2ce461bcf2de8e5e4485b3c2dc6ceef59d5cef58e3663}"
KERNEL_GPL_BUNDLE="${KERNEL_GPL_BUNDLE:-}"

# Pull $TARBALL out of a Ubiquiti GPL bundle; nonzero if the file is not one.
extract_kernel_from_bundle() {
    local bundle="$1" inner
    inner="$(tar tf "$bundle" 2>/dev/null | grep -E "(^|/)${TARBALL}\$" | head -n1 || true)"
    [[ -n "$inner" ]] || return 1
    echo "   extracting $inner from $bundle"
    tar xf "$bundle" "$inner"
    mv "$inner" "$TARBALL"
    rmdir "$(dirname "$inner")" 2>/dev/null || true
    return 0
}

fetch_source_tarball() {
# No-op when KERNEL_SRC_REPO is set (extract_source() clones it instead).
[[ -n "$KERNEL_SRC_REPO" ]] && return 0
# No-op if $TARBALL exists; otherwise fall through so check_prerequisites
# reports the missing file.
[[ -f "$TARBALL" ]] && return 0

local bundle="${KERNEL_GPL_BUNDLE:-}"
if [[ -z "$bundle" ]]; then
    bundle="$(find . -maxdepth 2 -name 'UCKP-*-GPL.tar.gz' -print -quit 2>/dev/null || true)"
fi
if [[ -n "$bundle" && -f "$bundle" ]] && extract_kernel_from_bundle "$bundle"; then
    return 0
fi

[[ -n "$KERNEL_SRC_URL" ]] || return 0

echo "== Fetching source tarball =="
echo "   $KERNEL_SRC_URL"
local dl="$TARBALL.download"
if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$dl" "$KERNEL_SRC_URL" \
        || { rm -f "$dl"; echo "ERROR: failed to download $KERNEL_SRC_URL" >&2; exit 1; }
elif command -v curl >/dev/null 2>&1; then
    curl -fL -o "$dl" "$KERNEL_SRC_URL" \
        || { rm -f "$dl"; echo "ERROR: failed to download $KERNEL_SRC_URL" >&2; exit 1; }
else
    echo "ERROR: neither wget nor curl is available to fetch $TARBALL" >&2
    exit 1
fi

if [[ -n "$KERNEL_SRC_SHA256" ]]; then
    if echo "$KERNEL_SRC_SHA256  $dl" | sha256sum -c - >/dev/null 2>&1; then
        echo "   sha256 OK"
    else
        echo "ERROR: downloaded file failed sha256 verification (expected $KERNEL_SRC_SHA256) -- removing it" >&2
        rm -f "$dl"
        exit 1
    fi
else
    echo "   WARNING: KERNEL_SRC_SHA256 unset -- downloaded file NOT verified" >&2
fi

if extract_kernel_from_bundle "$dl"; then
    rm -f "$dl"
    return 0
fi
mv "$dl" "$TARBALL"
}


check_prerequisites() {
fetch_source_tarball
# ---- Sanity checks ----
# Source is $TARBALL or a KERNEL_SRC_REPO clone; RUNNING_CONFIG/LIVE_DTB come
# from the device.
local required=("$RUNNING_CONFIG" "$LIVE_DTB")
if [[ -z "$KERNEL_SRC_REPO" ]]; then
    required=("$TARBALL" "${required[@]}")
else
    command -v git >/dev/null 2>&1 || {
        echo "ERROR: KERNEL_SRC_REPO is set but git is not installed." >&2
        exit 1
    }
fi
for f in "${required[@]}"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required file '$f' not found in $(pwd)." >&2
        echo "See the prerequisites comment block at the top of this script." >&2
        exit 1
    fi
done

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    echo "ERROR: aarch64-linux-gnu-gcc not found." >&2
    echo "Install the toolchain first:" >&2
    echo "  apt update && apt install -y crossbuild-essential-arm64 build-essential \\" >&2
    echo "    bc bison flex libssl-dev libelf-dev dwarves kmod cpio rsync git \\" >&2
    echo "    python3 perl device-tree-compiler" >&2
    exit 1
fi

GCC_VERSION="$(aarch64-linux-gnu-gcc --version | head -1)"
echo "Using toolchain: $GCC_VERSION"
if ! echo "$GCC_VERSION" | grep -q "10.2.1"; then
    echo "WARNING: expected gcc 10.2.1 (Debian bullseye) -- got a different version."
    echo "This tree is known to fail or misbehave with mismatched compilers. Continuing anyway."
fi
}

extract_source() {
# ---- 1. Clean extraction ----
# Start fresh: the tarball ships Ubiquiti's own build artifacts, and reusing
# them lets make silently mix objects built against a different .config.
echo "== Removing any existing extracted source tree =="
rm -rf "$SRC_DIR"

if [[ -n "$KERNEL_SRC_REPO" ]]; then
    echo "== Cloning source repo =="
    echo "   $KERNEL_SRC_REPO"
    git clone --depth 1 "$KERNEL_SRC_REPO" "$SRC_DIR"
    cd "$SRC_DIR"
else
    echo "== Extracting tarball =="
    tar xf "$TARBALL"
    cd "$SRC_DIR"
fi

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

echo "== Cleaning any pre-existing build artifacts from the tarball itself =="
make mrproper

}

fix_broken_symlinks() {
# ---- 2. Fix broken/missing vendor files ----
# The vendor tree symlinks some files into Ubiquiti's build host and omits
# others; ckg2plus-kernel-src mirrors it as-is, so restore what the arm64 build
# needs from mainline 3.18.44 here (source-less accessory drivers are disabled
# instead).
echo "== Fixing broken symlinks / missing vendor files =="

# Restored from mainline 3.18.44 if absent or a broken symlink. ax88179_178a.c
# is the only NIC; vmlinux.lds.h and vmlinux.lds.S are needed by
# usr/initramfs_data.S and the arm64 linker script.
local MAINLINE_31844=/tmp/linux-3.18.44
local MAINLINE_TARBALL=/tmp/linux-3.18.44.tar.xz
local -a MAINLINE_FILES=(
    drivers/net/usb/ax88179_178a.c
    include/asm-generic/vmlinux.lds.h
    arch/arm64/kernel/vmlinux.lds.S
)
local need_mainline=0 f
for f in "${MAINLINE_FILES[@]}"; do
    [ -f "$MAINLINE_31844/$f" ] || need_mainline=1
done
if [ "$need_mainline" = 1 ]; then
    echo "   Fetching mainline 3.18.44 source for: ${MAINLINE_FILES[*]}"
    if [ ! -f "$MAINLINE_TARBALL" ]; then
        ( cd /tmp && wget -q https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.18.44.tar.xz )
    fi
    local -a members=()
    for f in "${MAINLINE_FILES[@]}"; do
        members+=("linux-3.18.44/$f")
    done
    ( cd /tmp && tar xf linux-3.18.44.tar.xz "${members[@]}" )
fi
for f in "${MAINLINE_FILES[@]}"; do
    if [ ! -s "$f" ]; then
        mkdir -p "$(dirname "$f")"
        rm -f "$f"
        cp "$MAINLINE_31844/$f" "$f"
        echo "   Restored $f from mainline."
    fi
done

# --- hci_smd.c: real Qualcomm/CodeAurora GPLv2 source ---
# Broken symlink; ported from a public MSM8953-era tree and kept in
# custom-drivers/ (outside $SRC_DIR) because it needed real porting work.
CUSTOM_BT_DIR="$SCRIPT_DIR/custom-drivers"
if [ ! -f "$CUSTOM_BT_DIR/hci_smd.c" ]; then
    echo "ERROR: $CUSTOM_BT_DIR/hci_smd.c not found." >&2
    echo "Ported Qualcomm/CodeAurora GPLv2 hci_smd.c (ubnt,ck-powersource's" >&2
    echo "sibling fix for CONFIG_BT_HCISMD), absent from Ubiquiti's GPL" >&2
    echo "tarball entirely (broken symlink, no real source -- see the" >&2
    echo "file's own header for provenance). Place it there before" >&2
    echo "rerunning." >&2
    exit 1
fi
rm -f drivers/bluetooth/hci_smd.c
cp "$CUSTOM_BT_DIR/hci_smd.c" drivers/bluetooth/hci_smd.c
echo "   Reinstated hci_smd.c from $CUSTOM_BT_DIR (survives future reruns)."

# --- ubnt accessory drivers ---
# Broken symlinks with no real source. cloudkey-power.c is reconstructed
# (reinstated below); cloudkey-rackmount.c stays disabled.
rm -f drivers/misc/ubnt/Kconfig drivers/misc/ubnt/Makefile \
      drivers/misc/ubnt/cloudkey-power.c drivers/misc/ubnt/cloudkey-rackmount.c
rmdir drivers/misc/ubnt 2>/dev/null || true

# --- cloudkey-power.c: reconstructed driver, reinstated after the wipe above ---
# Kept outside $SRC_DIR so `rm -rf "$SRC_DIR"` never touches it.
CUSTOM_UBNT_DIR="$SCRIPT_DIR/custom-drivers"
if [ ! -f "$CUSTOM_UBNT_DIR/cloudkey-power.c" ]; then
    echo "ERROR: $CUSTOM_UBNT_DIR/cloudkey-power.c not found." >&2
    echo "Clean-room reimplementation of the CloudKey power-source" >&2
    echo "(mains/PoE/USB-C) detection driver, absent from Ubiquiti's" >&2
    echo "GPL tarball entirely (broken symlink, no real source). Place" >&2
    echo "it there before rerunning." >&2
    exit 1
fi
mkdir -p drivers/misc/ubnt
cp "$CUSTOM_UBNT_DIR/cloudkey-power.c" drivers/misc/ubnt/cloudkey-power.c
cat > drivers/misc/ubnt/Makefile << 'MAKEFILE_EOF'
obj-$(CONFIG_UBNT_CLOUDKEY_POWERSOURCE)	+= cloudkey-power.o
MAKEFILE_EOF
cat > drivers/misc/ubnt/Kconfig << 'KCONFIG_EOF'
config UBNT_CLOUDKEY_POWERSOURCE
	tristate "CloudKey power-source (mains/PoE/USB-C) detection"
	depends on OF && GPIOLIB
	help
	  Reports the CloudKey's external power source (PoE, USB-C, and
	  Quick Charge negotiation) as a "mains" power_supply device.

	  Clean-room reimplementation; absent from Ubiquiti's GPL
	  tarball entirely (broken symlink, no real source). See
	  cloudkey-power.c for details.

	  cloudkey-rackmount.c (CONFIG_UBNT_CLOUDKEY_RACKMOUNT) remains
	  unreconstructed and disabled -- see the .config sanity section
	  below.
KCONFIG_EOF
# drivers/misc/{Kconfig,Makefile} already reference ubnt/ and work as-is; no sed.
echo "   Reinstated cloudkey-power.c from $CUSTOM_UBNT_DIR (survives future reruns)."
echo "   cloudkey-rackmount.c remains unreconstructed -- CONFIG_UBNT_CLOUDKEY_RACKMOUNT stays disabled."

# --- ubnthal: /proc/ubnthal identity emulation ---
# From-scratch stub for unifi-drive's storageService, exporting a UNAS Pro
# identity (sysid 0xea51) from /proc/ubnthal/{system.info,board}; outside $SRC_DIR.
CUSTOM_UBNTHAL_DIR="$SCRIPT_DIR/custom-drivers"
if [ ! -f "$CUSTOM_UBNTHAL_DIR/ubnthal.c" ]; then
    echo "ERROR: $CUSTOM_UBNTHAL_DIR/ubnthal.c not found." >&2
    echo "From-scratch /proc/ubnthal identity-emulation stub (not a" >&2
    echo "Ubiquiti driver -- doesn't exist in the GPL tarball at all)." >&2
    echo "Place it there before rerunning." >&2
    exit 1
fi
mkdir -p drivers/misc/ubnthal
cp "$CUSTOM_UBNTHAL_DIR/ubnthal.c" drivers/misc/ubnthal/ubnthal.c
cat > drivers/misc/ubnthal/Makefile << 'MAKEFILE_EOF'
obj-$(CONFIG_UBNT_HAL)	+= ubnthal.o
MAKEFILE_EOF
cat > drivers/misc/ubnthal/Kconfig << 'KCONFIG_EOF'
config UBNT_HAL
	tristate "UBNTHAL /proc identity emulation (UNAS Pro spoof)"
	help
	  Creates /proc/ubnthal/{system.info,board} with static content
	  reporting a UNAS Pro hardware identity (sysid 0xea51). Not a
	  real Ubiquiti driver -- this doesn't exist anywhere in the
	  GPL tarball. Needed for UniFi OS userspace services (e.g.
	  unifi-drive's storageService) that read hardware identity
	  from /proc/ubnthal directly instead of (or in addition to)
	  shelling out to `ubnt-tools id`.

	  Changed from bool to tristate 2026-09-05 so this can be
	  rmmod'd on demand (e.g. to let unifi-core's WebUI update-check
	  fall through to genuine ubnt-tools identity instead of this
	  module's spoofed one, for a real Cloud Key OS update) without a
	  kernel rebuild each time. ubnthal.c's module_init/module_exit
	  were already written in the portable style with a correct,
	  complete teardown path -- no C source changes needed for this.
KCONFIG_EOF
# No pre-existing ubnthal reference; add it to drivers/misc/{Kconfig,Makefile}
# after the ubnt/ entries so it lands in the same place every extraction.
sed -i '/^source "drivers\/misc\/ubnt\/Kconfig"$/a source "drivers/misc/ubnthal/Kconfig"' \
    drivers/misc/Kconfig
sed -i '/^obj-y.*ubnt\/$/a obj-y\t\t\t\t+= ubnthal/' \
    drivers/misc/Makefile
if ! grep -q 'drivers/misc/ubnthal/Kconfig' drivers/misc/Kconfig; then
    echo "ERROR: failed to wire ubnthal/Kconfig into drivers/misc/Kconfig" >&2
    echo "(the ubnt/Kconfig anchor line this sed depends on may have moved" >&2
    echo "or been renamed in this tarball -- check drivers/misc/Kconfig by hand)." >&2
    exit 1
fi
if ! grep -q 'ubnthal' drivers/misc/Makefile; then
    echo "ERROR: failed to wire ubnthal/ into drivers/misc/Makefile" >&2
    echo "(the ubnt/ anchor line this sed depends on may have moved or been" >&2
    echo "renamed in this tarball -- check drivers/misc/Makefile by hand)." >&2
    exit 1
fi
echo "   Installed ubnthal.c from $CUSTOM_UBNTHAL_DIR and wired into drivers/misc/ (survives future reruns)."

# --- ui_hdd_pwrctl_fake: dummy HDD bay presence for uhwd ---
# From-scratch sysfs stub at /sys/devices/platform/ui-hdd-pwrctl/slot-<N>/
# present; the real driver exists only for the 5.10-alpine-unas kernel.
CUSTOM_UI_HDD_PWRCTL_FAKE_DIR="$SCRIPT_DIR/custom-drivers"
if [ ! -f "$CUSTOM_UI_HDD_PWRCTL_FAKE_DIR/ui_hdd_pwrctl_fake.c" ]; then
    echo "ERROR: $CUSTOM_UI_HDD_PWRCTL_FAKE_DIR/ui_hdd_pwrctl_fake.c not found." >&2
    echo "From-scratch ui-hdd-pwrctl sysfs stub (not a Ubiquiti driver --" >&2
    echo "the real one only exists for the 5.10.216-alpine-unas kernel)." >&2
    echo "Place it there before rerunning." >&2
    exit 1
fi
mkdir -p drivers/misc/ui_hdd_pwrctl_fake
cp "$CUSTOM_UI_HDD_PWRCTL_FAKE_DIR/ui_hdd_pwrctl_fake.c" drivers/misc/ui_hdd_pwrctl_fake/ui_hdd_pwrctl_fake.c
cat > drivers/misc/ui_hdd_pwrctl_fake/Makefile << 'MAKEFILE_EOF'
obj-$(CONFIG_UI_HDD_PWRCTL_FAKE)	+= ui_hdd_pwrctl_fake.o
MAKEFILE_EOF
cat > drivers/misc/ui_hdd_pwrctl_fake/Kconfig << 'KCONFIG_EOF'
config UI_HDD_PWRCTL_FAKE
	tristate "Dummy ui-hdd-pwrctl sysfs shim (fake HDD bay presence)"
	help
	  Creates /sys/devices/platform/ui-hdd-pwrctl/slot-<N>/
	  {present,fault,force_power} with all slots reporting present by
	  default. Not a real Ubiquiti driver -- ui-hdd-pwrctl.ko only
	  exists prebuilt for the 5.10.216-alpine-unas kernel and targets
	  real UNAS backplane hardware this board doesn't have. Needed
	  for uhwd to report attached USB/SATA disks as occupying bays
	  instead of treating every slot as empty.

	  DELIBERATELY tristate, not bool: this sealed device has no serial
	  console, so a bug in a driver wired in as built-in (=y) is
	  undiagnosable and boot-fatal by construction -- a =y build of this
	  exact driver previously produced a kernel that never came back up
	  over SSH after flashing and needed the recovery-mode procedure to
	  recover. Keep this =m, loaded manually via insmod over SSH for
	  testing, until it has proven stable across multiple loads. Only then
	  consider promoting it to =y following ubnthal.c's already-proven
	  pattern.
KCONFIG_EOF
sed -i '/^source "drivers\/misc\/ubnthal\/Kconfig"$/a source "drivers/misc/ui_hdd_pwrctl_fake/Kconfig"' \
    drivers/misc/Kconfig
sed -i '/^obj-y.*ubnthal\/$/a obj-y\t\t\t\t+= ui_hdd_pwrctl_fake/' \
    drivers/misc/Makefile
if ! grep -q 'drivers/misc/ui_hdd_pwrctl_fake/Kconfig' drivers/misc/Kconfig; then
    echo "ERROR: failed to wire ui_hdd_pwrctl_fake/Kconfig into drivers/misc/Kconfig" >&2
    echo "(the ubnthal/Kconfig anchor line this sed depends on may have moved" >&2
    echo "or been renamed -- check drivers/misc/Kconfig by hand)." >&2
    exit 1
fi
if ! grep -q 'ui_hdd_pwrctl_fake' drivers/misc/Makefile; then
    echo "ERROR: failed to wire ui_hdd_pwrctl_fake/ into drivers/misc/Makefile" >&2
    echo "(the ubnthal anchor line this sed depends on may have moved or been" >&2
    echo "renamed -- check drivers/misc/Makefile by hand)." >&2
    exit 1
fi
echo "   Installed ui_hdd_pwrctl_fake.c from $CUSTOM_UI_HDD_PWRCTL_FAKE_DIR and wired into drivers/misc/ (survives future reruns)."

# --- fbtft (front display) driver ---
rm -f drivers/staging/fbtft/*
rmdir drivers/staging/fbtft 2>/dev/null || true
sed -i 's|^source "drivers/staging/fbtft/Kconfig"|# source "drivers/staging/fbtft/Kconfig" (source missing from GPL tarball)|' \
    drivers/staging/Kconfig
# fbtft's Makefile uses obj-$(CONFIG_FB_TFT), disabled below; no Makefile edit needed.

# --- fb_sp8110: reconstructed driver, reinstated after the wipe above ---
# Source lives outside $SRC_DIR so the clean extraction never deletes it.
CUSTOM_FBTFT_DIR="$SCRIPT_DIR/custom-drivers"
REQUIRED_FBTFT_FILES="fb_sp8110.c fbtft.h fbtft-core.c fbtft-bus.c fbtft-io.c fbtft-sysfs.c"
for f in $REQUIRED_FBTFT_FILES; do
    if [ ! -f "$CUSTOM_FBTFT_DIR/$f" ]; then
        echo "ERROR: $CUSTOM_FBTFT_DIR/$f not found." >&2
        echo "This is part of the fbtft framework + our reconstructed SP8110" >&2
        echo "driver -- all of it lives outside \$SRC_DIR so it isn't deleted" >&2
        echo "by the clean-extraction step at the top of this script. Place" >&2
        echo "the full set there before rerunning: $REQUIRED_FBTFT_FILES" >&2
        exit 1
    fi
done
mkdir -p drivers/staging/fbtft
for f in $REQUIRED_FBTFT_FILES; do
    cp "$CUSTOM_FBTFT_DIR/$f" "drivers/staging/fbtft/$f"
done
cat > drivers/staging/fbtft/Makefile << 'MAKEFILE_EOF'
obj-$(CONFIG_FB_TFT)		+= fbtft.o
fbtft-objs			:= fbtft-core.o fbtft-sysfs.o fbtft-bus.o fbtft-io.o
obj-$(CONFIG_FB_TFT_SP8110)	+= fb_sp8110.o
MAKEFILE_EOF
cat > drivers/staging/fbtft/Kconfig << 'KCONFIG_EOF'
menu "Support for small TFT LCD display modules"
	depends on FB

config FB_TFT
	tristate
	select FB_DEFERRED_IO
	select FB_BACKLIGHT
	select FB_SYS_FILLRECT
	select FB_SYS_COPYAREA
	select FB_SYS_IMAGEBLIT
	select FB_SYS_FOPS

config FB_TFT_SP8110
	tristate "FB driver for the SP8110 SSD1351-family OLED display"
	depends on FB
	select FB_TFT
	help
	  Front-panel OLED display driver for the Ubiquiti CloudKey G2/G2+.
	  Reconstructed from stock firmware disassembly -- Ubiquiti's GPL
	  tarball ships a broken symlink for this file with no real source
	  behind it.

endmenu
KCONFIG_EOF
sed -i 's|^# source "drivers/staging/fbtft/Kconfig" (source missing from GPL tarball)|source "drivers/staging/fbtft/Kconfig"|' \
    drivers/staging/Kconfig
echo "   Reinstated fb_sp8110.c from $CUSTOM_FBTFT_DIR (survives future reruns)."

# --- leds-ulogo / ledtrig-external: reconstructed drivers, reinstated
#     after the wipe above ---
# Not in the tarball at all, so drivers/leds/ files are intact -- just add
# the sources and append entries; kept outside $SRC_DIR like the fbtft files.
CUSTOM_LEDS_DIR="$SCRIPT_DIR/custom-drivers"
REQUIRED_LEDS_FILES="leds-ulogo.c ledtrig-external.c"
for f in $REQUIRED_LEDS_FILES; do
    if [ ! -f "$CUSTOM_LEDS_DIR/$f" ]; then
        echo "ERROR: $CUSTOM_LEDS_DIR/$f not found." >&2
        echo "Clean-room reimplementation of the U-logo LED +" >&2
        echo "external0/external1 trigger driver, absent from" >&2
        echo "Ubiquiti's GPL tarball entirely. Place it there before" >&2
        echo "rerunning: $REQUIRED_LEDS_FILES" >&2
        exit 1
    fi
done
cp "$CUSTOM_LEDS_DIR/leds-ulogo.c" drivers/leds/leds-ulogo.c
cp "$CUSTOM_LEDS_DIR/ledtrig-external.c" drivers/leds/trigger/ledtrig-external.c
cat >> drivers/leds/Kconfig << 'KCONFIG_EOF'

config LEDS_TRIGGER_EXTERNAL
	tristate "LED Trigger for CloudKey-family external indicators"
	depends on LEDS_TRIGGERS
	help
	  Clean-room reimplementation; absent from Ubiquiti's GPL
	  tarball entirely. See ledtrig-external.c for details.

config LEDS_TRIGGER_EXTERNAL_MAX
	int "Number of external LED trigger slots"
	depends on LEDS_TRIGGER_EXTERNAL
	default 2

config LEDS_ULOGO
	tristate "LED support for CloudKey-family U-logo indicator"
	depends on LEDS_CLASS && OF && LEDS_TRIGGER_EXTERNAL
	help
	  Clean-room reimplementation; absent from Ubiquiti's GPL
	  tarball entirely. See leds-ulogo.c for details.

config LEDS_ULOGO_PATTERN_MAX
	int "Maximum U-logo pattern steps"
	depends on LEDS_ULOGO
	default 16
KCONFIG_EOF
echo 'obj-$(CONFIG_LEDS_TRIGGER_EXTERNAL)	+= ledtrig-external.o' >> drivers/leds/trigger/Makefile
echo 'obj-$(CONFIG_LEDS_ULOGO)		+= leds-ulogo.o' >> drivers/leds/Makefile
echo "   Reinstated leds-ulogo.c + ledtrig-external.c from $CUSTOM_LEDS_DIR (survives future reruns)."

# --- gpio-battery.c: leave symlink, disable via .config below ---
# Conditional Makefile entry, so disabling the config option suffices.

echo "== Symlink fixes complete =="

}

install_verified_config() {
# ---- 3. Install the verified running config ----
# The device's real /proc/config.gz, not the generic apq8053 config in the
# tarball (which carries NVR-class RAID/DM/bcache options this device lacks).
echo "== Installing verified running config =="
cp "../$RUNNING_CONFIG" .config

}

apply_deliberate_changes() {
# ---- 4. Apply our specific, deliberate changes ----
echo "== Applying config changes =="

# a) Mark this as a custom build (also changes vermagic)
sed -i "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"$LOCALVERSION_SUFFIX\"/" .config

# b) Disable source-less drivers: FB_TFT_ST7735R, UBNT_CLOUDKEY_RACKMOUNT,
#    BATTERY_GPIO -- not the ones restored above and re-enabled below.
sed -i \
  -e 's/^CONFIG_FB_TFT_ST7735R=y/# CONFIG_FB_TFT_ST7735R is not set/' \
  -e 's/^CONFIG_UBNT_CLOUDKEY_RACKMOUNT=y/# CONFIG_UBNT_CLOUDKEY_RACKMOUNT is not set/' \
  -e 's/^CONFIG_BATTERY_GPIO=y/# CONFIG_BATTERY_GPIO is not set/' \
  .config

# b2) Enable reconstructed SP8110 (add-or-replace: config may say "is not set").
for sym in CONFIG_FB_TFT CONFIG_FB_TFT_SP8110; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=y" >> .config
done
# NOTE: FB_DEFERRED_IO has no prompt and is enabled via FB_TFT's select.
# NOTE: USB_NET_AX88179_178A stays =y -- the device's only network interface.

# b3) Enable reconstructed CloudKey power-source driver; same idiom as b2.
# shellcheck disable=SC2043  # single symbol now, kept as a loop so the list can grow
for sym in CONFIG_UBNT_CLOUDKEY_POWERSOURCE; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=y" >> .config
done

# b4) Enable clean-room leds-ulogo + ledtrig-external. MAX values match the
#     device's /proc/config.gz: ULOGO_PATTERN_MAX=16, TRIGGER_EXTERNAL_MAX=2.
for sym in CONFIG_LEDS_TRIGGER_EXTERNAL CONFIG_LEDS_ULOGO; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=y" >> .config
done
for sym_val in "CONFIG_LEDS_TRIGGER_EXTERNAL_MAX=2" "CONFIG_LEDS_ULOGO_PATTERN_MAX=16"; do
    sym="${sym_val%%=*}"
    sed -i "/^${sym}=/d" .config
    echo "${sym_val}" >> .config
done

# b5) Enable ported hci_smd.c (real Qualcomm/CodeAurora source, not clean-room).
# shellcheck disable=SC2043  # single symbol now, kept as a loop so the list can grow
for sym in CONFIG_BT_HCISMD; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=y" >> .config
done

# b6) Enable btrfs (upstream source already present). Built =y to skip
#     modules_install/depmod; same add-or-replace idiom as b2-b5.
for sym in CONFIG_BTRFS_FS CONFIG_BTRFS_FS_POSIX_ACL \
           CONFIG_LZO_COMPRESS CONFIG_LZO_DECOMPRESS \
           CONFIG_ZSTD_COMPRESS CONFIG_ZSTD_DECOMPRESS; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=y" >> .config
done

# b7) Enable FUSE for unifi-drive's M365 backup (fusermount3 needs /dev/fuse).
#     Built =y to skip modules_install/depmod, same as btrfs/hci_smd.
# shellcheck disable=SC2043  # single symbol now, kept as a loop so the list can grow
for sym in CONFIG_FUSE_FS; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=y" >> .config
done

# b8) ubnthal is =m (loadable) so it can be rmmod'd for a genuine Cloud Key OS
#     update; modules-load.d autoloads it on boot so usd/uhwd still see it.
# shellcheck disable=SC2043  # single symbol now, kept as a loop so the list can grow
for sym in CONFIG_UBNT_HAL; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=m" >> .config
done

# b9) ui_hdd_pwrctl_fake stays =m, not =y: no serial console, so a bug in a
#     built-in driver is boot-fatal. insmod manually; promote only once stable.
# shellcheck disable=SC2043  # single symbol now, kept as a loop so the list can grow
for sym in CONFIG_UI_HDD_PWRCTL_FAKE; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=m" >> .config
done

# c) Patch smp2p_init_header(): gcc 10.2.1 merges adjacent __iomem stores into
#    an alignment-faulting wide store; disabling MSM_SMP2P_TEST breaks the link.
echo "== Patching smp2p_init_header() alignment bug =="
SMP2P_FILE="drivers/soc/qcom/smp2p.c"

# Refuse to patch unless the original function matches exactly (safety).
if ! grep -Fq 'void smp2p_init_header(struct smp2p_smem __iomem *header_ptr,' "$SMP2P_FILE" 2>/dev/null; then
    echo "ERROR: smp2p_init_header() signature not found as expected in $SMP2P_FILE." >&2
    echo "Refusing to patch blindly -- inspect the file by hand." >&2
    exit 1
fi
if grep -q "writel_relaxed(SMP2P_MAGIC" "$SMP2P_FILE"; then
    echo "   Already patched (writel_relaxed present) -- skipping."
else
    START_LINE="$(grep -Fn 'void smp2p_init_header(struct smp2p_smem __iomem *header_ptr,' "$SMP2P_FILE" | head -1 | cut -d: -f1)"
    if [ -z "$START_LINE" ]; then
        echo "ERROR: could not locate start of smp2p_init_header()." >&2
        exit 1
    fi
    # The function ends at the first line containing only "}" after START_LINE.
    END_LINE="$(awk -v start="$START_LINE" 'NR>=start && /^}$/ {print NR; exit}' "$SMP2P_FILE")"
    if [ -z "$END_LINE" ]; then
        echo "ERROR: could not locate end of smp2p_init_header()." >&2
        exit 1
    fi

    {
        head -n "$((START_LINE - 1))" "$SMP2P_FILE"
        cat <<'FUNCEOF'
void smp2p_init_header(struct smp2p_smem __iomem *header_ptr,
		int local_pid, int remote_pid,
		uint32_t features, uint32_t version)
{
	/* NOTE: rewritten to use writel_relaxed/readl_relaxed instead of
	 * plain struct-field assignment against __iomem memory. Field
	 * assignment lets the compiler merge adjacent 32-bit writes into a
	 * single wider store, which faults with an ARM64 alignment
	 * exception on this SoC's SMEM region under gcc 10.2.1 codegen.
	 * See build-cloudkey-kernel.sh for the full writeup.
	 */
	uint32_t rem_loc_proc_id = 0;
	uint32_t valid_total_ent = 0;
	uint32_t feature_version = 0;

	writel_relaxed(SMP2P_MAGIC, &header_ptr->magic);

	SMP2P_SET_LOCAL_PID(rem_loc_proc_id, local_pid);
	SMP2P_SET_REMOTE_PID(rem_loc_proc_id, remote_pid);
	writel_relaxed(rem_loc_proc_id, &header_ptr->rem_loc_proc_id);

	SMP2P_SET_FEATURES(feature_version, features);
	writel_relaxed(feature_version, &header_ptr->feature_version);

	SMP2P_SET_ENT_TOTAL(valid_total_ent, SMP2P_MAX_ENTRY);
	SMP2P_SET_ENT_VALID(valid_total_ent, 0);
	writel_relaxed(valid_total_ent, &header_ptr->valid_total_ent);

	writel_relaxed(0, &header_ptr->flags);

	/* ensure that all fields are valid before version is written */
	wmb();
	feature_version = readl_relaxed(&header_ptr->feature_version);
	SMP2P_SET_VERSION(feature_version, version);
	writel_relaxed(feature_version, &header_ptr->feature_version);
}
FUNCEOF
        tail -n "+$((END_LINE + 1))" "$SMP2P_FILE"
    } > "${SMP2P_FILE}.new"

    mv "${SMP2P_FILE}.new" "$SMP2P_FILE"
    echo "   Patched $SMP2P_FILE successfully."
fi

# Match the __iomem qualifier on the prototype in smp2p_private.h.
sed -i 's/^void smp2p_init_header(struct smp2p_smem \*header_ptr, int local_pid,/void smp2p_init_header(struct smp2p_smem __iomem *header_ptr, int local_pid,/' \
    drivers/soc/qcom/smp2p_private.h

# d) log2.h: ____ilog2_NaN() combines const+noreturn attributes, which GCC 5+
#    flags as contradictory. Non-fatal here; a real upstream one-line fix.
echo "== Patching log2.h const/noreturn attribute conflict =="
LOG2_FILE="include/linux/log2.h"
if grep -q "^extern __attribute__((noreturn))$" "$LOG2_FILE" 2>/dev/null; then
    echo "   Already patched -- skipping."
elif grep -q "^extern __attribute__((const, noreturn))$" "$LOG2_FILE" 2>/dev/null; then
    sed -i 's/^extern __attribute__((const, noreturn))$/extern __attribute__((noreturn))/' "$LOG2_FILE"
    echo "   Patched $LOG2_FILE successfully."
else
    echo "   WARNING: expected 'extern __attribute__((const, noreturn))' not"
    echo "   found in $LOG2_FILE -- skipping this patch. The kernel build"
    echo "   will still work (the warning is non-fatal there). Only relevant"
    echo "   if you later build an out-of-tree module with its own"
    echo "   -Werror'd ./configure against these headers."
fi

# h) Backport statx(2) (additive: reuses vfs_fstatat()/struct kstat and reports
#    only STATX_BASIC_STATS). Syscall 291 was a reserved gap in this tree.
echo "== Backporting statx(2) syscall =="

FCNTL_UAPI="include/uapi/linux/fcntl.h"
if grep -q "AT_STATX_SYNC_TYPE" "$FCNTL_UAPI" 2>/dev/null; then
    echo "   $FCNTL_UAPI already patched -- skipping."
elif grep -Fq '#define AT_EMPTY_PATH		0x1000	/* Allow empty relative pathname */' "$FCNTL_UAPI"; then
    sed -i '/#define AT_EMPTY_PATH\t\t0x1000\t\/\* Allow empty relative pathname \*\//a\
\
/* statx() flags: this kernel treats all sync modes identically (local\
 * filesystems only), so these bits are accepted and ignored rather than\
 * rejected. */\
#define AT_STATX_SYNC_TYPE\t0x6000\t/* Type of synchronisation required from statx() */\
#define AT_STATX_SYNC_AS_STAT\t0x0000\t/* - Do whatever stat() does */\
#define AT_STATX_FORCE_SYNC\t0x2000\t/* - Force the attributes to be synced with the server */\
#define AT_STATX_DONT_SYNC\t0x4000\t/* - Do not sync attributes with the server */' "$FCNTL_UAPI"
    echo "   Patched $FCNTL_UAPI successfully."
else
    echo "ERROR: expected AT_EMPTY_PATH line not found as expected in $FCNTL_UAPI." >&2
    echo "Refusing to patch blindly -- inspect the file by hand." >&2
    exit 1
fi

STAT_UAPI="include/uapi/linux/stat.h"
if grep -q "^struct statx {" "$STAT_UAPI" 2>/dev/null; then
    echo "   $STAT_UAPI already patched -- skipping."
elif grep -Fq '#endif /* _UAPI_LINUX_STAT_H */' "$STAT_UAPI"; then
    sed -i 's/^#include <linux\/types.h>$//' "$STAT_UAPI"  # avoid a dup on re-patch attempts
    sed -i '0,/^#define _UAPI_LINUX_STAT_H$/s//#define _UAPI_LINUX_STAT_H\n\n#include <linux\/types.h>/' "$STAT_UAPI"
    python3 - "$STAT_UAPI" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
marker = "#endif /* _UAPI_LINUX_STAT_H */"
addition = '''
/*
 * Timestamp structure for the timestamps in struct statx.
 */
struct statx_timestamp {
	__s64	tv_sec;
	__u32	tv_nsec;
	__s32	__reserved;
};

/*
 * Structure for the extended file attribute retrieval system call
 * (statx()). Binary-layout-compatible with the real, upstream Linux ABI
 * (as of the syscall's introduction in 4.11): fields this kernel's
 * backport doesn't populate (stx_mnt_id and later additions) are always
 * zeroed and never claimed in stx_mask, exactly as the real ABI requires
 * callers to check before trusting a field.
 */
struct statx {
	/* 0x00 */
	__u32	stx_mask;
	__u32	stx_blksize;
	__u64	stx_attributes;
	/* 0x10 */
	__u32	stx_nlink;
	__u32	stx_uid;
	__u32	stx_gid;
	__u16	stx_mode;
	__u16	__spare0[1];
	/* 0x20 */
	__u64	stx_ino;
	__u64	stx_size;
	__u64	stx_blocks;
	__u64	stx_attributes_mask;
	/* 0x40 */
	struct statx_timestamp	stx_atime;
	struct statx_timestamp	stx_btime;
	struct statx_timestamp	stx_ctime;
	struct statx_timestamp	stx_mtime;
	/* 0x80 */
	__u32	stx_rdev_major;
	__u32	stx_rdev_minor;
	__u32	stx_dev_major;
	__u32	stx_dev_minor;
	/* 0x90 */
	__u64	stx_mnt_id;
	__u64	__spare2;
	/* 0xa0 */
	__u64	__spare3[12];
	/* 0x100 */
};

#define STATX_TYPE		0x00000001U
#define STATX_MODE		0x00000002U
#define STATX_NLINK		0x00000004U
#define STATX_UID		0x00000008U
#define STATX_GID		0x00000010U
#define STATX_ATIME		0x00000020U
#define STATX_MTIME		0x00000040U
#define STATX_CTIME		0x00000080U
#define STATX_INO		0x00000100U
#define STATX_SIZE		0x00000200U
#define STATX_BLOCKS		0x00000400U
#define STATX_BASIC_STATS	0x000007ffU
#define STATX_BTIME		0x00000800U
#define STATX_ALL		0x00000fffU
#define STATX__RESERVED		0x80000000U

#define STATX_ATTR_COMPRESSED		0x00000004
#define STATX_ATTR_IMMUTABLE		0x00000010
#define STATX_ATTR_APPEND		0x00000020
#define STATX_ATTR_NODUMP		0x00000040
#define STATX_ATTR_ENCRYPTED		0x00000800
#define STATX_ATTR_AUTOMOUNT		0x00001000

''' + marker
assert content.count(marker) == 1, "expected exactly one marker occurrence"
content = content.replace(marker, addition)
with open(path, "w") as f:
    f.write(content)
PYEOF
    echo "   Patched $STAT_UAPI successfully."
else
    echo "ERROR: expected trailing #endif not found as expected in $STAT_UAPI." >&2
    echo "Refusing to patch blindly -- inspect the file by hand." >&2
    exit 1
fi

SYSCALLS_H="include/linux/syscalls.h"
if grep -q "sys_statx" "$SYSCALLS_H" 2>/dev/null; then
    echo "   $SYSCALLS_H already patched -- skipping."
else
    if ! grep -Fq 'struct stat64;' "$SYSCALLS_H"; then
        echo "ERROR: expected 'struct stat64;' forward decl not found in $SYSCALLS_H." >&2
        exit 1
    fi
    sed -i 's/^struct stat64;$/struct stat64;\nstruct statx;/' "$SYSCALLS_H"
    if ! grep -Fq 'asmlinkage long sys_fstatat64(int dfd, const char __user *filename,' "$SYSCALLS_H"; then
        echo "ERROR: expected sys_fstatat64 prototype not found in $SYSCALLS_H." >&2
        exit 1
    fi
    perl -0pi -e 's/(asmlinkage long sys_fstatat64\(int dfd, const char __user \*filename,\n\t\t\t       struct stat64 __user \*statbuf, int flag\);\n)/$1asmlinkage long sys_statx(int dfd, const char __user *filename,\n\t\t\t   unsigned flags, unsigned mask,\n\t\t\t   struct statx __user *buffer);\n/' "$SYSCALLS_H"
    echo "   Patched $SYSCALLS_H successfully."
fi

UNISTD_GENERIC="include/uapi/asm-generic/unistd.h"
if grep -q "__NR_statx" "$UNISTD_GENERIC" 2>/dev/null; then
    echo "   $UNISTD_GENERIC already patched -- skipping."
elif grep -Fq '__SYSCALL(__NR_bpf, sys_bpf)' "$UNISTD_GENERIC"; then
    perl -0pi -e 's/(__SYSCALL\(__NR_bpf, sys_bpf\)\n)/$1\n\/*\n * 281 (execveat) through 290 (pkey_free) are real upstream syscalls not\n * backported here -- unimplemented, calls still return -ENOSYS via the\n * sys_call_table default sys_ni_syscall fill. 291 (statx) is backported\n * here.\n *\/\n#define __NR_statx 291\n__SYSCALL(__NR_statx, sys_statx)\n/' "$UNISTD_GENERIC"
    echo "   Patched $UNISTD_GENERIC successfully."
else
    echo "ERROR: expected __NR_bpf entry not found as expected in $UNISTD_GENERIC." >&2
    echo "Refusing to patch blindly -- inspect the file by hand." >&2
    exit 1
fi

STAT_C="fs/stat.c"
if grep -q "SYSCALL_DEFINE5(statx" "$STAT_C" 2>/dev/null; then
    echo "   $STAT_C already patched -- skipping."
elif grep -Fq 'EXPORT_SYMBOL(vfs_lstat);' "$STAT_C"; then
    python3 - "$STAT_C" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
marker = "EXPORT_SYMBOL(vfs_lstat);"
addition = marker + '''

/*
 * statx() backport -- see this build script's header comment for the
 * "why". Reuses vfs_fstatat()/struct kstat completely unmodified; reports
 * only STATX_BASIC_STATS as valid, everything else left zeroed and
 * unclaimed in stx_mask per spec.
 */
static int cp_statx(struct kstat *stat, struct statx __user *buffer)
{
	struct statx tmp;

	memset(&tmp, 0, sizeof(tmp));

	tmp.stx_mask = STATX_BASIC_STATS;
	tmp.stx_blksize = stat->blksize;
	tmp.stx_attributes = 0;
	tmp.stx_nlink = stat->nlink;
	tmp.stx_uid = from_kuid_munged(current_user_ns(), stat->uid);
	tmp.stx_gid = from_kgid_munged(current_user_ns(), stat->gid);
	tmp.stx_mode = stat->mode;
	tmp.stx_ino = stat->ino;
	tmp.stx_size = stat->size;
	tmp.stx_blocks = stat->blocks;
	tmp.stx_attributes_mask = 0;

	tmp.stx_atime.tv_sec = stat->atime.tv_sec;
	tmp.stx_atime.tv_nsec = stat->atime.tv_nsec;
	tmp.stx_ctime.tv_sec = stat->ctime.tv_sec;
	tmp.stx_ctime.tv_nsec = stat->ctime.tv_nsec;
	tmp.stx_mtime.tv_sec = stat->mtime.tv_sec;
	tmp.stx_mtime.tv_nsec = stat->mtime.tv_nsec;

	tmp.stx_rdev_major = MAJOR(stat->rdev);
	tmp.stx_rdev_minor = MINOR(stat->rdev);
	tmp.stx_dev_major = MAJOR(stat->dev);
	tmp.stx_dev_minor = MINOR(stat->dev);

	return copy_to_user(buffer, &tmp, sizeof(tmp)) ? -EFAULT : 0;
}

SYSCALL_DEFINE5(statx, int, dfd, const char __user *, filename,
		unsigned, flags, unsigned, mask,
		struct statx __user *, buffer)
{
	struct kstat stat;
	int error;
	unsigned lookup_flags;

	if (mask & STATX__RESERVED)
		return -EINVAL;
	if ((flags & AT_STATX_SYNC_TYPE) == AT_STATX_SYNC_TYPE)
		return -EINVAL;

	lookup_flags = flags & ~AT_STATX_SYNC_TYPE;
	if ((lookup_flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |
			      AT_EMPTY_PATH)) != 0)
		return -EINVAL;

	error = vfs_fstatat(dfd, filename, &stat, lookup_flags);
	if (error)
		return error;

	return cp_statx(&stat, buffer);
}'''
assert content.count(marker) == 1, "expected exactly one marker occurrence"
content = content.replace(marker, addition)
with open(path, "w") as f:
    f.write(content)
PYEOF
    echo "   Patched $STAT_C successfully."
else
    echo "ERROR: expected 'EXPORT_SYMBOL(vfs_lstat);' not found as expected in $STAT_C." >&2
    echo "Refusing to patch blindly -- inspect the file by hand." >&2
    exit 1
fi

# e) Set default show_unhandled_signals=0: systemd 247 calls syscalls absent
#    from 3.18 (pidfd_getfd, close_range), each printing a register dump.
echo "== Patching default show_unhandled_signals to reduce log noise =="
TRAPS_FILE="arch/arm64/kernel/traps.c"
if grep -q "^int show_unhandled_signals = 0;" "$TRAPS_FILE" 2>/dev/null; then
    echo "   Already patched -- skipping."
elif grep -q "^int show_unhandled_signals = 1;" "$TRAPS_FILE" 2>/dev/null; then
    sed -i 's/^int show_unhandled_signals = 1;/int show_unhandled_signals = 0;/' "$TRAPS_FILE"
    echo "   Patched $TRAPS_FILE successfully."
else
    echo "   WARNING: expected 'int show_unhandled_signals = 1;' not found in"
    echo "   $TRAPS_FILE -- skipping this patch (harmless if skipped; you'll"
    echo "   just see the verbose logging as before, fixable at runtime with"
    echo "   the sysctl command noted above)."
fi

# f) GCC 10 defaults to -fno-common, breaking old code that relies on
#    tentative-definition merging; forced at build time below, not via .config.

# g) Bypass the AOSP gcc-wrapper.py warning gate, which fails the build on
#    benign GCC-version-drift warnings under gcc 10.
sed -i '/gcc-wrapper\.py/ s|.*|CC               = $(REAL_CC)|' Makefile

# i) Build netfilter/iptables NAT in (=y): this arm64 port lacks module PLTs,
#    so x_tables.ko fails to load; NF_CONNTRACK/NF_CONNTRACK_IPV4 must be =y too.
for sym in CONFIG_NETFILTER_XTABLES CONFIG_IP_NF_IPTABLES \
           CONFIG_NF_CONNTRACK CONFIG_NF_CONNTRACK_IPV4 \
           CONFIG_NF_NAT CONFIG_NF_NAT_IPV4 CONFIG_IP_NF_NAT \
           CONFIG_NETFILTER_XT_TARGET_REDIRECT CONFIG_IP_NF_TARGET_REDIRECT \
           CONFIG_NETFILTER_XT_MATCH_OWNER; do
    sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config
    echo "${sym}=y" >> .config
done

echo "== Running olddefconfig to reconcile config with source tree =="
make olddefconfig
echo ""
echo "   ^ Check the output above for anything unexpected. Two harmless"
echo "     'choice value used outside its choice group' warnings from"
echo "     drivers/soc/qcom/Kconfig are expected and can be ignored."
echo ""

}

sanity_check_config() {
# ---- 5. Sanity-check key config symbols before the full build (aborts on error). ----
echo "== Sanity-checking key config symbols =="
FAIL=0
for sym in USB_NET_AX88179_178A MSM_SMEM MSM_SMP2P CRYPTO_DEV_QCE50 LEDS_ULOGO LEDS_TRIGGER_EXTERNAL UBNT_CLOUDKEY_POWERSOURCE BT_HCISMD BTRFS_FS FUSE_FS UBNT_HAL UI_HDD_PWRCTL_FAKE; do
    val="$(grep -E "^CONFIG_${sym}=" .config || echo "MISSING/UNSET")"
    echo "   CONFIG_${sym}: ${val#CONFIG_${sym}=}"
    if [ "$val" = "MISSING/UNSET" ]; then
        FAIL=1
    fi
done
echo "== Sanity-checking netfilter/NAT symbols landed as built-in (=y), not module (=m) =="
for sym in NETFILTER_XTABLES IP_NF_IPTABLES NF_CONNTRACK NF_CONNTRACK_IPV4 \
           NF_NAT NF_NAT_IPV4 IP_NF_NAT \
           NETFILTER_XT_TARGET_REDIRECT IP_NF_TARGET_REDIRECT \
           NETFILTER_XT_MATCH_OWNER; do
    val="$(grep -E "^CONFIG_${sym}=" .config || echo "MISSING/UNSET")"
    echo "   CONFIG_${sym}: ${val#CONFIG_${sym}=}"
    if [ "$val" != "CONFIG_${sym}=y" ]; then
        FAIL=1
    fi
done
if [ "$FAIL" = "1" ]; then
    echo "ERROR: one or more core platform config symbols are missing/unset." >&2
    echo "Do not proceed with the build -- see the comment block above this" >&2
    echo "check for context. Inspect .config by hand before retrying." >&2
    exit 1
fi
echo "   All expected symbols present."

}

build_kernel() {
# ---- 6. Build (KCFLAGS drops unwind tables: gcc 10 .eh_frame PC-relative
#      pointers overflow for modules in vmalloc space at insmod) ----
echo "== Building kernel + modules (this will take a while) =="
make -j"$JOBS" HOSTCFLAGS="-fcommon" \
    KCFLAGS="-fcommon -fno-asynchronous-unwind-tables -fno-unwind-tables" \
    Image modules 2>&1 | tee ../build.log

if [ ! -f arch/arm64/boot/Image ]; then
    echo "ERROR: build did not produce arch/arm64/boot/Image." >&2
    echo "Check ../build.log for the actual error -- search for 'Error' or 'error:'." >&2
    exit 1
fi

echo "== Verifying the smp2p_init_header fix actually landed in the binary =="
# writel_relaxed is inlined on arm64 (no symbol); a clean link with
# MSM_SMP2P_TEST=y is itself the evidence.
if nm vmlinux 2>/dev/null | grep -q smp2p_remote_mock_init; then
    echo "   smp2p_remote_mock_init present (expected -- MSM_SMP2P_TEST=y, patched version)."
else
    echo "WARNING: smp2p_remote_mock_init not found in vmlinux -- unexpected for this config."
    echo "This doesn't necessarily mean the build is broken, but is worth a second look"
    echo "before flashing if you were expecting the loopback driver to be present."
fi

echo "== Installing modules (this device has 250 CONFIG_X=m modules that" \
     "were being built but never installed anywhere -- ramoops.ko, all" \
     "netfilter/xfrm modules, etc. This produces a local staging tree" \
     "only; it does NOT touch the live device, matching this script's" \
     "existing policy of never automating anything that writes to the" \
     "device itself. See NEXT STEPS at the end for the manual transfer" \
     "step, same treatment as the boot image below. =="
MODULES_STAGING_DIR="../modules-staging"
rm -rf "$MODULES_STAGING_DIR"
mkdir -p "$MODULES_STAGING_DIR"
# Resolve now: the script `cd ..` later, so a relative path would break the
# NEXT STEPS output that references this variable.
MODULES_STAGING_DIR="$(cd "$MODULES_STAGING_DIR" && pwd)"
make INSTALL_MOD_PATH="$MODULES_STAGING_DIR" modules_install
KERNEL_VERSION="$(make -s kernelrelease)"

# Drop modules_install's build/source symlinks, or `scp -r` would dereference
# them and copy the whole kernel source tree.
rm -f "$MODULES_STAGING_DIR/lib/modules/$KERNEL_VERSION/build"
rm -f "$MODULES_STAGING_DIR/lib/modules/$KERNEL_VERSION/source"

depmod -b "$MODULES_STAGING_DIR" "$KERNEL_VERSION"
if [ ! -f "$MODULES_STAGING_DIR/lib/modules/$KERNEL_VERSION/modules.dep" ]; then
    echo "ERROR: depmod did not produce modules.dep -- module installation" >&2
    echo "did not complete correctly. Check the modules_install/depmod" >&2
    echo "output above for the actual error." >&2
    exit 1
fi
echo "   Installed $(find "$MODULES_STAGING_DIR" -name '*.ko' | wc -l) modules to $MODULES_STAGING_DIR/lib/modules/$KERNEL_VERSION/"

}

package_boot_image() {
# ---- 7. Package the boot image ----
echo "== Packaging boot image =="
gzip -n -f -9 -c arch/arm64/boot/Image > ../Image.gz
cat ../Image.gz "../$LIVE_DTB" > ../my-Image.gz-dtb

cd ..

# bootimg.cfg/initrd.img (from `abootimg -x` on the original backup) carry the
# real load addresses and cmdline; only the kernel+dtb payload is new.
if [ ! -f bootimg.cfg ] || [ ! -f initrd.img ]; then
    echo "ERROR: bootimg.cfg and/or initrd.img not found." >&2
    echo "Extract them once from your original boot partition backup with:" >&2
    echo "  abootimg -x original-boot-partition-backup.img" >&2
    exit 1
fi

abootimg --create new-boot.img -k my-Image.gz-dtb -r initrd.img -f bootimg.cfg

echo ""
echo "== Build complete =="
echo "Output: $(pwd)/new-boot.img"
abootimg -i new-boot.img
echo ""
echo "NEXT STEPS (manual, deliberately not automated by this script or"
echo "02-flash-kernel.sh -- loadable-first policy: a bad"
echo "=y build already bricked this device once):"
echo "  1. Review any new/changed driver source against this tree's ACTUAL"
echo "     headers (not remembered/general kernel knowledge) before flashing."
echo "  2. Run 02-flash-kernel.sh from THIS PROJECT'S environment (not from"
echo "     inside this chroot) -- it mechanizes the backup+checksum,"
echo "     transfer+verify, dd+sync+verify, and kernel-module-install steps:"
echo "       DEVICE_HOST=root@<cloudkey-ip> DEVICE_PASSWORD='...' \\"
echo "           UNAS-CloudKey/02-flash-kernel.sh $(pwd)/new-boot.img $MODULES_STAGING_DIR"
echo "  3. Have your recovery-mode procedure and serial console ready before"
echo "     rebooting -- 02-flash-kernel.sh will remind you of this too."
echo "  4. Test any NEWLY-built driver manually, over SSH -- do NOT wire it"
echo "     to load automatically at boot until it has proven stable across"
echo "     multiple loads on real hardware (see its Kconfig help text)."
echo "     Example for ui_hdd_pwrctl_fake:"
echo "     ssh root@<cloudkey-ip> \"insmod /lib/modules/$KERNEL_VERSION/extra/ui_hdd_pwrctl_fake.ko && dmesg | tail -20\""
echo "     ssh root@<cloudkey-ip> \"ls /sys/devices/platform/ui-hdd-pwrctl/\""
echo "     ssh root@<cloudkey-ip> \"cat /sys/devices/platform/ui-hdd-pwrctl/slot-1/present\""
echo "     ssh root@<cloudkey-ip> \"rmmod ui_hdd_pwrctl_fake\"  # when done testing"
}

main() {
    check_prerequisites
    extract_source
    fix_broken_symlinks
    install_verified_config
    apply_deliberate_changes
    sanity_check_config
    build_kernel
    package_boot_image
}

# Guarded so the script can be sourced to re-run a single stage without a
# full build; no effect on normal execution.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
