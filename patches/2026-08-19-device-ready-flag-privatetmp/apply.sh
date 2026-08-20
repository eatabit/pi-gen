#!/bin/bash
# Patch: 2026-08-19-device-ready-flag-privatetmp   (BUG-039)
#
# The "device ready" receipt is meant to print ONCE PER POWER CYCLE. Its guard is a
# flag file, and that flag lived in /tmp -- but mqtt-client.service sets
# PrivateTmp=true, so systemd hands the unit a FRESH private /tmp namespace on every
# start and destroys the flag. Every service restart therefore reprints the receipt,
# including the Layer 1 watchdog's process.exit(1) after 150 s disconnected. A
# flapping device reprints all night. Measured in the field: 5 service starts ->
# 5 ready prints, 1:1, with exactly one boot in 21 h 30 m.
#
# The in-code comment claimed the opposite ("Persisted to /tmp so it survives service
# restarts but clears on reboot"). It was false in both halves and is corrected here;
# that correction is part of the fix, not tidy-up.
#
# THE FIX -- two files, both required:
#   1) mqtt-client.service gains RuntimeDirectory=eatabit and
#      RuntimeDirectoryPreserve=restart, so systemd creates /run/eatabit (tmpfs) and
#      KEEPS it across a restart.
#   2) mqtt-client.js moves the flag to /run/eatabit/device-ready-printed, corrects
#      the comment, and no longer swallows a failed flag write (a silent write failure
#      reproduces this very bug and is otherwise indistinguishable from it).
#
# PrivateTmp=true is NOT removed -- it is correct hardening. The flag was misplaced.
#
# WHY NOT a persistent on-disk path: it would survive a power cycle too, so the
# receipt would NEVER print again -- the same bug in the silent direction. And
# /usr/local/lib/eatabit/log is specifically unsafe despite being in ReadWritePaths,
# because log2ram restores it at boot (BUG-041).
#
# Gating is by CHECKSUM per file, not by version string, and each file is gated
# INDEPENDENTLY so a half-applied device can be completed. An unrecognised file is
# never overwritten -- and the refusal PRINTS the observed sha256 so an unsampled
# field device reports its own state instead of merely being rejected.
#
# These exact files are also committed to image source on both lines and are intended
# to ship in v1.0.11 (hw/1.0) / v1.1.5 (hw/1.1).
#
# NOT YET BYTE-IDENTICAL TO THE RELEASE, and do not assume it. BUG-044 also edits this
# unit and BUG-045 also edits mqtt-client.js, so the shas those releases finally ship
# will differ from the FIXED_* values below. Until ISSUE-065 reconciles the patch set
# against the built image, a device freshly flashed to v1.0.11 / v1.1.5 will NOT no-op
# here -- it hits the refusal path and prints its observed sha. Safe, but not the
# intended end state. ISSUE-065 must update FIXED_JS_SHA / FIXED_UNIT_SHA (or extend
# ACCEPTED_PRIOR_SHAS) once the real release shas exist.
#
# NOTE: restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside
# that process). Over SSH this script runs the restart+verify DETACHED and logs to
# apply.log, so the dropped tunnel cannot interrupt the verify/rollback.
#
# Usage:
#   sudo ./apply.sh             # apply patch
#   sudo ./apply.sh --rollback  # restore the pre-patch files from backup

set -euo pipefail

PATCH_ID="2026-08-19-device-ready-flag-privatetmp"
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
RUNTIME_DIR="/run/eatabit"
FORCE_INLINE=0
FORCE_DETACH=0
READY_FLAG="${RUNTIME_DIR}/device-ready-printed"

# --- Desired end state -------------------------------------------------------
FIXED_JS_SHA="d4647dab55ee858206446c9cc0be5c284ac40554f04a75252cc90abafcbc3376"
FIXED_UNIT_SHA="84aa9272b43699c7d337f8b6e63f2b90d38306335d51bb3475e2e2f4201fc25f"

# --- Files we are willing to replace ----------------------------------------
# Deliberately NARROW. This patch installs the v1.0.10 / v1.1.4 generation of
# mqtt-client.js with the BUG-039 fix on top. Devices on materially older builds
# (v1.0.2/1.0.4/1.0.6/1.1.0/1.1.1) are NOT accepted: dropping this file on them
# would also apply many unrelated intervening changes, which is a different and
# much larger change than this patch is scoped to make. Those devices get the fix
# through the v1.0.11 / v1.1.5 image release instead. See README.md -> Coverage.
ACCEPTED_PRIOR_JS_SHAS=(
  "2f8848db0e8fba8a4ffdc10a517a8b154e181ac0a450d580cae9fca11b459866" # stock v1.0.10 / v1.1.4
  "e80b7a1749672b77e5d67c4e70a418ef30ebb946b9b20580ba4a346402790e20" # stock v1.0.8, v1.0.9, v1.1.2, v1.1.3
  "51a012aef50d802bfcec1ff40cf8d2b4d1ad3839f6c4a0be07d957b7d4d095f3" # field patch 2026-06-25-offline-reboot-loop
  "b30bc9c27f6654f309c3aeb3c9ada35f76a6ec978a50f4bc2ed541e7fedb137f" # field patch, broken first cut of the above
  "607f3d2888fbe9b01b5805da0f64f2267824ff5119e64236a94efd8981905bad" # field patch, combined rollup pre connection-rebuild
)
ACCEPTED_PRIOR_UNIT_SHAS=(
  "e92b2a157f0e9604bc8fed567eda7ae4221920372b8df37c8cb8b3ec0dce6edc" # stock unit, v1.0.8-v1.0.10 / v1.1.2-v1.1.4
)

