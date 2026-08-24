#!/bin/bash
# =============================================================================
#  2026-08-23-app-permissions-and-shadow-churn  (ISSUE-068, Phase 2 -- app half)
# =============================================================================
#  The application-code half of ISSUE-068. Companion to
#  2026-08-23-log-permissions-and-rotation, which fixes the same problem from the
#  filesystem side. Either can be applied first; see "Ordering" below.
#
#  TWO FIXES.
#
#  1. PERMISSIVE MODES IN THE APPLICATIONS. mqtt-client.js and ble-config.js create
#     /usr/local/lib/eatabit/{log,config,reset} with mode 0o777 and their log files
#     with 0o666 whenever they find them MISSING. logrotate refuses to rotate a file
#     whose parent directory is world-writable unless the config carries an `su`
#     directive, so those directories are why mqtt-client.log had never once been
#     rotated. The companion patch narrows the directories that exist NOW; this one
#     stops the applications RE-CREATING them wide open. Neither is sufficient alone:
#     without this patch, one service start against an absent directory silently undoes
#     the companion patch and rotation breaks again. 14 sites: 8 in mqtt-client.js,
#     6 in ble-config.js.
#
#  2. shadow-health.json REWRITE CHURN. persistShadowToFile() rewrote the whole file
#     on every call and the health shadow fires every 15 minutes -- 96 whole-file
#     rewrites a day, ~159 KiB/day straight to the SD card (that directory is NOT
#     RAM-buffered; log2ram only ever managed /var/log), roughly 7x the write volume of
#     the entire log directory. The state is almost always identical between cycles; it
#     was the embedded `timestamp` that made every serialisation differ, so a naive
#     content-equality check would never have skipped anything. The fix compares the
#     `state` object ONLY, via a canonical sorted-key encoding so key ordering cannot
#     produce a false match, and consults the on-disk file once after start-up so a
#     restart does not force a redundant write either.
#
#     CONSEQUENCE, recorded because it is a semantic change and not merely an
#     optimisation: `timestamp` now means LAST CHANGE, not last check. That is safe for
#     liveness -- the file is write-only (nothing in the image or on a device reads it
#     back) and the 15-minute MQTT publish to AWS IoT Core is untouched, so cloud-side
#     freshness is unaffected. The per-cycle heartbeat also remains visible in
#     mqtt-client.log.
#
#  THIS PATCH RESTARTS SERVICES. Unlike its companion, it replaces running code, so
#  mqtt-client.service and ble-config.service must both be restarted to take effect.
#  RESTARTING mqtt-client DROPS IN-FLIGHT PRINT JOBS (BUG-049) and CLOSES an ngrok SSH
#  session, because ngrok runs inside that process. run_detached_if_ssh() is therefore
#  restored from patches/_template VERBATIM -- including the sshd* glob and the
#  `bash "$SELF"` re-exec, both of which are BUG-047 and both of which have been got
#  wrong here before. Do not hand-roll either.
#
#  PAYLOADS ARE THE IMAGE SOURCE, byte for byte.
#    mqtt-client.js  == iot-pi stage3/03-install-mqtt-client/files/mqtt-client.js
#    ble-config.js   == iot-pi stage3/08-ble-config/files/ble-config.js
#  as of ISSUE-068 Phase 2. A patched device and a device reflashed to the next release
#  therefore converge on exactly the same bytes rather than drifting into two
#  similar-but-different states.
#
#  A NOTE ON THE PRIOR STATE, because an earlier draft of this work got it backwards.
#  The deployed mqtt-client.js (b009b68c...) is IDENTICAL to the pre-ISSUE-068 image
#  source -- the 2026-08-20-ngrok-session-reclaim and 2026-08-19-mqtt-keepalive-tolerance
#  fixes were already merged into the image, exactly as patches/README.md requires
#  ("the same fix is ALSO committed to the image source ... the image is the source of
#  truth"). Installing this payload therefore REVERTS NOTHING: it is that same file plus
#  the ISSUE-068 changes. Verified by comparing the deployed sha against
#  `git show <ref>:stage3/03-install-mqtt-client/files/mqtt-client.js`.
#
#  ble-config.js HAS TWO ACCEPTED PRIORS, and they are not interchangeable. v1.0.10 and
#  v1.1.4 ship 2cda3a88...; v1.1.0 ships a different file, d70edf02..., which differs in
#  53 lines unrelated to this fix. Upgrading a v1.1.0 device to the v1.1.4 payload would
#  smuggle in those unrelated changes, so this patch ships a SECOND payload,
#  ble-config-v1.1.0.js -- that device's own file with only the six mode sites narrowed.
#  It selects by observed sha. The v1.1.4 payload converges on the current image; the
#  v1.1.0 payload converges on "v1.1.0 plus this fix", which is correct for that device
#  and deliberately not the same bytes.
#
#  ORDERING. Lineage `mqtt-client` (shares /usr/local/lib/eatabit/bin/mqtt-client.js with
#  2026-08-19-mqtt-keepalive-tolerance, whose output is this patch's accepted prior) and
#  lineage `ble-config` (new; no other patch ships ble-config.js). It shares NO file with
#  its companion 2026-08-23-log-permissions-and-rotation -- that one touches directory
#  modes and /etc/logrotate.d, this one touches /usr/local/lib/eatabit/bin -- so the two
#  are independent of each other and may be applied in either order. Applying BOTH is
#  what actually closes ISSUE-068 on a deployed device.
# =============================================================================
set -uo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-23-app-permissions-and-shadow-churn"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
VERSION_FILE="/usr/local/lib/eatabit/version"

