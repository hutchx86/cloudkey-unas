#!/bin/bash
# Installed as /sbin/mkfs.btrfs (real binary at /sbin/mkfs.btrfs.real).
#
# usd hardcodes `-s 65536 -n 65536` for 64K-page UNAS hardware, but this
# device's 3.18.44 kernel uses 4K pages and requires sectorsize == PAGE_SIZE
# (else the final mount fails). Strips those options, forces -s 4096 -n 4096.

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
