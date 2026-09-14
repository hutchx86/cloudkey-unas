# Credits & third-party notices

## Special thanks

Special thanks to **dciancu** for
[unifi-protect-unvr-docker-arm64](https://github.com/dciancu/unifi-protect-unvr-docker-arm64).
That project was the direct inspiration for this one: it showed the approach
was viable, and much of what was needed to get it working was learned from it.
This project would not exist in its current form without it.

## Reference project

The original approach — binwalk-extract a UniFi firmware image, `dpkg-repack`
the installed packages back into real `.deb`s, and install them into a plain
Debian base against Ubiquiti's own apt repo — was adapted from:

- **dciancu/unifi-protect-unvr-docker-arm64** — https://github.com/dciancu/unifi-protect-unvr-docker-arm64

That project is **not** vendored or redistributed in this repository (it has
no license file). It was used as a reference for the mechanism only; the
early version of this project's Docker pipeline is preserved only in the
author's private notes. All credit for the underlying technique goes there.

## GPL-2.0 kernel code

`UNAS-CloudKey/custom-drivers/` contains third-party GPL-2.0 driver code and
clean-room drivers written for this project. Original copyright/license
headers are retained.

- `fbtft-core.c`, `fbtft.h`, `fbtft-bus.c`, `fbtft-io.c`, `fbtft-sysfs.c` —
  taken **verbatim** (byte-identical, unmodified) from **notro/fbtft**
  (https://github.com/notro/fbtft), Noralf Tronnes's out-of-tree fbtft
  driver later mainlined as `drivers/staging/fbtft`. Copyright (C) 2013
  Noralf Tronnes; GPL-2.0-or-later.
- `hci_smd.c` — Qualcomm/CodeAurora `msm` HCI shared-memory driver
  (GPL-2.0), as shipped in Android's `kernel/msm`
  (https://android.googlesource.com/kernel/msm). This copy is the
  `linux-qcom-apq8053-3.18.44-ui-qcom` version, ported (include path + a few
  HCI/SMD API changes) for this tree. Copyright (c) 2000-2012 Code Aurora
  Forum; Copyright (C) 2002-2003 Maxim Krasnyansky; Copyright (C) 2004-2006
  Marcel Holtmann; MODULE_AUTHOR Ankur Nandwani.
- `ubnthal.c`, `ui_hdd_pwrctl_fake.c`, `cloudkey-power.c`, `fb_sp8110.c`,
  `leds-ulogo.c`, `ledtrig-external.c` — clean-room drivers written for this
  project (SPDX `GPL-2.0-only`; Copyright (C) 2026 the CloudKey UNAS project
  authors). Their behavior was reconstructed from the stock kernel /
  disassembly, not from Ubiquiti source.

These are kernel modules and therefore link against the Linux kernel
(GPL-2.0-only), which is why this project is licensed GPL-2.0-only.

## Firmware / packages

Ubiquiti firmware images and packages downloaded by these scripts remain the
property of Ubiquiti Inc. and are subject to their terms. Nothing proprietary
is redistributed here. "UniFi", "Cloud Key", "UniFi Drive" and "UNAS" are
trademarks of Ubiquiti Inc. This project is not affiliated with or endorsed
by Ubiquiti.