SERVICE="mqtt-client.service"
BLE_SERVICE="ble-config.service"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Targets -----------------------------------------------------------------
BIN_DIR="/usr/local/lib/eatabit/bin"
MQTT_JS="${BIN_DIR}/mqtt-client.js"
BLE_JS="${BIN_DIR}/ble-config.js"

SRC_MQTT="${SCRIPT_DIR}/mqtt-client.js"
SRC_BLE_A="${SCRIPT_DIR}/ble-config.js"            # for the 2cda3a88 prior (v1.0.10 / v1.1.4)
SRC_BLE_B="${SCRIPT_DIR}/ble-config-v1.1.0.js"     # for the d70edf02 prior (v1.1.0)

# --- Gates -------------------------------------------------------------------
# Checksums are the authoritative gate; version lists are informational. Refusing on an
# unrecognised sha, and PRINTING it, is what makes a patch safe to hand to an operator
# who cannot inspect the device first.
FIXED_MQTT_SHA="4cafe4db9f942825c5ced68a83591a3ba9663140e6b7d0b5ca708cf866ba3c09"
ACCEPTED_MQTT_PRIOR_SHAS=(
  "b009b68c8692314ed8476f3bbb3b1d479c3d97fca67240f7bcf96e44444ed339"  # head of the mqtt-client lineage == pre-ISSUE-068 image source
  "${FIXED_MQTT_SHA}"                                                 # already fixed
)

# ble-config.js: prior sha -> payload, and prior sha -> resulting fixed sha.
BLE_PRIOR_A="2cda3a88dc7ea08a0c8875253d4d36eca3b95b12ef81010416b202a8b5235740"  # v1.0.10, v1.1.4
BLE_FIXED_A="a1730cdb2928f2938d8eb9cd89f4462ddef114b860cefa7356b7d10411f65435"
BLE_PRIOR_B="d70edf02fa4b1adb0b294e6215204ed1a3fe163656171d8860d93a7d9c1867b2"  # v1.1.0
BLE_FIXED_B="a912dda06995ce35208c3c3dd622109e621824de79e77a162e4c3ab4123ee577"

KNOWN_VERSIONS=(1.0.1 1.0.2 1.0.3 1.0.4 1.0.5 1.0.6 1.0.7 1.0.8 1.0.9 1.0.10
                1.1.0 1.1.1 1.1.2 1.1.3 1.1.4)

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

in_list() {
  local needle=$1; shift
  local x
  for x in "$@"; do [[ $x == "$needle" ]] && return 0; done
  return 1
}

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

PLACEHOLDER_PATCH_ID="YYYY-MM-DD-short-slug"
assert_not_template() {
  [[ $PATCH_ID != "$PLACEHOLDER_PATCH_ID" ]] || fail \
    "this is patches/_template -- a skeleton, not a patch. Copy it, then set PATCH_ID to the new directory name. See ./README.md"
}

