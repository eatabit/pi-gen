#!/bin/bash
# =============================================================================
#  2026-08-23-app-permissions-and-shadow-churn  (ISSUE-068, Phase 2 -- mqtt half)
# =============================================================================
#  The mqtt-client.js half of ISSUE-068's application work. TWO FIXES.
#
#  1. PERMISSIVE MODES. mqtt-client.js creates /usr/local/lib/eatabit/{log,config,reset}
#     with mode 0o777 and its log file and reset flag with 0o666, whenever it finds them
#     MISSING. logrotate refuses to rotate a file whose parent directory is
#     world-writable unless the config carries an `su` directive, so those directories
#     are why mqtt-client.log had never once been rotated. The companion patch
#     2026-08-23-log-permissions-and-rotation narrows the directories that exist NOW;
#     this one stops mqtt-client RE-CREATING them wide open. Neither is sufficient
#     alone. 8 sites in mqtt-client.js.
#
#  2. SHADOW SNAPSHOT CHURN -- fixed by MOVING THE FILES TO tmpfs.
#     persistShadowToFile() rewrote the whole file on every call into
#     /usr/local/lib/eatabit/config, which is NOT RAM-buffered (log2ram only ever
#     managed /var/log). The health shadow fires every 15 minutes: 96 whole-file
#     rewrites a day, ~159 KiB/day straight to the SD card, roughly 7x the write volume
#     of the entire log directory.
#
#     THE FIX IS THE LOCATION. The snapshots now live in /run/eatabit -- tmpfs, already
#     created for this unit by RuntimeDirectory=eatabit with
#     RuntimeDirectoryPreserve=restart, so they survive a service restart and are
#     discarded on stop. That is the correct lifetime: these files are WRITE-ONLY.
#     Nothing in the image or on a device reads them back -- the authoritative shadow
#     lives in AWS IoT Core, and docs/SERVICE_PACKS.md lists config/shadow-*.json as
#     never-managed. Losing them on reboot costs nothing; each is rewritten within one
#     heartbeat. Card writes for this state: zero.
#
#     A skip-if-unchanged guard is also present, and it is NOT the fix. MEASURED ON
#     HARDWARE (bench .126, 2026-08-24): it does NOT reduce the health shadow's write
#     rate, because that shadow's `state` legitimately changes every cycle -- it embeds
#     its own timestamp, uptime.seconds, freeMemory and disk usage. The guard was
#     written expecting it to help; it does not. It is kept because it is correct and
#     does skip genuinely redundant writes (the private shadow at start-up, for one).
#     Recorded so nobody cites it as the card-wear fix, or re-derives this the hard way.
#
#     The comparison covers `state` ONLY, because the wrapper's own `timestamp` changes
#     on every serialisation and a whole-content check would never skip. `timestamp`
#     therefore means LAST CHANGE, not last check -- safe, since the 15-minute MQTT
#     publish to AWS IoT Core is untouched and the heartbeat stays in mqtt-client.log.
#
#  SCOPE: mqtt-client.js ONLY. ble-config.js has its own patch --
#  2026-08-24-ble-config-permissions -- and the split is deliberate, not cosmetic. This
#  patch requires the mqtt-client lineage head as its prior, and that lineage's ENTRY
#  POINT (2026-08-20-ngrok-session-reclaim) only accepts stock v1.0.8-v1.0.10 /
#  v1.1.2-v1.1.4, so devices on v1.0.1-v1.0.7, v1.1.0 or v1.1.1 cannot enter it at all.
#  While the two fixes were welded together that dead end governed the ble fix as well,
#  even though the ble change needs no lineage and applies to every released variant.
#  Split, each reaches as far as it actually can.
#
#  THIS PATCH RESTARTS mqtt-client.service. It replaces running code. RESTARTING IT
#  DROPS IN-FLIGHT PRINT JOBS (BUG-049) and CLOSES an ngrok SSH session, because ngrok
#  runs inside that process. run_detached_if_ssh() is therefore restored from
#  patches/_template VERBATIM -- including the sshd* glob and the `bash "$SELF"`
#  re-exec, both BUG-047. Do not hand-roll either.
#
#  PAYLOAD IS THE IMAGE SOURCE, byte for byte:
#    mqtt-client.js == iot-pi stage3/03-install-mqtt-client/files/mqtt-client.js
#  as of ISSUE-068 Phase 2, so a patched device and one reflashed to the next release
#  converge on exactly the same bytes.
#
#  A NOTE ON THE PRIOR STATE, because an earlier draft of this work got it backwards.
#  The deployed mqtt-client.js (b009b68c...) is IDENTICAL to the pre-ISSUE-068 image
#  source -- the 2026-08-20-ngrok-session-reclaim and 2026-08-19-mqtt-keepalive-tolerance
#  fixes were already merged into the image, exactly as patches/README.md requires ("the
#  same fix is ALSO committed to the image source ... the image is the source of truth").
#  Installing this payload therefore REVERTS NOTHING: it is that same file plus the
#  ISSUE-068 changes.
#
#  PREREQUISITE: 2026-08-19-mqtt-keepalive-tolerance. Its output sha is this patch's only
#  accepted prior. MOST FIELD DEVICES ARE NOT AT THAT HEAD, so this patch will refuse on
#  them until the lineage is brought up: apply 2026-08-20-ngrok-session-reclaim, then
#  2026-08-19-mqtt-keepalive-tolerance, then this. A refusal prints exactly that sequence
#  rather than a bare sha mismatch. The prerequisite's marker file is checked and
#  reported, but is NEVER the gate: a device reflashed to an image that already contains
#  the keepalive code has the right sha and no marker, and must still be accepted.
#
#  ORDERING. Lineage `mqtt-client`. It shares NO file with
#  2026-08-23-log-permissions-and-rotation (directory modes + /etc/logrotate.d) or with
#  2026-08-24-ble-config-permissions (ble-config.js), so all three are independent of one
#  another and may be applied in any order. Applying all three is what closes ISSUE-068
#  on a deployed device.
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

