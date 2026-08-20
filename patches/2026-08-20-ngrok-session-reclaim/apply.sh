#!/bin/bash
# Patch: 2026-08-20-ngrok-session-reclaim   (BUG-049, folding in BUG-038)
#
# After ONE connect/disconnect cycle, every later startNgrokTunnel on the device failed
# with reasonCode 500 / "Failed to establish tunnel" -- consistently, single attempts
# included -- until mqtt-client restarted. Remote SSH was unavailable for that entire
# window, and since every field patch ships OVER that SSH tunnel, the maintenance
# procedure degraded to reboot -> connect -> patch -> reboot per device. Each reboot
# drops in-flight print jobs, so the fix procedure was inflicting the customer-visible
# harm itself. That is why this is P1.
#
# ROOT CAUSE (confirmed, not hypothesised): the @ngrok/ngrok agent SESSION is
# process-global and outlives the tunnel it was created for. ngrok.forward() builds an
# implicit default session and returns only a Listener; closing the listener leaves the
# session connected, and the module exposes no way to reach that implicit session --
# ngrok.disconnect() and ngrok.kill() both close LISTENERS, not sessions. Nothing
# reclaimed sessions. Observed directly on the ngrok API: both LAN printers holding
# sessions with NO tunnels attached, and an orphan session alive since 2026-08-17.
#
# BUG-035's reaper does not help: it reclaims ngrok CREDENTIALS, not sessions. A clean
# credential ledger says nothing about how many stale sessions a device holds.
#
# THE FIX -- one file, mqtt-client.js, five defects, one restart:
#   F1  Publish a terminal status on BOTH previously silent branches: the missing
#       authToken guard, and the "no active forwarding to stop" branch. Both used to
#       return without publishing, leaving the DeviceCommand at `sent` forever.
#   F2  Bound and serialise the ngrok calls, and RECLAIM THE AGENT SESSION -- the tunnel
#       is now built on a session we own via SessionBuilder, and stop closes the
#       listener AND the session.
#   F3  Fix the check-then-act race on the ngrokListener global. Production-confirmed:
#       two live tunnels from pid 124474, the loser uncloseable because the handle had
#       already been overwritten.
#   F5  Publish the REAL err.message instead of the hardcoded "Failed to establish
#       tunnel", sanitized to AWS's documented StatusReason constraints.
#
# F4 (pinning @ngrok/ngrok) is deliberately NOT in this patch -- its home is
# stage2/04-cloud-init/files/user-data, it only reaches newly provisioned devices, and
# it is hardening against a future drift rather than part of this wedge. See README.md.
#
# ORDERING REQUIREMENT -- READ THIS BEFORE APPLYING:
#   Apply 2026-08-19-device-ready-flag-privatetmp FIRST. This patch's mqtt-client.js
#   carries BUG-039's device-ready flag in /run/eatabit, which only works when the unit
#   file has RuntimeDirectory=eatabit -- and this patch does NOT ship the unit file. So
#   the gate below accepts EXACTLY ONE prior sha: the output of the 2026-08-19 patch.
#   Installing this JS on a device that still has the stock unit would move the flag to
#   a directory systemd never creates, the flag write would fail, and the ready receipt
#   would reprint on every restart -- BUG-039 in the silent direction. Refusing is
#   correct; the refusal message says what to do.
#
# Gating is by CHECKSUM, not by version string. An unrecognised file is never
# overwritten -- and the refusal PRINTS the observed sha256, so an unsampled field
# device reports its own state instead of merely being rejected.
#
# NOT YET BYTE-IDENTICAL TO THE RELEASE, and do not assume it. ISSUE-065 owns v1.0.11 /
# v1.1.5, and BUG-044 (unit) and BUG-045 (js) also land in that cut, so the sha the
# release finally ships will differ from FIXED_JS_SHA below. Until ISSUE-065 reconciles
# the patch set against the built image, a device freshly flashed to v1.0.11 / v1.1.5
# will NOT no-op here -- it hits the refusal path and prints its observed sha. Safe, but
# not the intended end state.
#
# NOTE: restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside
# that process). Over SSH this script runs the restart+verify DETACHED and logs to
# apply.log, so the dropped tunnel cannot interrupt the verify/rollback. That detection
# is carried by hand from 2026-08-19-device-ready-flag-privatetmp -- per BUG-047's audit
# it is the only shipped patch that gets it right, and there is NO shared patch script.
#
# Usage:
#   sudo ./apply.sh             # apply patch
#   sudo ./apply.sh --rollback  # restore the pre-patch file from backup

