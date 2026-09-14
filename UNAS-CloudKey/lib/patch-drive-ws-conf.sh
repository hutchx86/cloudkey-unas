#!/bin/bash
# Installed as /usr/local/sbin/patch-drive-ws-conf.sh.
#
# unifi-core regenerates /data/unifi-core/config/http/shared-runnable-drive.conf
# from its own internal template on every service restart AND every device
# reboot, silently wiping any hand-edited sub_filter/location additions.
# This script re-applies the Drive-crash fix and is meant to run every time
# that file changes, via the drive-ws-conf-watch.path/.service pair this
# project installs alongside it.
#
# Idempotent: guarded by a marker comment, safe to run any number of times.
# LOCKED: a real race was hit here -- running this manually while the
# path-watcher was also enabled let both invocations see "no marker yet" and
# both insert, duplicating every sub_filter/location block and breaking
# `nginx -t`. Always assume the watcher will fire on any manual edit to the
# target file.

set -euo pipefail

CONF=/data/unifi-core/config/http/shared-runnable-drive.conf
MARKER="# --- BEGIN identity-spoof compat fix ---"
LOCK=/run/patch-drive-ws-conf.lock

exec 9>"$LOCK"
flock -n 9 || exit 0

[[ -f "$CONF" ]] || { echo "patch-drive-ws-conf: $CONF not found" >&2; exit 1; }

if grep -qF "$MARKER" "$CONF"; then
    exit 0
fi

# 1. Inject the general sub_filter block right after the opening brace of
#    the existing `location /proxy/drive/ {` block.
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

# 2. Insert the more-specific exact-match block for the whole-object-null
#    mydrive endpoint (nginx picks the longest/most specific matching
#    location, so `location =` wins over the `location /proxy/drive/`
#    prefix for this one path), immediately after the matching closing
#    brace of the `location /proxy/drive/` block -- tracked by brace depth
#    rather than a blind end-of-file append, so this stays inside whatever
#    context (server{}) actually contains it.
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
