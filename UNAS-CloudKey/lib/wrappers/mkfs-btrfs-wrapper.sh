#!/bin/bash
# Installed as /sbin/mkfs.btrfs (real binary moved to /sbin/mkfs.btrfs.real).
#
# usd hardcodes `mkfs.btrfs -s 65536 -n 65536 <device>` -- sector/node size
# tuned for real UNAS/UNAS-Pro hardware's 64K-page kernel. This device's
# 3.18.44 kernel runs 4K pages, and its btrfs code only accepts
# sectorsize == PAGE_SIZE. Without this wrapper: RAID -> PV -> VG -> LV all
# succeed, then the final mount fails ("Incompatible sector size(65536)").
#
# Reconstructed from documented behavior (strips -s/--sectorsize/-n/
# --nodesize/--leafsize, forces -s 4096 -n 4096, passes everything else
# through), not saved verbatim. Verify against the live /sbin/mkfs.btrfs on
# the device before reinstalling from scratch.

set -euo pipefail

REAL=/sbin/mkfs.btrfs.real
args=("$@")
out=()
i=0
n=${#args[@]}
while (( i < n )); do
    a="${args[$i]}"
    case "$a" in
        -s|-n|-l|--sectorsize|--nodesize|--leafsize)
            # option + separate value -- drop both
            i=$(( i + 2 ))
            ;;
        --sectorsize=*|--nodesize=*|--leafsize=*)
            # glued form -- drop just this one token
            i=$(( i + 1 ))
            ;;
        *)
            out+=("$a")
            i=$(( i + 1 ))
            ;;
    esac
done

exec "$REAL" -s 4096 -n 4096 "${out[@]}"
