#!/bin/bash
# Installed as /bin/mount (real binary moved to /bin/mount.real).
#
# usd hardcodes `-o relatime,space_cache=v2,nodatacow,nodatasum` for every
# btrfs mount. `space_cache=v2` (the free-space-tree feature) was added in
# Linux 4.5; this device's 3.18.44 kernel predates it and rejects the whole
# mount with EINVAL ("unrecognized mount option 'space_cache=v2'"). Strip
# just that one token, whatever form it arrives in, and pass everything
# else through unchanged.
#
# GOTCHA (found the hard way): the bash `case` pattern `-o*)` also matches
# the bare argument `-o` on its own (glob `*` matches zero characters too),
# which swallows the separate-arg form (`-o value`) before it ever reaches
# the intended `-o)` branch. The exact `-o)` case MUST be checked first,
# then `-o?*)` (requires at least one more character) second.

args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    -o)
      next=$((i+1))
      if [[ "${args[$next]}" == *space_cache=v2* ]]; then
        opt=$(echo ",${args[$next]}," | sed -E 's/,space_cache=v2,/,/g; s/^,//; s/,$//')
        args[$next]="$opt"
      fi
      ;;
    -o?*)
      opt="${args[$i]#-o}"
      if [[ "$opt" == *space_cache=v2* ]]; then
        opt=$(echo ",$opt," | sed -E 's/,space_cache=v2,/,/g; s/^,//; s/,$//')
        args[$i]="-o$opt"
      fi
      ;;
  esac
done

exec /bin/mount.real "${args[@]}"
