# CloudKey UNAS (CloudKey Gen 2 Plus to UNAS conversion, (sort of))

Run Ubiquiti's **genuine UniFi Drive** stack on a stock **UniFi Cloud Key
Gen 2 Plus (UCKP)** — hardware Ubiquiti never sold as a NAS. Everything runs
on the real device over SSH; there is no Docker/emulation layer.

This is a reverse-engineering / interoperability **proof of concept**. It
builds a custom 3.18.44 kernel, presents the Cloud Key as a NAS-class board
so `unifi-core` will enable Drive, and installs Ubiquiti's own packages. It
is **not** recommended for a real production system.

> **⚠ Warning — this can damage your device.** The project flashes a custom
> kernel and modifies the device's root filesystem, and the process can
> format storage. You can **brick the console**, **lose data**, and **void
> warranties**. Proceed only on hardware you own, at your own risk. See
> [Disclaimer](#disclaimer).

> **⛔ NEVER click "Eject USB drive"** (Drive WebUI → **All files**). Under
> no circumstances do this: it ejects the disk backing the Drive
> database/pool and will cause issues with the storage database, potentially
> corrupting or losing it, with no clean way back.

> **Not affiliated with Ubiquiti Inc.** This repository contains **no
> Ubiquiti binaries or firmware**. You must supply your own firmware images
> and packages; see [Legal](#legal).

> **AI-assisted development.** Large parts of this project were produced with
> LLMs (Claude Code and DeepSeek), always under strict human supervision,
> review, and real-hardware testing. Still, verify anything you rely on.

## Status

Working and verified on real hardware: the device runs the custom kernel with
the Drive stack installed and a btrfs pool mounted, and
`UNAS-CloudKey/05-verify.sh` passes.

## Requirements

- A UniFi Cloud Key Gen 2 Plus, **and its root password**.
- A Debian bullseye build host for the custom kernel (see
  `UNAS-CloudKey/00-create-chroot.sh`). Bullseye matters: the kernel is built
  with gcc 10.2.1.
- Your own copies of the relevant Ubiquiti firmware `.bin` files (downloaded
  from Ubiquiti's public firmware API) to regenerate the package debs.

## Repository layout

```
UNAS-CloudKey/   build + provisioning pipeline (00..05, provision-all.sh)
    custom-drivers/   kernel drivers (GPL-2.0; see CREDITS.md)
    lib/              SSH helper + on-device wrappers
scripts/         firmware repack helpers + lint
fw_picked/       package lists (binaries are regenerated, not stored)
```

## Usage

Everything is driven by the scripts in `UNAS-CloudKey/`. Steps 3–5 run
against the real console; steps are ordered and each is safe to re-run.

**1. Kernel source.** `01-build-kernel.sh` fetches Ubiquiti's GPL-2.0 kernel
source from the companion repo automatically via `KERNEL_SRC_REPO`
(default URL in the script header; a local tarball/bundle also works):

```
KERNEL_SRC_REPO=https://github.com/hutchx86/ckg2plus-kernel-src.git
```

**2. Drive package debs.** Rebuild the pinned packages from firmware (they
are not stored in the repo):

```
scripts/fetch-firmware-debs.sh
```

**3. Build the custom kernel** (on the bullseye build host):

```
UNAS-CloudKey/00-create-chroot.sh        # once, to create the chroot
# then, inside the chroot:
KERNEL_SRC_REPO=https://github.com/hutchx86/ckg2plus-kernel-src.git \
  UNAS-CloudKey/01-build-kernel.sh
```

It writes `new-boot.img` and a `modules-staging/` tree, and prints the exact
`02-flash-kernel.sh` command to run next.

**4. Flash the kernel** (from your own machine, to the device):

```
DEVICE_HOST=root@<cloudkey-ip> DEVICE_PASSWORD='...' \
  UNAS-CloudKey/02-flash-kernel.sh <path>/new-boot.img <path>/modules-staging
```

It backs up the current boot partition, verifies the transfer, and then asks
you to type `yes`. For scripted runs set `FLASH_CONFIRM=yes` (this skips a
safety confirmation — only do so if you are sure).

**5. Provision and verify:**

```
DEVICE_HOST=root@<cloudkey-ip> DEVICE_PASSWORD='...' \
  UNAS-CloudKey/provision-all.sh
```

This syncs to the device, installs the Drive stack, applies the fix layer,
reboots, and runs `05-verify.sh`.

## Verification

- Static checks: `scripts/lint.sh` (`bash -n`, `shellcheck`, Python compile).
- Device state: `UNAS-CloudKey/05-verify.sh` (kernel, modules, identity,
  Drive API, relay, pool mount, failed units).

## Legal

- **Not affiliated with, or endorsed by, Ubiquiti Inc.** "UniFi", "Cloud
  Key", "UniFi Drive", and "UNAS" are trademarks of Ubiquiti Inc.
- **No Ubiquiti binaries or firmware are distributed here.** The scripts
  download firmware and packages from Ubiquiti's public endpoints or expect
  you to provide them. Redistributing Ubiquiti packages may be subject to
  Ubiquiti's terms — don't.
- This project is intended for interoperability and personal use on hardware
  you own. Reverse engineering may be restricted in your jurisdiction; you
  are responsible for how you use it.
- See [CREDITS.md](CREDITS.md) for third-party code and inspiration.

## Disclaimer

**This is a proof-of-concept project, not a production-ready system**, and it
is **not recommended for an actual production system**. Large parts were
produced with LLMs (Claude Code and DeepSeek) under strict human supervision
and testing — review and verify everything yourself. **This software is
provided "as is", without warranty of any kind.** It performs invasive
operations: flashing a custom kernel, modifying the root filesystem, and
interacting with storage. There is a genuine risk of **bricking the device,
rendering it unbootable, losing data, or permanently damaging hardware**.
Recovery may require physical access and a recovery console, and is never
guaranteed.

By using this project you accept full responsibility for any damage, data
loss, downtime, or other consequences. **The authors and contributors are
not responsible or liable for any loss or damage arising from its use.**
Only proceed if you understand the risks and are working on hardware you own.

## License

GPL-2.0-only. See [LICENSE](LICENSE). The kernel drivers in
`UNAS-CloudKey/custom-drivers/` derive from GPL-2.0 sources (mainline
`fbtft`, Qualcomm/CodeAurora `hci_smd`) and declare `MODULE_LICENSE("GPL")`,
which is why the project as a whole is GPL-2.0.