FORCE_INLINE=0
FORCE_DETACH=0

# --- Target ------------------------------------------------------------------
MQTT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
SRC_MQTT="${SCRIPT_DIR}/mqtt-client.js"

# --- Gates -------------------------------------------------------------------
# Checksums are the authoritative gate; version lists are informational. Refusing on an
# unrecognised sha, and PRINTING it, is what makes a patch safe to hand to an operator
# who cannot inspect the device first.
FIXED_MQTT_SHA="7ecbf0ead594437934e3d0e501689a3bf99a1df77acdefb4369b57fc5655a34a"
ACCEPTED_MQTT_PRIOR_SHAS=(
  "b009b68c8692314ed8476f3bbb3b1d479c3d97fca67240f7bcf96e44444ed339"  # head of the mqtt-client lineage == pre-ISSUE-068 image source
  "${FIXED_MQTT_SHA}"                                                 # already fixed
)

KNOWN_VERSIONS=(1.0.8 1.0.9 1.0.10 1.1.2 1.1.3 1.1.4)

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

# Carried VERBATIM from patches/_template (BUG-047). $SSH_CONNECTION alone is NOT
# sufficient: sudo's env_reset strips it and the documented invocation is
# `sudo ./apply.sh`, so an environment-only check reports "local console" over SSH, runs
# the restart inline, and is killed by the tunnel drop it just caused. Matching `sshd`
# exactly is also insufficient: OpenSSH 9.8+ splits the per-connection process out as
# `sshd-session`, and under socket activation there is no `sshd` in the chain at all.
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
    log "Version '$1' is a known release for this lineage (informational; the sha is the gate)."
  else
    log "Version '$1' is not in the known-release list (informational only, not a refusal)."
  fi
}

mqtt_sha()      { [[ -f $MQTT_JS ]] && file_sha "$MQTT_JS" || printf ''; }
mqtt_main_pid() { systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || printf 'unknown'; }

report_state() {
  local m; m="$(mqtt_sha)"
  log "  ${MQTT_JS} sha: ${m:-<absent>}"
}

is_fixed() { [[ "$(mqtt_sha)" == "$FIXED_MQTT_SHA" ]]; }

