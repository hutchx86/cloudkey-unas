#!/bin/bash
# Installed as /usr/local/sbin/patch-drive-ws-conf.sh.
#
# unifi-core regenerates shared-runnable-drive.conf from its template on every
# restart/reboot, wiping the Drive-crash sub_filter/location fix; this reapplies
# it, triggered by drive-ws-conf-watch.path/.service. Idempotent via a marker;
# flocked because the watcher can race a manual run into double-inserting.

set -euo pipefail

CONF=/data/unifi-core/config/http/shared-runnable-drive.conf
MARKER="# --- BEGIN identity-spoof compat fix ---"
LOCK=/run/patch-drive-ws-conf.lock

exec 9>"$LOCK"
flock -n 9 || exit 0

[[ -f "$CONF" ]] || { echo "patch-drive-ws-conf: $CONF not present yet -- nothing to patch (the watcher re-applies once unifi-core creates it)" >&2; exit 0; }

if grep -qF "$MARKER" "$CONF"; then
    exit 0
fi

# 1. Inject the general sub_filter block just after the `location /proxy/drive/ {` line.
awk -v marker="$MARKER" '
    /location \/proxy\/drive\/ \{/ {
        print
        print marker
        print "    proxy_set_header Accept-Encoding \"\";"
        print "    sub_filter_types application/json;"
        print "    sub_filter_once off;"
        print "    sub_filter \"\\\"displayableRaidLevels\\\":null\" \"\\\"displayableRaidLevels\\\":[\\\"single\\\",\\\"raid0\\\",\\\"raid1\\\",\\\"raid4\\\",\\\"raid5\\\",\\\"raid6\\\",\\\"raid10\\\"]\";"
        print "    sub_filter \"\\\"preferRaidLevels\\\":null\" \"\\\"preferRaidLevels\\\":[\\\"single\\\",\\\"raid0\\\",\\\"raid1\\\",\\\"raid4\\\",\\\"raid5\\\",\\\"raid6\\\",\\\"raid10\\\"]\";"
        print "    sub_filter \"\\\"networkInterfaces\\\":null\" \"\\\"networkInterfaces\\\":[]\";"
        print "    sub_filter \"\\\"storagePoolIds\\\":null\" \"\\\"storagePoolIds\\\":[]\";"
        print "    sub_filter \"\\\"rsyncAccount\\\":null\" \"\\\"rsyncAccount\\\":{}\";"
        print "    sub_filter \"\\\"sharedDrives\\\":null\" \"\\\"sharedDrives\\\":[]\";"
        print "    sub_filter \"\\\"personalDrives\\\":null\" \"\\\"personalDrives\\\":[]\";"
        print "    sub_filter \"\\\"raidGroupCountLimit\\\":null\" \"\\\"raidGroupCountLimit\\\":0\";"
        next
    }
    { print }
' "$CONF" > "$CONF.tmp"

# 2. Insert the exact-match block for the whole-object-null mydrive endpoint
#    (`location =` beats the `/proxy/drive/` prefix); brace-depth tracked, not EOF-appended.
awk '
    /location \/proxy\/drive\/ \{/ { in_block=1; depth=0 }
    in_block {
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        print
        if (depth == 0) {
            in_block = 0
            print ""
            print "    location = /proxy/drive/api/v1/encryption/mydrive {"
            print "        proxy_set_header Accept-Encoding \"\";"
            print "        sub_filter_types application/json;"
            print "        sub_filter_once off;"
            print "        sub_filter \"\\\"data\\\":null\" \"\\\"data\\\":{}\";"
            print "        include /usr/share/unifi-core/http/cors.conf;"
            print "        include /usr/share/unifi-core/http/security.conf;"
            print "        include /usr/share/unifi-core/http/auth.conf;"
            print "        include /usr/share/unifi-core/http/proxy.conf;"
            print "        proxy_pass http://drive_api_backend/api/v1/encryption/mydrive;"
            print "    }"
        }
        next
    }
    { print }
' "$CONF.tmp" > "$CONF.tmp2"
mv "$CONF.tmp2" "$CONF.tmp"

mv "$CONF.tmp" "$CONF"

nginx -t && systemctl reload nginx
