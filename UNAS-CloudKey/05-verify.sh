#!/bin/bash
# 05-verify.sh
#
# Checks a provisioned Cloud Key's health: kernel, kernel modules, identity,
# Drive API reachability, the frame-aware hardware-identity relay, pool
# mount, and failed units.
#
# Identity is checked via unifi-core's own no-auth API, never the CLI: a
# direct `ubnt-tools id` call always shows the safe NAS-spoofed default
# regardless of what unifi-core itself sees, by the v2 wrapper's own
# caller-differentiated design.
#
# Can be run standalone (just check current device health) as well as by
# provision-all.sh at the end of a full provisioning run.
#
# Usage (standalone):
#   DEVICE_HOST=root@10.10.10.61 DEVICE_PASSWORD='...' ./05-verify.sh
# Usage (reusing an already-established SSH ControlMaster, e.g. from
# provision-all.sh, or one you set up yourself via lib/ssh_master.py):
#   DEVICE_HOST=root@10.10.10.61 SSH_CONTROL_SOCKET=/tmp/ck_ssh_ctrl.sock ./05-verify.sh
#
# Prints a pass/fail report; does not abort on an individual check failing
# (these are diagnostic, not preconditions for each other) -- the point is
# to report every discrepancy at once. Exits 0 if everything passed, 1
# otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE_HOST="${DEVICE_HOST:?set DEVICE_HOST, e.g. root@10.10.10.61}"
SSH_CONTROL_SOCKET="${SSH_CONTROL_SOCKET:-/tmp/ck_ssh_ctrl.sock}"
EXPECT_KERNEL="3.18.44-btrfscustom"

# sshd is reachable well before unifi-core/nginx finish initializing after a
# reboot -- the two service-level checks below retry for up to this long
# before being reported as a real failure.
SERVICE_READY_TIMEOUT_SECS="${SERVICE_READY_TIMEOUT_SECS:-90}"
SERVICE_READY_POLL_INTERVAL_SECS="${SERVICE_READY_POLL_INTERVAL_SECS:-10}"

log() { echo "[verify] $*"; }
fail() { echo "[verify] ERROR: $*" >&2; exit 1; }