set -euo pipefail

PATCH_ID="2026-08-20-ngrok-session-reclaim"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MQTT_CLIENT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
UNIT_FILE="/etc/systemd/system/mqtt-client.service"
VERSION_FILE="/usr/local/lib/eatabit/version"
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
SERVICE="mqtt-client.service"
FORCE_INLINE=0
FORCE_DETACH=0

# --- Desired end state -------------------------------------------------------
FIXED_JS_SHA="323299afb4d62508be5543d3ecb6c7240f8e05dba7ad566f9eb0644017d026c0"

# --- Files we are willing to replace ----------------------------------------
# Deliberately ONE entry. See "ORDERING REQUIREMENT" in the header: this payload carries
# BUG-039's /run/eatabit flag, which needs the patched unit file that this patch does not
# ship. The only safe pre-state is therefore a device that has already taken the
# 2026-08-19 patch (js AND unit).
ACCEPTED_PRIOR_JS_SHAS=(
  "d4647dab55ee858206446c9cc0be5c284ac40554f04a75252cc90abafcbc3376" # output of 2026-08-19-device-ready-flag-privatetmp
)

# The unit sha that must already be in place for the payload above to behave. Checked but
# never modified -- this patch does not install a unit file.
REQUIRED_UNIT_SHA="84aa9272b43699c7d337f8b6e63f2b90d38306335d51bb3475e2e2f4201fc25f"

# Informational only; the checksums above are the authoritative gate.
KNOWN_VERSIONS=("1.0.10" "1.1.4")

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "must be run as root (use: sudo $0)"
  fi
}

current_version() {
  [[ -f $VERSION_FILE ]] || fail "$VERSION_FILE not found -- is this an eatabit Pi image?"
  tr -d '[:space:]' < "$VERSION_FILE"
}

file_sha() { sha256sum "$1" | awk '{print $1}'; }

# Refusal path. Prints the observed sha and everything it was compared against, so a
# device we have never sampled reports its own state in one run. Changes nothing.
refuse_unrecognized() {
  local path=$1 observed=$2; shift 2
  local accepted=("$@") a
  {
    printf '\n[ERROR] Refusing to overwrite an unrecognized file.\n'
    printf '  file:            %s\n' "$path"
    printf '  observed sha256: %s\n' "$observed"
    printf '  device version:  %s\n' "$(current_version 2>/dev/null || echo unknown)"
    printf '  checked against:\n'
    for a in "${accepted[@]}"; do printf '    %s\n' "$a"; done
    printf '\n  If this device has NOT taken 2026-08-19-device-ready-flag-privatetmp yet,\n'
    printf '  apply that patch first -- this one deliberately builds on its output.\n'
    printf '  Otherwise report the observed sha256 above so it can be added to this patch\n'
    printf '  (see README.md -> Coverage) or handled by the image release.\n'
    printf '  Nothing has been modified.\n\n'
  } >&2
  exit 1
}

node_check() {
  local node_bin
  node_bin="$(command -v node || true)"
  [[ -x $node_bin ]] || node_bin="/usr/bin/node"
  [[ -x $node_bin ]] || { log "WARNING: node not found, skipping syntax check"; return 0; }
  "$node_bin" --check "$1"
}

# Is this an SSH session? The obvious test -- $SSH_CONNECTION -- is NOT sufficient:
# sudo's env_reset strips SSH_CONNECTION/SSH_CLIENT/SSH_TTY, and the documented way to
# run this script is `sudo ./apply.sh`. Checking only the environment therefore reports
# "local console" over SSH, the restart runs inline, and it kills the ngrok tunnel it is
# running over -- the precise failure the detach exists to prevent, and the precise
# failure this patch is about. So fall back to walking the parent process chain for
# sshd, which survives sudo. Carried by hand from the 2026-08-19 patch (BUG-047).
is_remote_session() {
  [[ $FORCE_INLINE -eq 1 ]] && return 1
  [[ $FORCE_DETACH -eq 1 ]] && return 0
  [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] && return 0
  local pid=${PPID:-0} comm guard=0
  while [[ $pid -gt 1 && $guard -lt 32 ]]; do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [[ $comm == sshd ]] && return 0
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
    [[ -z $pid ]] && pid=0
    guard=$((guard + 1))
  done
  return 1
}