# --- Prerequisite: 2026-08-19-mqtt-keepalive-tolerance ------------------------
# Its output sha IS this patch's accepted prior, so the sha check alone is
# authoritative -- but a bare "unrecognised sha" refusal tells an operator nothing about
# what to do next, and MOST FIELD DEVICES ARE NOT AT THE LINEAGE HEAD. The marker file is
# corroborating evidence only, NEVER the gate: a device reflashed to an image that
# already contains the keepalive code has the correct sha and NO marker, and must still
# be accepted.
PREREQ_PATCH="2026-08-19-mqtt-keepalive-tolerance"
PREREQ_MARKER="/usr/local/lib/eatabit/patches/${PREREQ_PATCH}/applied"
NGROK_PATCH="2026-08-20-ngrok-session-reclaim"
LINEAGE_ENTRY_NOTE="stock v1.0.8-v1.0.10 / v1.1.2-v1.1.4"

prereq_state() {
  if [[ -f $PREREQ_MARKER ]]; then printf 'marker-present'; else printf 'no-marker'; fi
}

explain_prior_mismatch() {
  local observed=$1
  log ""
  log "WHY THIS REFUSED:"
  log "  This patch requires ${PREREQ_PATCH} to have been applied first."
  log "  Its output is this patch's only accepted prior:"
  log "    ${ACCEPTED_MQTT_PRIOR_SHAS[0]}"
  log "  This device has:"
  log "    ${observed:-<mqtt-client.js absent>}"
  log "  Prerequisite marker on this device: $(prereq_state)"
  log ""
  log "WHAT TO DO:"
  log "  Bring the mqtt-client lineage up to its head, then re-run this patch:"
  log "    1. ${NGROK_PATCH}   (entry point; accepts ${LINEAGE_ENTRY_NOTE} and the"
  log "       output of every earlier patch in the lineage)"
  log "    2. ${PREREQ_PATCH}  (requires 1)"
  log "    3. this patch"
  log "  Each ships its own --check dry run. See patches/README.md -> Lineages."
  log ""
  log "  NOTE: the lineage entry point accepts only ${LINEAGE_ENTRY_NOTE}. A device on"
  log "  v1.0.1-v1.0.7, v1.1.0 or v1.1.1 CANNOT enter the lineage and so cannot take this"
  log "  patch at all. Its ble-config.js counterpart --"
  log "  2026-08-24-ble-config-permissions -- has no such restriction and still applies."
  log ""
  log "  If the observed sha matches none of the above, report it rather than forcing:"
  log "  it means this device carries something this tree does not know about."
}

do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed. (No root required.)"
  log "Payload shipped with this patch:"
  log "  mqtt-client.js : $(file_sha "$SRC_MQTT")"
  log "State on this device:"
  report_state
  log "Prerequisite ${PREREQ_PATCH}: $(prereq_state) (corroborating only; the sha is the gate)"

  if is_fixed; then
    log "RESULT: already patched -- a real run would NO-OP. (exit 0)"
    exit 0
  fi

  local m; m="$(mqtt_sha)"
  if [[ -z $m ]]; then
    log "RESULT: would REFUSE -- ${MQTT_JS} is missing. (exit 1)"; exit 1
  fi
  if ! in_list "$m" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}"; then
    log "RESULT: would REFUSE -- unrecognised ${MQTT_JS}. (exit 1)"
    explain_prior_mismatch "$m"
    exit 1
  fi

  if is_remote_session; then
    log "Detection: REMOTE -- a real run would DETACH (restarting ${SERVICE} closes this session)."
  else
    log "Detection: LOCAL -- a real run would go INLINE."
  fi
  log "NOTE: a real run RESTARTS ${SERVICE}, which DROPS IN-FLIGHT PRINT JOBS (BUG-049)."
  log "RESULT: would APPLY. (exit 2)"
  exit 2
}