# Informational only; the checksums above are the authoritative gate.
KNOWN_VERSIONS=("1.0.8" "1.0.9" "1.0.10" "1.1.2" "1.1.3" "1.1.4")

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
    printf '  file:          %s\n' "$path"
    printf '  observed sha256: %s\n' "$observed"
    printf '  device version:  %s\n' "$(current_version 2>/dev/null || echo unknown)"
    printf '  checked against:\n'
    for a in "${accepted[@]}"; do printf '    %s\n' "$a"; done
    printf '  Nothing has been modified. Report the observed sha256 above so it can be\n'
    printf '  added to this patch (see README.md -> Coverage) or handled by the image release.\n\n'
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

unit_check() {
  local unit=$1 tmp
  command -v systemd-analyze >/dev/null 2>&1 || { log "WARNING: systemd-analyze not found, skipping unit verify"; return 0; }
  tmp="/run/${PATCH_ID}-candidate.service"
  cp "$unit" "$tmp"
  local rc=0
  systemd-analyze verify "$tmp" || rc=$?
  rm -f "$tmp"
  return $rc
}

# Is this an SSH session? The obvious test -- $SSH_CONNECTION -- is NOT sufficient:
# sudo's env_reset strips SSH_CONNECTION/SSH_CLIENT/SSH_TTY, and the documented way to
# run this script is `sudo ./apply.sh`. Checking only the environment therefore reports
# "local console" over SSH, the restart runs inline, and it kills the ngrok tunnel it is
# running over -- the precise failure the detach exists to prevent. So fall back to
# walking the parent process chain for sshd, which survives sudo.
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
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]]      && install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  [[ -f "$BACKUP_DIR/mqtt-client.service" ]] && install -m 0644 "$BACKUP_DIR/mqtt-client.service" "$UNIT_FILE"
  systemctl daemon-reload || true
}

# -----------------------------------------------------------------------------
# Finalize steps (restart + verify). Invoked inline or re-exec'd detached.
# -----------------------------------------------------------------------------
__finalize_apply() {
  require_root
  local v=$1
  mkdir -p "$PATCH_STATE_DIR"

  systemctl daemon-reload

  # NOTE: this restart starts the service into a freshly-created /run/eatabit, so the
  # ready receipt prints exactly ONCE here. That is expected and unavoidable: seeding
  # the flag beforehand does not work, because systemd recreates RuntimeDirectory= on
  # start and discards anything placed there by hand. Subsequent restarts are silent,
  # which is the whole point of the fix.
  log "Restarting $SERVICE (this prints one ready receipt -- expected, see README)..."
  systemctl restart "$SERVICE"

  sleep 5
  local state
  state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    log "Restoring backup and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "$SERVICE did not return to active; originals restored. Rollback (if needed): $0 --rollback"
  fi

  # The whole point of the patch: the runtime dir must exist and be writable by the
  # unit. If it is not, the flag write fails and the bug is unchanged (but now logged).
  if [[ ! -d $RUNTIME_DIR ]]; then
    log "WARNING: $RUNTIME_DIR does not exist after restart -- RuntimeDirectory= did not take effect."
    log "Restoring backup and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "$RUNTIME_DIR missing; originals restored."
  fi

  if journalctl -u "$SERVICE" -b --no-pager 2>/dev/null | grep -q 'Failed to persist device ready flag'; then
    log "WARNING: the service logged a failed flag write -- the guard is NOT working."
    log "Recent journal:"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    log "Restoring backup and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "flag write failed under ProtectSystem=strict; originals restored."
  fi

  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Service: $state"
  log "Runtime dir: $(ls -ld "$RUNTIME_DIR")"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $0 --rollback"
  log ""
  log "VERIFY the fix (a restart must NOT reprint):"
  log "  sudo systemctl restart $SERVICE   # detached if over SSH"
  log "  # then confirm the flag mtime is OLDER than ExecMainStartTimestamp:"
  log "  systemctl show $SERVICE -p ExecMainStartTimestamp"
  log "  ls -l --time-style=full-iso $READY_FLAG"
}

