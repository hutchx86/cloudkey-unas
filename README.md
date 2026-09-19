# CloudKey UNAS — run UniFi Drive on a Cloud Key Gen 2 Plus

<div align="center">

<a href="LICENSE"><img src="https://img.shields.io/github/license/hutchx86/cloudkey-unas" alt="License"></a>

**Runs Ubiquiti's genuine UniFi Drive stack on a stock UniFi Cloud Key Gen 2 Plus (UCKP).**
**A custom 3.18.44 kernel and clean-room drivers present the console as a NAS-class
board so `unifi-core` will enable Drive — on the real hardware, over SSH, with no
Docker or emulation layer.**

</div>

> [!WARNING]
> This project flashes a custom kernel, modifies the device's root filesystem, and
> can format storage. You can **brick the console, lose data, and void
> warranties**. Proceed only on hardware you own. See [Disclaimer](#disclaimer).

> [!CAUTION]
> **Never click "Eject USB drive"** (Drive WebUI → **All files**). It ejects the
> disk backing the Drive database/pool and can corrupt or lose the storage
> database with no clean way back.

> [!NOTE]
> Not affiliated with Ubiquiti Inc. No Ubiquiti firmware or binaries are
> distributed here — you supply your own. Built with AI assistance under human
> review. See [Legal](#legal).

## Quick start

The custom kernel is built and flashed by hand first (see
[Install / Usage](#install--usage)). Once it is, provisioning the Drive stack is
one command:

```
git clone https://github.com/hutchx86/cloudkey-unas && cd cloudkey-unas
scripts/fetch-firmware-debs.sh
DEVICE_HOST=root@<cloudkey-ip> DEVICE_PASSWORD='...' \
  UNAS-CloudKey/provision-all.sh
```

## At a glance

|  |  |
| --- | --- |
| **What** | Ubiquiti's genuine UniFi Drive stack running on a Cloud Key Gen 2 Plus |
| **Hardware** | UniFi Cloud Key Gen 2 Plus (UCKP, Qualcomm APQ8053) |
| **Interface** | SSH for provisioning; the on-device Drive stack itself is Ubiquiti's, untouched |
| **Language** | Bash + Python (pipeline), C (kernel modules) |
| **Status** | Working and verified on real hardware; proof of concept |
| **License** | GPL-2.0-only |

## How it compares

|  | Genuine UNAS Pro | This project |
| --- | --- | --- |
| **What it is** | Ubiquiti's standalone NAS appliance | A Cloud Key Gen 2 Plus presented as a NAS-class board |
| **Hardware** | Native NAS SoC + drive backplane | Stock UCKP (APQ8053) + a USB/SATA disk |
| **Cost** | Buy a UNAS Pro | An already-owned Cloud Key |
| **Fidelity** | Native and supported | Proof of concept — custom kernel + identity spoof, not production-ready |

## How it works

`unifi-core` refuses to enable Drive on a stock Cloud Key: it gates the app on the
device identifying as a NAS-class board. This project rebuilds the 3.18.44 vendor
kernel with the drivers such a board exposes, and adds a fix layer over the
installed Ubiquiti packages that spoofs that identity — `/proc/ubnthal` in the
kernel, and a `ubnt-tools` wrapper plus a frame-aware hardware relay in userspace.
The Drive stack itself is Ubiquiti's own, installed from pinned `.deb`s; nothing
is emulated.

<img src="docs/images/architecture.svg" width="720" alt="Architecture: Drive stack and identity/fix layer over a custom kernel on Cloud Key hardware">

| Component | Language | Role |
| --- | --- | --- |
| `UNAS-CloudKey/` | Bash | Build + provisioning pipeline (`00`..`05`, `provision-all.sh`) |
| `UNAS-CloudKey/custom-drivers/` | C | Kernel drivers: `ubnthal` identity, fake HDD-bay presence, display, LEDs, power-source, Bluetooth |
| `UNAS-CloudKey/lib/wrappers/` | Python / Bash | `ubnt-tools` identity wrapper, frame-aware hardware relay, mount/mkfs wrappers |
| `scripts/` | Bash / Python | Firmware/deb repack helpers and lint |

## Supported hardware

| Model | SoC / variant | Status | Notes |
| --- | --- | --- | --- |
| Cloud Key Gen 2 Plus (`UCKP`) | Qualcomm APQ8053 | Verified | Drive stack installed and btrfs pool mounted; `05-verify.sh` passes |
| Cloud Key Gen 2 | Qualcomm APQ8053 | Untested | Identical kernel config, but no drive bay; not exercised |

## Features

- **Genuine Drive stack** — Ubiquiti's own packages; no userspace reimplementation.
- **Custom 3.18.44 kernel** — built from Ubiquiti's GPL source, with the missing
  CloudKey drivers, btrfs, FUSE, and a `statx(2)` backport.
- **Identity layer** — `/proc/ubnthal` in the kernel plus a `ubnt-tools` wrapper
  and frame-aware relay in userspace present a NAS-class board.
- **Idempotent provisioning** — `provision-all.sh` installs, fixes, reboots, and
  verifies; every step is safe to re-run.
- **No Docker** — everything runs directly on the real hardware over SSH.

## Requirements

- A UniFi Cloud Key Gen 2 Plus, **and its root password**.
- A Linux machine with SSH access to the device (the build host can be the same
  machine).
- A Debian bullseye build host for the custom kernel (see
  `UNAS-CloudKey/00-create-chroot.sh`). Bullseye matters: the kernel is built
  with gcc 10.2.1.
- Network access to Ubiquiti's public firmware API and the companion
  kernel-source repo. The scripts download and checksum-verify; nothing is
  redistributed here.

## Repository layout

```
UNAS-CloudKey/   build + provisioning pipeline (00..05, provision-all.sh)
    custom-drivers/   kernel drivers (GPL-2.0; see CREDITS.md)
    lib/              SSH helper + on-device wrappers
scripts/         firmware repack helpers + lint
fw_picked/       package lists; binaries are regenerated, not stored
docs/images/     README assets
```

## Install / Usage

Everything runs from `UNAS-CloudKey/`; the `0N` prefixes are the pipeline order.
`00`–`02` build and flash the kernel (build host + SSH); `03`–`05` install, fix,
and verify the Drive stack (on the device, orchestrated by `provision-all.sh`).
Each script is idempotent and safe to re-run.

**Prerequisite — regenerate the pinned packages.** The ~320 MB of Ubiquiti `.deb`s
are not stored in the repo, and `03` needs them. Fetch the pinned set (downloads
and checksum-verifies the firmware; needs `wget`, `unsquashfs`, `dpkg-deb`):

```
scripts/fetch-firmware-debs.sh
```

### 00 — Create the bullseye chroot (once, on the build host)

```
UNAS-CloudKey/00-create-chroot.sh        # root; debootstraps bullseye + toolchain
```

### 01 — Build the custom kernel (inside the chroot)

Set `KERNEL_SRC_REPO` to the companion kernel-source repo, or supply a local
tarball/GPL bundle (see the script header). Run it from the directory holding
`verified-running.config` and `cloudkey-live.dtb`:

```
KERNEL_SRC_REPO=https://github.com/hutchx86/ckg2plus-kernel-src.git \
  UNAS-CloudKey/01-build-kernel.sh
```

It writes `new-boot.img` and a `modules-staging/` tree, and prints the exact `02`
command to run next.

### 02 — Flash the kernel (from your machine, to the device)

```
DEVICE_HOST=root@<cloudkey-ip> DEVICE_PASSWORD='...' \
  UNAS-CloudKey/02-flash-kernel.sh <path>/new-boot.img <path>/modules-staging
```

It backs up the current boot partition, verifies the transfer, and then asks you
to type `yes`. For scripted runs set `FLASH_CONFIRM=yes` (this skips a safety
confirmation — only do so if you are sure).

### provision-all.sh — install, fix, reboot, verify (device)

```
DEVICE_HOST=root@<cloudkey-ip> DEVICE_PASSWORD='...' \
  UNAS-CloudKey/provision-all.sh
```

This syncs to the device, runs `03-install-drive-stack.sh` and
`04-apply-drive-fixes.sh`, reboots, and runs `05-verify.sh`. The individual
`03`/`04`/`05` scripts can also be run directly on the device.

## Verification

- Static checks: `scripts/lint.sh` (`bash -n`, `shellcheck`, Python compile).
- Device state: `UNAS-CloudKey/05-verify.sh` (kernel, modules, identity, Drive
  API, relay, pool mount, failed units).

## Roadmap / known limitations

- **Known:** proof of concept, not production-ready — see [Disclaimer](#disclaimer).
- **Known:** first-time storage-pool creation is a manual WebUI action
  ("Add Drives"); no script performs it.
- **Known:** installing an app through the `unifi.ui.com` cloud portal fails;
  installing by direct URL works.
- **Known:** untested kernel drivers ship as loadable modules and must be
  exercised before being promoted to built-in.

## Troubleshooting

<details>
<summary><b>Troubleshooting / FAQ</b></summary>

**`provision-all.sh` aborts with "is running kernel ..., expected
`3.18.44-btrfscustom`"** — the custom kernel isn't flashed yet. Build and flash
it with `01`/`02` first.

**Drive refuses to enable, or shows no storage** — same cause: the stock kernel
is still running. Check `uname -r` on the device.

**Drive file and folder listings return HTTP 500** — the kernel lacks the
`statx(2)` backport; use the kernel built by `01-build-kernel.sh`, which includes
it.

</details>

## Credits

Special thanks to [dciancu](https://github.com/dciancu) for
[unifi-protect-unvr-docker-arm64](https://github.com/dciancu/unifi-protect-unvr-docker-arm64) —
the direct inspiration for this project, and the reference for the original
firmware-extract / `dpkg-repack` approach.

Third-party kernel code and its licenses are listed in [CREDITS.md](CREDITS.md).

<details>
<summary><b>Legal</b></summary>

- **Not affiliated with, or endorsed by, Ubiquiti Inc.** "UniFi", "Cloud Key",
  "UniFi Drive", and "UNAS" are trademarks of Ubiquiti Inc.
- **No Ubiquiti binaries or firmware are distributed here.** The scripts
  download firmware and packages from Ubiquiti's public endpoints or expect you
  to provide them. Redistributing Ubiquiti packages may be subject to Ubiquiti's
  terms — don't.
- This project is intended for interoperability and personal use on hardware you
  own. Reverse engineering may be restricted in your jurisdiction; you are
  responsible for how you use it.

</details>

<details>
<summary><b>Disclaimer</b></summary>

**This is a proof-of-concept project, not a production-ready system**, and it is
**not recommended for an actual production system**. Large parts were produced
with LLMs (Claude Code and DeepSeek) under strict human supervision and testing —
review and verify everything yourself. **This software is provided "as is",
without warranty of any kind.** It performs invasive operations: flashing a custom
kernel, modifying the root filesystem, and interacting with storage. There is a
genuine risk of **bricking the device, rendering it unbootable, losing data, or
permanently damaging hardware**. Recovery may require physical access and a
recovery console, and is never guaranteed.

By using this project you accept full responsibility for any damage, data loss,
downtime, or other consequences. **The authors and contributors are not
responsible or liable for any loss or damage arising from its use.** Only proceed
if you understand the risks and are working on hardware you own.

</details>

## Security

Report vulnerabilities privately through
[GitHub Security Advisories](../../security/advisories/new). No credentials are
stored in the repository: the device root password is passed in via the
`DEVICE_PASSWORD` environment variable.

## License

GPL-2.0-only. See [LICENSE](LICENSE). The kernel drivers in
`UNAS-CloudKey/custom-drivers/` derive from GPL-2.0 sources (mainline `fbtft`,
Qualcomm/CodeAurora `hci_smd`) and declare `MODULE_LICENSE("GPL")`, which is why
the project as a whole is GPL-2.0.