__finalize_apply() {
  local v=$1
  assert_not_template
  log "Restarting ${SERVICE}..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  sleep 3
  local state; state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: ${SERVICE} is '${state}'. Recent journal:"
    journalctl -u "$SERVICE" -n 25 --no-pager || true
    fail "${SERVICE} did not return to active. Rollback with: sudo $SELF --rollback"
  fi

  # Retire the old on-card snapshots, AFTER the restart so the pre-patch process cannot
  # recreate them. Left in place they would be frozen at the moment of patching while
  # still looking like live state -- a trap for whoever next reads one to debug. They are
  # backed up first, so --rollback puts them back.
  local old_shadow_dir="/usr/local/lib/eatabit/config"
  local moved=0 f
  for f in "$old_shadow_dir"/shadow-*.json; do
    [[ -e $f ]] || continue
    mkdir -p "${BACKUP_DIR}/config-shadows"
    if cp -p "$f" "${BACKUP_DIR}/config-shadows/" && rm -f "$f"; then
      moved=$((moved + 1))
    else
      log "  WARNING: could not retire $(basename "$f") -- left in place."
    fi
  done
  if [[ $moved -gt 0 ]]; then
    log "Retired ${moved} stale on-card shadow snapshot(s) from ${old_shadow_dir}"
    log "  (backed up under ${BACKUP_DIR}/config-shadows; live copies are now in /run/eatabit)"
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. ${SERVICE}=${state}"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
  log ""
  log "To confirm the shadow fix, check the snapshots are on tmpfs and NOT on card:"
  log "  ls /run/eatabit/shadow-*.json                              # expect 3"
  log "  ls /usr/local/lib/eatabit/config/shadow-*.json             # expect none"
  log "  findmnt -no FSTYPE /run                                    # expect tmpfs"
  log "Do NOT expect the mtime to stop advancing -- these files still rewrite every 15"
  log "minutes, but on tmpfs, so they cost ZERO SD-card writes."
}

__finalize_rollback() {
  assert_not_template
  log "Restarting ${SERVICE}..."
  systemctl daemon-reload
  systemctl restart "$SERVICE" || true
  rm -f "$MARKER_FILE"
  log "Rollback complete. ${SERVICE}=$(systemctl is-active "$SERVICE" || true)"
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
  log "Prerequisite ${PREREQ_PATCH}: $(prereq_state) (corroborating only; the sha is the gate)"

  if is_fixed; then
    log "mqtt-client.js is already at the fixed sha. Nothing to do."
    exit 0
  fi

  # --- Gates, before anything is touched -------------------------------------
  local m; m="$(mqtt_sha)"
  [[ -n $m ]] || fail "${MQTT_JS} is missing. Nothing was changed."
  if ! in_list "$m" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}"; then
    explain_prior_mismatch "$m"
    fail "unrecognised ${MQTT_JS}. Nothing was changed. See the prerequisite steps above."
  fi
  [[ -r $SRC_MQTT ]] || fail "payload ${SRC_MQTT} is missing from this patch directory."

  # --- Back up BEFORE touching anything --------------------------------------
  mkdir -p "$BACKUP_DIR"
  cp -p "$MQTT_JS" "${BACKUP_DIR}/mqtt-client.js"
  log "Backed up prior file to ${BACKUP_DIR}/mqtt-client.js"

  # --- Install ---------------------------------------------------------------
  install -m 0755 -o root -g root "$SRC_MQTT" "$MQTT_JS" \
    || fail "failed to install ${MQTT_JS}. Roll back with: sudo $SELF --rollback"
  log "  installed ${MQTT_JS} ($(mqtt_sha))"

  # --- Verify bytes BEFORE restarting ----------------------------------------
  # The restart is the expensive, disruptive step (it drops in-flight print jobs), so
  # prove the file landed correctly first rather than discovering it afterwards.
  [[ "$(mqtt_sha)" == "$FIXED_MQTT_SHA" ]] || fail \
    "post-install sha mismatch on ${MQTT_JS} (got $(mqtt_sha), want ${FIXED_MQTT_SHA}). Nothing was restarted. Roll back with: sudo $SELF --rollback"
  log "Byte-level verification passed."

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

  # Put the on-card snapshots back, so a rolled-back device is indistinguishable from
  # one that never took this patch.
  if [[ -d ${BACKUP_DIR}/config-shadows ]]; then
    local restored=0 f
    for f in "${BACKUP_DIR}"/config-shadows/shadow-*.json; do
      [[ -e $f ]] || continue
      install -m 0644 -o root -g root "$f" "/usr/local/lib/eatabit/config/$(basename "$f")" \
        && restored=$((restored + 1))
    done
    [[ $restored -gt 0 ]] && log "  restored ${restored} on-card shadow snapshot(s)"
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
  --rollback  restore the pre-patch file from backup
  --inline    force the restart+verify to run in the foreground
  --detach    force the restart+verify to run detached

Scope: mqtt-client.js only. ble-config.js has its own patch,
2026-08-24-ble-config-permissions.

This patch REPLACES RUNNING CODE, so it restarts $SERVICE. That drops in-flight
print jobs (BUG-049) and drops the ngrok SSH tunnel (ngrok runs inside it), so over
SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