# Run a finalize step (which restarts mqtt-client and thus drops an ngrok SSH tunnel).
# Over SSH, re-exec it detached via setsid so the session drop cannot kill it
# mid-restart; results go to $LOG. On a local console, run inline.
run_detached_if_ssh() {
  local internal_cmd=$1; shift
  if is_remote_session; then
    mkdir -p "$PATCH_STATE_DIR"
    log "Over SSH: restarting $SERVICE will CLOSE this session (ngrok runs inside it)."
    log "Running '$internal_cmd' DETACHED so the tunnel drop cannot interrupt it; logging to:"
    log "  $LOG"
    log "After reconnecting (re-issue the startNgrokTunnel cloud command), check:"
    log "  cat $LOG"
    log "  cat $MARKER_FILE"
    if command -v setsid >/dev/null 2>&1; then
      setsid "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    else
      nohup "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    fi
    disown 2>/dev/null || true
    exit 0
  fi
  "$internal_cmd" "$@"
}

restore_backup() {
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] && install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  return 0
}

# -----------------------------------------------------------------------------
# Finalize steps (restart + verify). Invoked inline or re-exec'd detached.
# -----------------------------------------------------------------------------
__finalize_apply() {
  require_root
  local v=$1
  mkdir -p "$PATCH_STATE_DIR"

  log "Restarting $SERVICE..."
  systemctl restart "$SERVICE"

  sleep 8
  local state
  state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u "$SERVICE" -n 30 --no-pager || true
    log "Restoring backup and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "$SERVICE did not return to active; original restored. Rollback (if needed): $0 --rollback"
  fi

  # The service must have reconnected to AWS IoT, otherwise the device is reachable by
  # nothing at all and the next start command can never arrive.
  if ! journalctl -u "$SERVICE" -b --no-pager 2>/dev/null | tail -n 200 | grep -qi 'connect'; then
    log "NOTE: no connection line seen in the recent journal; check manually."
  fi

  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Service: $state"
  log "Original backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $0 --rollback"
  log ""
  log "VERIFY the fix -- the SECOND start of a process lifetime is the assertion:"
  log "  1) startNgrokTunnel  -> expect success"
  log "  2) stopNgrokTunnel   -> expect SUCCEEDED (reasonCode 200)"
  log "  3) startNgrokTunnel  -> MUST succeed. Before this patch it failed 500."
  log "  Repeat 1-3 at least three times. Also confirm on the ngrok API that no"
  log "  tunnel-less agent session remains after step 2."
}

__finalize_rollback() {
  require_root
  systemctl restart "$SERVICE"
  rm -f "$MARKER_FILE"
  sleep 5
  log "Rollback complete. Service is: $(systemctl is-active "$SERVICE" || true)"
}

