#!/bin/bash
# Installed as /bin/mount (real binary at /bin/mount.real).
#
# usd hardcodes `-o relatime,space_cache=v2,nodatacow,nodatasum`; space_cache=v2
# needs Linux 4.5 and this 3.18.44 kernel rejects the mount with EINVAL, so strip
# that token in any form and pass the rest through.
# GOTCHA: `-o*)` also matches bare `-o` (glob `*` matches zero chars), so test
# `-o)` before `-o?*)` or the separate-arg form is swallowed.

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