# Is this an SSH session? Carried VERBATIM from patches/_template (BUG-047). The obvious
# test -- $SSH_CONNECTION -- is NOT sufficient: sudo's env_reset strips
# SSH_CONNECTION/SSH_CLIENT/SSH_TTY and the documented invocation is `sudo ./apply.sh`,
# so an environment-only check reports "local console" over SSH, runs the restart inline,
# and is killed by the tunnel drop it just caused -- taking the verify step and the
# automatic rollback with it. Matching `sshd` EXACTLY is also insufficient: OpenSSH 9.8+
# splits the per-connection process out as `sshd-session`, and under socket activation
# there is no `sshd` in the chain at all. Hence the parent walk and the sshd* glob.
is_remote_session() {
  [[ $FORCE_INLINE -eq 1 ]] && return 1
  [[ $FORCE_DETACH -eq 1 ]] && return 0
  [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] && return 0
  local pid=${PPID:-0} comm guard=0
  while [[ $pid -gt 1 && $guard -lt 32 ]]; do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [[ $comm == sshd* ]] && return 0
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
    [[ -z $pid ]] && pid=0
    guard=$((guard + 1))
  done
  return 1
}

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
    # Re-exec via `bash "$SELF"` rather than executing $SELF directly: if this directory
    # were delivered by any route that drops the executable bit, a direct exec fails with
    # "Permission denied" INSIDE the detached child while the foreground has already
    # logged "running DETACHED" and exited 0 -- success on screen, nothing applied.
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    else
      nohup bash "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    fi
    disown 2>/dev/null || true
    exit 0
  fi
  "$internal_cmd" "$@"
}

# =============================================================================
#  PATCH-SPECIFIC
# =============================================================================

start_logging() {
  mkdir -p "$PATCH_STATE_DIR"
  exec > >(tee -a "$LOG") 2>&1
  log "---- $(date -Iseconds) :: $PATCH_ID :: $* ----"
}

note_version() {
  if in_list "$1" "${KNOWN_VERSIONS[@]}"; then
    log "Version '$1' is a known release (informational; the deployed state is the gate)."
  else
    log "Version '$1' is not in the known-release list (informational only, not a refusal)."
  fi
}

mqtt_sha() { [[ -f $MQTT_JS ]] && file_sha "$MQTT_JS" || printf ''; }
ble_sha()  { [[ -f $BLE_JS  ]] && file_sha "$BLE_JS"  || printf ''; }

report_state() {
  local m b
  m="$(mqtt_sha)"; log "  ${MQTT_JS} sha: ${m:-<absent>}"
  b="$(ble_sha)";  log "  ${BLE_JS} sha: ${b:-<absent>}"
}

# Which ble payload does this device's observed prior call for? Echoes "<src>|<fixed>".
# Empty output means the observed sha is not one we know how to upgrade.
ble_plan() {
  local b; b="$(ble_sha)"
  case "$b" in
    "$BLE_PRIOR_A"|"$BLE_FIXED_A") printf '%s|%s' "$SRC_BLE_A" "$BLE_FIXED_A" ;;
    "$BLE_PRIOR_B"|"$BLE_FIXED_B") printf '%s|%s' "$SRC_BLE_B" "$BLE_FIXED_B" ;;
    *) printf '' ;;
  esac
}

is_fixed() {
  [[ "$(mqtt_sha)" == "$FIXED_MQTT_SHA" ]] || return 1
  local b; b="$(ble_sha)"
  [[ $b == "$BLE_FIXED_A" || $b == "$BLE_FIXED_B" ]] || return 1
  return 0
}

