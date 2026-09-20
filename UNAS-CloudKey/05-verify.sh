#!/bin/bash
# 05-verify.sh -- check a provisioned Cloud Key's health: kernel, modules, identity,
# Drive API reachability, hardware-identity relay, pool mount, failed units. Run
# standalone or from provision-all.sh; prints a pass/fail report and exits 0/1.
#
# Usage (standalone): DEVICE_HOST=root@<ip> DEVICE_PASSWORD='...' ./05-verify.sh
# Usage (reuse an existing ControlMaster): DEVICE_HOST=root@<ip> \
#   SSH_CONTROL_SOCKET=/tmp/ck_ssh_ctrl.sock ./05-verify.sh
# Identity is queried via unifi-core's own no-auth /api/system, never `ubnt-tools id`,
# which always shows the safe NAS-spoofed default regardless of what unifi-core sees.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE_HOST="${DEVICE_HOST:?set DEVICE_HOST, e.g. root@<cloudkey-ip>}"
SSH_CONTROL_SOCKET="${SSH_CONTROL_SOCKET:-/tmp/ck_ssh_ctrl.sock}"
EXPECT_KERNEL="3.18.44-btrfscustom"

# sshd is reachable well before unifi-core/nginx; the two service checks retry up to this long.
SERVICE_READY_TIMEOUT_SECS="${SERVICE_READY_TIMEOUT_SECS:-90}"
SERVICE_READY_POLL_INTERVAL_SECS="${SERVICE_READY_POLL_INTERVAL_SECS:-10}"

log() { echo "[verify] $*"; }
fail() { echo "[verify] ERROR: $*" >&2; exit 1; }

ssh_dev() { ssh -S "$SSH_CONTROL_SOCKET" "$DEVICE_HOST" "$@"; }

# Establish a ControlMaster if none is live (standalone run); needs DEVICE_PASSWORD then.
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

    # sshd comes up before unifi-core/nginx, so retry both service checks until this deadline.
    local service_deadline=$((SECONDS + SERVICE_READY_TIMEOUT_SECS))

    # Query unifi-core's no-auth /api/system, not `ubnt-tools id`, which always shows the NAS-spoofed default.
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

    # GET .../proxy/drive/api/system with no auth should return 401 (routed Drive
    # backend, auth required). The failure message distinguishes the mode:
    #   200 -> the unifi-core web UI answered (no Drive location: app not installed)
    #   000/empty -> nginx or unifi-drive is down
    #   5xx -> unifi-drive is up but erroring
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
        failures=$((failures + 1))
        case "$drive_http_code" in
            200)
                log "  FAIL: got HTTP 200 instead of 401 -- the unifi-core web UI answered /proxy/drive/ (no Drive location), so the Drive app is not installed (or its nginx conf is missing)"
                ;;
            000|"")
                log "  FAIL: no response from https://localhost/proxy/drive/api/system -- nginx or unifi-drive is down"
                ;;
            5*)
                log "  FAIL: Drive API returned HTTP $drive_http_code -- unifi-drive is up but erroring"
                ;;
            *)
                log "  FAIL: Drive API returned HTTP '$drive_http_code' after waiting ${SERVICE_READY_TIMEOUT_SECS}s (expected 401)"
                ;;
        esac
    fi

    if ssh_dev systemctl is-active --quiet drive-hardware-relay-v3.service; then
        log "  OK: drive-hardware-relay-v3.service active"
    else
        log "  FAIL: drive-hardware-relay-v3.service not active"
        failures=$((failures + 1))
    fi

    # Pool mount is genuinely optional: a fresh device has no pool until created via the WebUI
    # ("Add Drives"/PoolEditor), so finding none mounted is reported, not treated as a failure.
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
    # proc-fs-nfsd.mount/run-rpc_pipefs.mount are pre-existing and irrelevant; anything else is a regression.
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

# Guarded so provision-all.sh can `source` this and call verify_final_state() directly.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