__finalize_rollback() {
  require_root
  systemctl daemon-reload
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
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]]      || fail "no backup of mqtt-client.js in $BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.service" ]] || fail "no backup of mqtt-client.service in $BACKUP_DIR"

  install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  install -m 0644 "$BACKUP_DIR/mqtt-client.service" "$UNIT_FILE"
  log "Restored $MQTT_CLIENT_JS and $UNIT_FILE"

  # The pre-patch build reads its flag from /tmp, so /run/eatabit is now dead weight.
  # (It is tmpfs, so it would vanish at the next boot regardless.)
  rm -f "$READY_FLAG"
  rmdir "$RUNTIME_DIR" 2>/dev/null || true

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
  [[ -f $UNIT_FILE ]]      || fail "$UNIT_FILE not found."

  js_sha="$(file_sha "$MQTT_CLIENT_JS")"
  unit_sha="$(file_sha "$UNIT_FILE")"

  # Idempotency: both files already carry the fix.
  if [[ $js_sha == "$FIXED_JS_SHA" && $unit_sha == "$FIXED_UNIT_SHA" ]]; then
    log "mqtt-client.js and mqtt-client.service already contain the fix. Nothing to do."
    mkdir -p "$PATCH_STATE_DIR"
    [[ -f $MARKER_FILE ]] || printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
    exit 0
  fi

  # Gate each file independently. A half-applied device (e.g. a previous run that died
  # between the two installs) is completed rather than refused.
  local need_js=0 need_unit=0 accepted prior

  if [[ $js_sha != "$FIXED_JS_SHA" ]]; then
    accepted=0
    for prior in "${ACCEPTED_PRIOR_JS_SHAS[@]}"; do [[ $js_sha == "$prior" ]] && accepted=1; done
    (( accepted )) || refuse_unrecognized "$MQTT_CLIENT_JS" "$js_sha" "${ACCEPTED_PRIOR_JS_SHAS[@]}" "$FIXED_JS_SHA"
    need_js=1
  else
    log "mqtt-client.js already at the fixed sha."
  fi

  if [[ $unit_sha != "$FIXED_UNIT_SHA" ]]; then
    accepted=0
    for prior in "${ACCEPTED_PRIOR_UNIT_SHAS[@]}"; do [[ $unit_sha == "$prior" ]] && accepted=1; done
    (( accepted )) || refuse_unrecognized "$UNIT_FILE" "$unit_sha" "${ACCEPTED_PRIOR_UNIT_SHAS[@]}" "$FIXED_UNIT_SHA"
    need_unit=1
  else
    log "mqtt-client.service already at the fixed sha."
  fi

  local known=0 kv
  for kv in "${KNOWN_VERSIONS[@]}"; do [[ $v == "$kv" ]] && known=1; done
  (( known )) || log "NOTE: version $v not in ${KNOWN_VERSIONS[*]}, but its files match recognized pre-fix checksums -- proceeding."

  local src_js="$SCRIPT_DIR/mqtt-client.js"
  local src_unit="$SCRIPT_DIR/mqtt-client.service"
  [[ -f $src_js ]]   || fail "missing $src_js -- patch directory is incomplete"
  [[ -f $src_unit ]] || fail "missing $src_unit -- patch directory is incomplete"
  [[ "$(file_sha "$src_js")" == "$FIXED_JS_SHA" ]]     || fail "bundled mqtt-client.js sha mismatch -- patch directory is corrupt."
  [[ "$(file_sha "$src_unit")" == "$FIXED_UNIT_SHA" ]] || fail "bundled mqtt-client.service sha mismatch -- patch directory is corrupt."

  # Verify the candidate unit BEFORE installing it. A bad unit means a service that
  # will not start, on a device we may not be able to reach again.
  if ! unit_check "$src_unit"; then
    fail "systemd-analyze verify rejected the bundled unit -- refusing to install it."
  fi
  log "systemd-analyze verify: bundled unit is clean."

  log "Backing up originals to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]]      || cp -p "$MQTT_CLIENT_JS" "$BACKUP_DIR/mqtt-client.js"
  [[ -f "$BACKUP_DIR/mqtt-client.service" ]] || cp -p "$UNIT_FILE" "$BACKUP_DIR/mqtt-client.service"

  if (( need_js )); then
    log "Installing fixed mqtt-client.js"
    install -m 0755 "$src_js" "$MQTT_CLIENT_JS"
    if ! node_check "$MQTT_CLIENT_JS"; then
      log "Installed mqtt-client.js failed syntax check -- restoring backup."
      restore_backup
      fail "syntax check failed; originals restored."
    fi
  fi

  if (( need_unit )); then
    log "Installing fixed mqtt-client.service"
    install -m 0644 "$src_unit" "$UNIT_FILE"
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
  --rollback  restore the pre-patch mqtt-client.js and mqtt-client.service from backup
  --inline    force the restart+verify to run inline (local console / testing)
  --detach    force the restart+verify to run detached

Remote-session detection does NOT rely on \$SSH_CONNECTION alone -- sudo strips it --
it also walks the parent process chain for sshd.

Two files are gated independently by sha256. An unrecognized file is never
overwritten, and the refusal prints the observed sha256 so an unsampled device
reports its own state.

Restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside it),
so over SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