do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed. (No root required.)"
  log "Payloads shipped with this patch:"
  log "  mqtt-client.js       : $(file_sha "$SRC_MQTT")"
  log "  ble-config.js        : $(file_sha "$SRC_BLE_A")  (for v1.0.10 / v1.1.4)"
  log "  ble-config-v1.1.0.js : $(file_sha "$SRC_BLE_B")  (for v1.1.0)"
  log "State on this device:"
  report_state

  if is_fixed; then
    log "RESULT: already patched -- a real run would NO-OP. (exit 0)"
    exit 0
  fi

  local m; m="$(mqtt_sha)"
  if [[ -z $m ]]; then
    log "RESULT: would REFUSE -- ${MQTT_JS} is missing. (exit 1)"; exit 1
  fi
  if ! in_list "$m" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}"; then
    log "RESULT: would REFUSE -- unrecognised ${MQTT_JS}:"
    log "  observed: ${m}"
    log "  accepted: ${ACCEPTED_MQTT_PRIOR_SHAS[*]}"
    log "Report this sha -- it is a decision for ISSUE-068, not a device fault. (exit 1)"
    exit 1
  fi

  local plan; plan="$(ble_plan)"
  if [[ -z $plan ]]; then
    log "RESULT: would REFUSE -- unrecognised ${BLE_JS} (observed $(ble_sha)). (exit 1)"
    log "  accepted priors: ${BLE_PRIOR_A} (v1.0.10/v1.1.4)"
    log "                   ${BLE_PRIOR_B} (v1.1.0)"
    exit 1
  fi
  log "ble-config payload selected: $(basename "${plan%%|*}")"

  if is_remote_session; then
    log "Detection: REMOTE -- a real run would DETACH (restarting ${SERVICE} closes this session)."
  else
    log "Detection: LOCAL -- a real run would go INLINE."
  fi
  log "NOTE: a real run RESTARTS ${SERVICE} and ${BLE_SERVICE}."
  log "      Restarting ${SERVICE} DROPS IN-FLIGHT PRINT JOBS (BUG-049)."
  log "RESULT: would APPLY. (exit 2)"
  exit 2
}

__finalize_apply() {
  local v=$1
  assert_not_template
  log "Restarting ${SERVICE} and ${BLE_SERVICE}..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  systemctl restart "$BLE_SERVICE"
  sleep 3

  local s1 s2
  s1="$(systemctl is-active "$SERVICE" || true)"
  s2="$(systemctl is-active "$BLE_SERVICE" || true)"
  if [[ $s1 != active || $s2 != active ]]; then
    log "WARNING: ${SERVICE}=${s1} ${BLE_SERVICE}=${s2}. Recent journal:"
    journalctl -u "$SERVICE" -u "$BLE_SERVICE" -n 25 --no-pager || true
    fail "a service did not return to active. Rollback with: sudo $SELF --rollback"
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. ${SERVICE}=${s1} ${BLE_SERVICE}=${s2}"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
  log ""
  log "To confirm the shadow-churn fix: shadow-health.json's mtime should now STOP"
  log "advancing every 15 minutes while device state is steady --"
  log "  stat -c '%y' /usr/local/lib/eatabit/config/shadow-health.json"
  log "and it must still update when state actually changes."
}

__finalize_rollback() {
  assert_not_template
  log "Restarting ${SERVICE} and ${BLE_SERVICE}..."
  systemctl daemon-reload
  systemctl restart "$SERVICE" || true
  systemctl restart "$BLE_SERVICE" || true
  rm -f "$MARKER_FILE"
  log "Rollback complete. ${SERVICE}=$(systemctl is-active "$SERVICE" || true) ${BLE_SERVICE}=$(systemctl is-active "$BLE_SERVICE" || true)"
}