ssh_dev() { ssh -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" "$@"; }

# If no live ControlMaster socket is already present (e.g. this is being run
# standalone rather than chained from provision-all.sh, which sets one up
# itself), establish one -- needs DEVICE_PASSWORD in that case.
ensure_control_socket() {
    if ssh -O check -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" 2>/dev/null; then
        return 0
    fi
    : "${DEVICE_PASSWORD:?no live SSH ControlMaster at $SSH_CONTROL_SOCKET and DEVICE_PASSWORD not set -- either export DEVICE_PASSWORD so this script can establish one, or pre-establish one yourself: python3 $SCRIPT_DIR/lib/ssh_master.py $DEVICE_HOST '<password>' $SSH_CONTROL_SOCKET}"
    log "establishing SSH ControlMaster to $DEVICE_HOST"
    if ! python3 "$SCRIPT_DIR/lib/ssh_master.py" "$DEVICE_HOST" "$DEVICE_PASSWORD" "$SSH_CONTROL_SOCKET"; then
        fail "could not establish SSH ControlMaster to $DEVICE_HOST -- do NOT retry rapidly if this just followed a dropped connection (sshd's PerSourcePenalties can lock out both this and the user's own session at once)"
    fi
}

verify_final_state() {
    log "verifying final state"
    local failures=0

    local kver
    kver="$(ssh_dev uname -r)"
    if [[ "$kver" == "$EXPECT_KERNEL" ]]; then
        log "  OK: kernel is $kver"
    else
        log "  FAIL: kernel is '$kver', expected '$EXPECT_KERNEL'"
        failures=$((failures + 1))
    fi

    local lsmod_out
    lsmod_out="$(ssh_dev lsmod)"
    for mod in ui_hdd_pwrctl_fake ubnthal; do
        if grep -q "^$mod" <<<"$lsmod_out"; then
            log "  OK: $mod loaded"
        else
            log "  FAIL: $mod not loaded"
            failures=$((failures + 1))
        fi
    done

    # sshd comes up well before unifi-core/nginx finish initializing after a
    # reboot; retry both service-level checks up to SERVICE_READY_TIMEOUT_SECS
    # so a real regression is still caught but a normal late-starting service
    # isn't misreported as one.
    local service_deadline=$((SECONDS + SERVICE_READY_TIMEOUT_SECS))

    # Identity must be queried via unifi-core's own no-auth API, not a direct
    # CLI `ubnt-tools id` call, which always shows the safe NAS-spoofed default.
    local api_system=""
    while (( SECONDS < service_deadline )); do
        api_system="$(ssh_dev "curl -sk https://localhost/api/system" 2>/dev/null || true)"
        grep -q '"shortname":"UCKP"' <<<"$api_system" && break
        sleep "$SERVICE_READY_POLL_INTERVAL_SECS"
    done
    if grep -q '"shortname":"UCKP"' <<<"$api_system"; then
        log "  OK: unifi-core's /api/system reports genuine UCKP"
    else
        log "  FAIL: unifi-core's /api/system does not report genuine UCKP after waiting ${SERVICE_READY_TIMEOUT_SECS}s (got: ${api_system:0:200})"
        failures=$((failures + 1))
    fi

    # GET .../proxy/drive/api/system with no auth is expected to return 401 --
    # the correct behavior for a live, correctly-routed backend, not a failure.
    # A connection-level failure (empty response, curl's own "000") means nginx
    # or unifi-drive itself is down, which IS a real failure here. curl's -w
    # '%{http_code}' already prints "000" on no response, so don't append a
    # fallback "000" on a nonzero exit.
    local drive_http_code=""
    service_deadline=$((SECONDS + SERVICE_READY_TIMEOUT_SECS))
    while (( SECONDS < service_deadline )); do
        drive_http_code="$(ssh_dev "curl -sk -o /dev/null -w '%{http_code}' https://localhost/proxy/drive/api/system" 2>/dev/null)" || true
        [[ "$drive_http_code" == "401" ]] && break
        sleep "$SERVICE_READY_POLL_INTERVAL_SECS"
    done
    if [[ "$drive_http_code" == "401" ]]; then
        log "  OK: Drive API reachable and routed (401 Unauthorized, as expected without a session)"
    else
        log "  FAIL: Drive API returned HTTP '$drive_http_code' after waiting ${SERVICE_READY_TIMEOUT_SECS}s (expected 401) -- nginx routing or unifi-drive itself may be down"
        failures=$((failures + 1))
    fi

    if ssh_dev systemctl is-active --quiet drive-hardware-relay-v3.service; then
        log "  OK: drive-hardware-relay-v3.service active"
    else
        log "  FAIL: drive-hardware-relay-v3.service not active"
        failures=$((failures + 1))
    fi

    # Pool mount: genuinely optional. A truly fresh device has no pool yet
    # -- creating one the first time is a WebUI action ("Add Drives" /
    # PoolEditor), not something this script performs, so finding none
    # mounted is not treated as a failure, only reported for visibility.
    local btrfs_mounts
    btrfs_mounts="$(ssh_dev "findmnt -t btrfs -n -o TARGET,SOURCE" 2>/dev/null || true)"
    if [[ -n "$btrfs_mounts" ]]; then
        log "  OK: btrfs pool(s) mounted:"
        while IFS= read -r line; do log "    $line"; done <<<"$btrfs_mounts"
    else
        log "  NOTE: no btrfs pool currently mounted -- expected on a device that hasn't had a pool created yet via the WebUI; not counted as a failure"
    fi

    local failed_units
    failed_units="$(ssh_dev "systemctl --failed --no-legend" 2>/dev/null || true)"
    # proc-fs-nfsd.mount / run-rpc_pipefs.mount are pre-existing and always
    # irrelevant on this device -- anything else failed is a real regression.
    local unexpected_failed
    unexpected_failed="$(grep -vE 'proc-fs-nfsd\.mount|run-rpc_pipefs\.mount' <<<"$failed_units" || true)"
    if [[ -z "$unexpected_failed" ]]; then
        log "  OK: no unexpected failed units"
    else
        log "  FAIL: unexpected failed units:"
        while IFS= read -r line; do log "    $line"; done <<<"$unexpected_failed"
        failures=$((failures + 1))
    fi

    if (( failures == 0 )); then
        log "PASS: all checks OK"
        return 0
    else
        log "FAIL: $failures check(s) failed, see above"
        return 1
    fi
}

main() {
    ensure_control_socket
    verify_final_state
}

# Guarded so this script can be `source`d (e.g. by provision-all.sh, to
# reuse its already-established control socket and call verify_final_state()
# directly without re-checking/establishing one) without running main() a
# second time -- no effect on normal `./05-verify.sh` execution.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