# -----------------------------------------------------------------------------
# Rollback
# -----------------------------------------------------------------------------
do_rollback() {
  require_root
  log "Rolling back patch ${PATCH_ID}..."

  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] || fail "no backup of mqtt-client.js in $BACKUP_DIR"

  install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  log "Restored $MQTT_CLIENT_JS"

  run_detached_if_ssh __finalize_rollback
}

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------
do_apply() {
  require_root

  local v js_sha unit_sha
  v="$(current_version)"
  log "Detected device version: $v"

  [[ -f $MQTT_CLIENT_JS ]] || fail "$MQTT_CLIENT_JS not found."

  js_sha="$(file_sha "$MQTT_CLIENT_JS")"

  # Idempotency: already carries the fix.
  if [[ $js_sha == "$FIXED_JS_SHA" ]]; then
    log "mqtt-client.js already contains the fix. Nothing to do."
    mkdir -p "$PATCH_STATE_DIR"
    [[ -f $MARKER_FILE ]] || printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
    exit 0
  fi

  local is_accepted=0 prior
  for prior in "${ACCEPTED_PRIOR_JS_SHAS[@]}"; do [[ $js_sha == "$prior" ]] && is_accepted=1; done
  (( is_accepted )) || refuse_unrecognized "$MQTT_CLIENT_JS" "$js_sha" "${ACCEPTED_PRIOR_JS_SHAS[@]}" "$FIXED_JS_SHA"

  # The payload needs the patched unit (RuntimeDirectory=eatabit) to keep BUG-039 fixed.
  # We never modify the unit here -- we refuse if it is not already right, because
  # proceeding would silently reintroduce the ready-receipt reprint.
  [[ -f $UNIT_FILE ]] || fail "$UNIT_FILE not found."
  unit_sha="$(file_sha "$UNIT_FILE")"
  if [[ $unit_sha != "$REQUIRED_UNIT_SHA" ]]; then
    {
      printf '\n[ERROR] The unit file is not the BUG-039-patched one this payload requires.\n'
      printf '  file:            %s\n' "$UNIT_FILE"
      printf '  observed sha256: %s\n' "$unit_sha"
      printf '  required sha256: %s\n' "$REQUIRED_UNIT_SHA"
      printf '\n  Apply 2026-08-19-device-ready-flag-privatetmp first: it installs both the\n'
      printf '  unit and the matching mqtt-client.js. Nothing has been modified.\n\n'
    } >&2
    exit 1
  fi
  log "Unit file is the BUG-039-patched one, as required."

  local known=0 kv
  for kv in "${KNOWN_VERSIONS[@]}"; do [[ $v == "$kv" ]] && known=1; done
  (( known )) || log "NOTE: version $v not in ${KNOWN_VERSIONS[*]}, but its files match recognized checksums -- proceeding."

  local src_js="$SCRIPT_DIR/mqtt-client.js"
  [[ -f $src_js ]] || fail "missing $src_js -- patch directory is incomplete"
  [[ "$(file_sha "$src_js")" == "$FIXED_JS_SHA" ]] || fail "bundled mqtt-client.js sha mismatch -- patch directory is corrupt."

  # Syntax-check the CANDIDATE before installing it. A file that will not parse means a
  # service that will not start, on a device we may not be able to reach again.
  if ! node_check "$src_js"; then
    fail "bundled mqtt-client.js failed node --check -- refusing to install it."
  fi
  log "node --check: bundled mqtt-client.js is clean."

  log "Backing up original to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] || cp -p "$MQTT_CLIENT_JS" "$BACKUP_DIR/mqtt-client.js"

  log "Installing fixed mqtt-client.js"
  install -m 0755 "$src_js" "$MQTT_CLIENT_JS"
  if ! node_check "$MQTT_CLIENT_JS"; then
    log "Installed mqtt-client.js failed syntax check -- restoring backup."
    restore_backup
    fail "syntax check failed; original restored."
  fi

  # Restart + verify. This drops the ngrok SSH tunnel, so run it detached over SSH.
  run_detached_if_ssh __finalize_apply "$v"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inline) FORCE_INLINE=1; shift ;;
    --detach) FORCE_DETACH=1; shift ;;
    *) break ;;
  esac
done

case "${1:-apply}" in
  apply)                do_apply ;;
  --rollback)           do_rollback ;;
  __finalize_apply)     __finalize_apply "${2:?missing version}" ;;
  __finalize_rollback)  __finalize_rollback ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--inline|--detach] [apply|--rollback]
  apply       (default) apply the patch
  --rollback  restore the pre-patch mqtt-client.js from backup
  --inline    force the restart+verify to run inline (local console / testing)
  --detach    force the restart+verify to run detached

Apply 2026-08-19-device-ready-flag-privatetmp FIRST. This patch accepts exactly one
prior mqtt-client.js sha -- that patch's output -- and refuses to run unless the
BUG-039-patched unit file is already in place.

Remote-session detection does NOT rely on \$SSH_CONNECTION alone -- sudo strips it --
it also walks the parent process chain for sshd.

The file is gated by sha256. An unrecognized file is never overwritten, and the
refusal prints the observed sha256 so an unsampled device reports its own state.

Restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside it),
so over SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