do_apply() {
  require_root
  assert_not_template
  start_logging apply
  local v; v="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  log "Detected device version: $v"
  note_version "$v"
  log "State before:"
  report_state

  if is_fixed; then
    log "Both applications are already at the fixed shas. Nothing to do."
    exit 0
  fi

  # --- Gates, before anything is touched -------------------------------------
  local m; m="$(mqtt_sha)"
  [[ -n $m ]] || fail "${MQTT_JS} is missing. Nothing was changed."
  in_list "$m" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}" || fail \
    "unrecognised ${MQTT_JS} (observed ${m}; accepted ${ACCEPTED_MQTT_PRIOR_SHAS[*]}). Nothing was changed. Report this sha -- it is a decision for ISSUE-068, not a device fault."

  local plan; plan="$(ble_plan)"
  [[ -n $plan ]] || fail \
    "unrecognised ${BLE_JS} (observed $(ble_sha); accepted ${BLE_PRIOR_A} for v1.0.10/v1.1.4, ${BLE_PRIOR_B} for v1.1.0). Nothing was changed."
  local ble_src="${plan%%|*}" ble_expect="${plan##*|}"
  [[ -r $ble_src  ]] || fail "payload ${ble_src} is missing from this patch directory."
  [[ -r $SRC_MQTT ]] || fail "payload ${SRC_MQTT} is missing from this patch directory."
  log "ble-config payload selected: $(basename "$ble_src")"

  # --- Back up BEFORE touching anything --------------------------------------
  mkdir -p "$BACKUP_DIR"
  cp -p "$MQTT_JS" "${BACKUP_DIR}/mqtt-client.js"
  cp -p "$BLE_JS"  "${BACKUP_DIR}/ble-config.js"
  log "Backed up prior files to ${BACKUP_DIR}"

  # --- Install ---------------------------------------------------------------
  install -m 0755 -o root -g root "$SRC_MQTT" "$MQTT_JS" \
    || fail "failed to install ${MQTT_JS}. Roll back with: sudo $SELF --rollback"
  log "  installed ${MQTT_JS} ($(mqtt_sha))"

  install -m 0755 -o root -g root "$ble_src" "$BLE_JS" \
    || fail "failed to install ${BLE_JS}. Roll back with: sudo $SELF --rollback"
  log "  installed ${BLE_JS} ($(ble_sha))"

  # --- Verify bytes BEFORE restarting anything -------------------------------
  # A restart is the expensive, disruptive step (it drops in-flight print jobs), so
  # prove the files landed correctly first rather than discovering it afterwards.
  [[ "$(mqtt_sha)" == "$FIXED_MQTT_SHA" ]] || fail \
    "post-install sha mismatch on ${MQTT_JS} (got $(mqtt_sha), want ${FIXED_MQTT_SHA}). Nothing was restarted. Roll back with: sudo $SELF --rollback"
  [[ "$(ble_sha)" == "$ble_expect" ]] || fail \
    "post-install sha mismatch on ${BLE_JS} (got $(ble_sha), want ${ble_expect}). Nothing was restarted. Roll back with: sudo $SELF --rollback"
  log "Byte-level verification passed for both files."

  run_detached_if_ssh __finalize_apply "$v"
}

do_rollback() {
  require_root
  assert_not_template
  start_logging rollback
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"

  log "State before rollback:"
  report_state

  if [[ -r ${BACKUP_DIR}/mqtt-client.js ]]; then
    install -m 0755 -o root -g root "${BACKUP_DIR}/mqtt-client.js" "$MQTT_JS" && log "  restored ${MQTT_JS}"
  else
    log "  WARNING: no backup of mqtt-client.js -- left as it is."
  fi
  if [[ -r ${BACKUP_DIR}/ble-config.js ]]; then
    install -m 0755 -o root -g root "${BACKUP_DIR}/ble-config.js" "$BLE_JS" && log "  restored ${BLE_JS}"
  else
    log "  WARNING: no backup of ble-config.js -- left as it is."
  fi

  log "State after rollback:"
  report_state
  run_detached_if_ssh __finalize_rollback
}

# =============================================================================
#  Entry point
# =============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inline)  FORCE_INLINE=1; shift ;;
    --detach)  FORCE_DETACH=1; shift ;;
    *) break ;;
  esac
done

case "${1:-apply}" in
  apply)                do_apply ;;
  --check|check)        do_check ;;
  --rollback)           do_rollback ;;
  __finalize_apply)     __finalize_apply "${2:?missing version}" ;;
  __finalize_rollback)  __finalize_rollback ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--inline|--detach] [apply|--check|--rollback]
  apply       (default) apply the patch
  --check     DRY RUN, no root needed, changes nothing
  --rollback  restore the pre-patch files from backup
  --inline    force the restart+verify to run in the foreground
  --detach    force the restart+verify to run detached

This patch REPLACES RUNNING CODE, so it restarts $SERVICE and $BLE_SERVICE.
Restarting $SERVICE drops in-flight print jobs (BUG-049) and drops the ngrok SSH
tunnel (ngrok runs inside it), so over SSH the restart+verify runs detached and
logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
