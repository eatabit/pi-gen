#!/bin/bash
# =============================================================================
#  2026-08-23-log-permissions-and-rotation  (ISSUE-068, Phase 2)
# =============================================================================
#  Makes logrotate able to rotate the eatabit logs at all, on already-deployed
#  devices.
#
#  /usr/local/lib/eatabit/log ships mode 0777. logrotate REFUSES to act on a file
#  whose parent directory is world-writable unless the config carries an `su`
#  directive, and /etc/logrotate.d/eatabit-mqtt-client carries none. So it aborts
#  with:
#
#    error: skipping "/usr/local/lib/eatabit/log/mqtt-client.log" because parent
#    directory has insecure permissions (It's world writable or writable by group
#    which is not "root") Set "su" directive in config file...
#
#  mqtt-client.log has therefore NEVER been rotated -- not once, on any of the 15
#  release tags, on either hardware line. Verified by `logrotate --debug` on three
#  devices spanning both lines, with zero rotated siblings present on any of them
#  (ISSUE-068 Phase 1 -> Findings, audit section 6).
#
#  Three changes, applied together:
#    1. /usr/local/lib/eatabit/{log,config,reset} 0777 -> 0755
#    2. /etc/logrotate.d/eatabit-mqtt-client: create 0666 -> create 0644
#    3. /etc/logrotate.d/eatabit-ble-config: NEW -- ble-config.log had no rotation
#       config at all, on any release
#
#  Why 0755 rather than adding `su root root`: the MODE is the cause, so 0755 fixes
#  the class and covers every future file in the directory, where `su` fixes one
#  stanza and leaves the world-writable directory standing for the next file to trip
#  over. Safe because every writer runs as root -- all eight systemd units that touch
#  /usr/local/lib/eatabit (three declare User=root, five leave User= empty, which for
#  a system unit means root), with no cron writer, no user crontabs, and no non-root
#  process holding a descriptor there. Established on three devices, both lines
#  (ISSUE-068 Phase 1 -> Findings, audit section 7).
#
#  Why `create 0644`: at 0666 logrotate re-creates every ROTATED file world-writable,
#  perpetuating the exact condition that blocked rotation in the first place.
#
#  Why ble-config.log gets `maxsize 5M` as well as `daily`: its measured steady-state
#  growth is 0 B/h -- it is event-driven and only grows on BLE pairing activity -- so
#  the risk it carries is a burst during a pairing storm, not a steady climb. The size
#  trigger bounds the burst; the time trigger bounds everything else.
#
#  THE PAYLOAD FILES ARE BYTE-IDENTICAL TO WHAT THE IMAGE NOW WRITES (iot-pi
#  stage3/03-install-mqtt-client/00-run.sh and stage3/08-ble-config/00-run.sh, as of
#  ISSUE-068 Phase 2). A patched device and a freshly-imaged device therefore converge
#  on exactly the same state rather than drifting into two similar-but-different ones.
#
#  Built from patches/_template (BUG-047). Two deliberate deviations from it, the same
#  two the 2026-08-19-log2ram-timer-hourly-sync and 2026-08-19-gateway-timezone-utc
#  patches make, and for the same reason:
#
#  1. NO SERVICE RESTART. The template's __finalize_apply/__finalize_rollback run
#     `systemctl daemon-reload` + `systemctl restart mqtt-client.service`. Both are
#     REMOVED here, not merely left unreached. THIS PATCH RESTARTS NOTHING and is safe
#     to apply to a live, printing device with no maintenance window. Unlike the
#     log2ram timer patch, this one does not even need `daemon-reload`: it writes no
#     unit file and no drop-in. logrotate re-reads /etc/logrotate.d on every run, and
#     directory modes are read at open() time, so both changes take effect with no
#     signal to anything. mqtt-client's MainPID is captured before and after as
#     evidence that nothing was disturbed.
#
#  2. NO DETACH. run_detached_if_ssh() exists to survive a restart killing the ngrok
#     tunnel the operator is patching over. This patch restarts nothing, so there is
#     nothing to survive, and keeping the helper would be dead code whose log text
#     ("restarting ... will CLOSE this session") is simply false here.
#     is_remote_session() IS kept, verbatim from the template including the sshd* glob,
#     because --check reports the session context and because a future revision that
#     ever does need a restart must use the correct detection rather than reinvent it.
#     If you add a restart, restore run_detached_if_ssh from patches/_template/apply.sh
#     -- do not hand-roll one.
#
#  Lineage: NEW AND INDEPENDENT. Target files are the three directory modes and
#  /etc/logrotate.d/{eatabit-mqtt-client,eatabit-ble-config}. NO OTHER PATCH IN THIS
#  TREE TOUCHES ANY OF THEM -- verified: no patch writes /etc/logrotate.d at all, and
#  none alters a directory mode. It shares no checksum with the mqtt-client, bluetooth,
#  timezone or log2ram lineages and may be applied at any point in a campaign, before
#  or after any of them, or entirely on its own.
#
#  NOT IN THIS PATCH, deliberately: the application-code half of ISSUE-068 Phase 2 --
#  mqtt-client.js / ble-config.js create these directories at 0o777 and their log files
#  at 0o666 when they find them missing, and mqtt-client.js also rewrites
#  shadow-health.json every 15 minutes. Those live in the mqtt-client lineage, whose
#  deployed head is 2026-08-19-mqtt-keepalive-tolerance; a payload for them must be
#  built ON TOP of that patch's output or it silently reverts it. That is a separate
#  patch. CONSEQUENCE FOR THIS ONE: if a service is ever started while one of these
#  directories is ABSENT, the application will re-create it 0777 and rotation will
#  break again. Re-running this patch fixes it; the permanent fix is the image (or the
#  application patch).
# =============================================================================
set -uo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-23-log-permissions-and-rotation"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
VERSION_FILE="/usr/local/lib/eatabit/version"
# No SERVICE variable: this patch restarts nothing. See the header.

BACKUP_MODES="${BACKUP_DIR}/dir-modes"
BACKUP_MQTT_CONF="${BACKUP_DIR}/eatabit-mqtt-client"
BACKUP_BLE_EXISTED="${BACKUP_DIR}/ble-config-existed"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Targets -----------------------------------------------------------------
EATABIT_DIRS=(
  /usr/local/lib/eatabit/log
  /usr/local/lib/eatabit/config
  /usr/local/lib/eatabit/reset
)
TARGET_MODE="755"

LOGROTATE_D="/etc/logrotate.d"
MQTT_CONF="${LOGROTATE_D}/eatabit-mqtt-client"
BLE_CONF="${LOGROTATE_D}/eatabit-ble-config"

SRC_MQTT_CONF="${SCRIPT_DIR}/eatabit-mqtt-client"
SRC_BLE_CONF="${SCRIPT_DIR}/eatabit-ble-config"

# --- Gates -------------------------------------------------------------------
# Checksums are the authoritative gate; version lists are informational. Refusing on
# an unrecognised sha, and PRINTING the observed sha, is what makes a patch safe to
# hand to an operator who cannot inspect the device first.
FIXED_MQTT_SHA="09c2f9fa8a5420af87e98d413e65908f4861149ecd44a26c865a3b7d9e9ce801"
FIXED_BLE_SHA="3a6028e43a236676452ce545d78337d567202237551dc6e6a8e8bb21b1f72b3a"

# The stock config, byte-identical on every release tag of both hardware lines: the
# build script's logrotate heredoc is unchanged across all three blobs that
# stage3/03-install-mqtt-client/00-run.sh has ever had.
ACCEPTED_MQTT_PRIOR_SHAS=(
  "73e6530d260a82278f678a2e3d41d387f7918068aa3f9eca58a2b7eecd5f0710"  # stock, all tags
  "${FIXED_MQTT_SHA}"                                                 # already fixed
)

# Modes we are willing to move FROM. 777 is stock; 755 is already-correct.
ACCEPTED_DIR_MODES=("777" "755")

KNOWN_VERSIONS=(1.0.1 1.0.2 1.0.3 1.0.4 1.0.5 1.0.6 1.0.7 1.0.8 1.0.9 1.0.10
                1.1.0 1.1.1 1.1.2 1.1.3 1.1.4)

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
dir_mode() { stat -c '%a' "$1" 2>/dev/null || printf ''; }

in_list() {
  local needle=$1; shift
  local x
  for x in "$@"; do [[ $x == "$needle" ]] && return 0; done
  return 1
}

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

# --- Safety: this file is a TEMPLATE, not a patch -----------------------------
PLACEHOLDER_PATCH_ID="YYYY-MM-DD-short-slug"
assert_not_template() {
  [[ $PATCH_ID != "$PLACEHOLDER_PATCH_ID" ]] || fail \
    "this is patches/_template -- a skeleton, not a patch. Copy it, then set PATCH_ID to the new directory name. See ./README.md"
}

# Is this an SSH session? Kept verbatim from patches/_template (BUG-047) even though
# this patch never detaches: --check reports the session context, and a future revision
# that DOES need a restart must use the correct detection rather than reinvent it.
# $SSH_CONNECTION alone is insufficient (sudo's env_reset strips it), and matching
# `sshd` exactly is insufficient (OpenSSH 9.8+ splits out `sshd-session`), hence the
# parent-walk and the sshd* glob.
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

# =============================================================================
#  PATCH-SPECIFIC
# =============================================================================

# Everything an apply/rollback prints also lands in $LOG, so a device keeps its own
# record. The template got this for free from the detached redirect; this patch does
# not detach (it restarts nothing), so it is done explicitly. --check never calls this:
# it is read-only and must work without root.
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

mqtt_main_pid() { systemctl show mqtt-client.service -p MainPID --value 2>/dev/null || printf 'unknown'; }

mqtt_conf_sha() { [[ -f $MQTT_CONF ]] && file_sha "$MQTT_CONF" || printf ''; }
ble_conf_sha()  { [[ -f $BLE_CONF  ]] && file_sha "$BLE_CONF"  || printf ''; }

report_state() {
  local d m
  for d in "${EATABIT_DIRS[@]}"; do
    m="$(dir_mode "$d")"
    log "  ${d} mode: ${m:-<absent>}"
  done
  local s
  s="$(mqtt_conf_sha)"; log "  ${MQTT_CONF} sha: ${s:-<absent>}"
  s="$(ble_conf_sha)";  log "  ${BLE_CONF} sha: ${s:-<absent>}"
}

# True only when EVERY observable is in the desired end state. A correct logrotate
# config with a 0777 parent directory is NOT fixed -- logrotate would still skip it.
is_fixed() {
  local d m
  for d in "${EATABIT_DIRS[@]}"; do
    m="$(dir_mode "$d")"
    [[ $m == "$TARGET_MODE" ]] || return 1
  done
  [[ "$(mqtt_conf_sha)" == "$FIXED_MQTT_SHA" ]] || return 1
  [[ "$(ble_conf_sha)"  == "$FIXED_BLE_SHA"  ]] || return 1
  return 0
}

do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed. (No root required.)"
  log "Payload shipped with this patch:"
  log "  eatabit-mqtt-client sha: $(file_sha "$SRC_MQTT_CONF")"
  log "  eatabit-ble-config  sha: $(file_sha "$SRC_BLE_CONF")"
  log "State on this device:"
  report_state

  if is_fixed; then
    log "RESULT: already patched -- a real run would NO-OP. (exit 0)"
    exit 0
  fi

  # Mirror do_apply's gates exactly, without touching anything.
  local d m
  for d in "${EATABIT_DIRS[@]}"; do
    m="$(dir_mode "$d")"
    if [[ -z $m ]]; then
      log "RESULT: would REFUSE -- ${d} does not exist. (exit 1)"
      exit 1
    fi
    if ! in_list "$m" "${ACCEPTED_DIR_MODES[@]}"; then
      log "RESULT: would REFUSE -- ${d} has unrecognised mode ${m} (accepted: ${ACCEPTED_DIR_MODES[*]}). (exit 1)"
      log "Report this mode -- something else is managing it."
      exit 1
    fi
  done

  local cs; cs="$(mqtt_conf_sha)"
  if [[ -z $cs ]]; then
    log "RESULT: would REFUSE -- ${MQTT_CONF} is missing. (exit 1)"
    exit 1
  fi
  if ! in_list "$cs" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}"; then
    log "RESULT: would REFUSE -- unrecognised ${MQTT_CONF}:"
    log "  observed: ${cs}"
    log "  accepted: ${ACCEPTED_MQTT_PRIOR_SHAS[*]}"
    log "Report this sha -- it is a decision for ISSUE-068, not a device fault. (exit 1)"
    exit 1
  fi

  local bs; bs="$(ble_conf_sha)"
  if [[ -n $bs && $bs != "$FIXED_BLE_SHA" ]]; then
    log "RESULT: would REFUSE -- an unrecognised ${BLE_CONF} already exists (observed ${bs}). (exit 1)"
    log "Something else is managing it -- report it rather than overwriting it."
    exit 1
  fi

  if is_remote_session; then log "Detection: REMOTE session."
  else                       log "Detection: LOCAL console."; fi
  log "This patch restarts nothing, so that detection is informational only."
  log "RESULT: would APPLY. (exit 2)"
  exit 2
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

  local pid_before; pid_before="$(mqtt_main_pid)"
  log "mqtt-client MainPID before: ${pid_before}"

  # Idempotency: a device already correct -- reflashed to a post-ISSUE-068 image, or
  # patched already -- must NO-OP, not be refused. No marker is written in this branch:
  # the patch changed nothing, and claiming otherwise would misreport the device.
  if is_fixed; then
    log "Directories are ${TARGET_MODE} and both logrotate configs are current. Nothing to do."
    exit 0
  fi

  # --- Gates, before anything is touched -------------------------------------
  local d m
  for d in "${EATABIT_DIRS[@]}"; do
    m="$(dir_mode "$d")"
    [[ -n $m ]] || fail "${d} does not exist. Nothing was changed."
    in_list "$m" "${ACCEPTED_DIR_MODES[@]}" || fail \
      "${d} has unrecognised mode ${m} (accepted: ${ACCEPTED_DIR_MODES[*]}). Nothing was changed. Report this -- something else is managing it."
  done

  local cs; cs="$(mqtt_conf_sha)"
  [[ -n $cs ]] || fail "${MQTT_CONF} is missing -- is the mqtt-client stage installed? Nothing was changed."
  in_list "$cs" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}" || fail \
    "unrecognised ${MQTT_CONF} (observed ${cs}; accepted ${ACCEPTED_MQTT_PRIOR_SHAS[*]}). Nothing was changed. Report this sha -- it is a decision for ISSUE-068, not a device fault."

  local bs; bs="$(ble_conf_sha)"
  if [[ -n $bs && $bs != "$FIXED_BLE_SHA" ]]; then
    fail "an unrecognised ${BLE_CONF} already exists (observed ${bs}; expected ${FIXED_BLE_SHA}). Nothing was changed. Something else is managing it -- report it rather than overwriting it."
  fi

  [[ -r $SRC_MQTT_CONF ]] || fail "payload ${SRC_MQTT_CONF} is missing from this patch directory."
  [[ -r $SRC_BLE_CONF  ]] || fail "payload ${SRC_BLE_CONF} is missing from this patch directory."

  # --- Back up BEFORE touching anything --------------------------------------
  mkdir -p "$BACKUP_DIR"
  : > "$BACKUP_MODES"
  for d in "${EATABIT_DIRS[@]}"; do
    printf '%s %s\n' "$(dir_mode "$d")" "$d" >> "$BACKUP_MODES"
  done
  cp -p "$MQTT_CONF" "$BACKUP_MQTT_CONF"
  if [[ -f $BLE_CONF ]]; then printf 'yes\n' > "$BACKUP_BLE_EXISTED"
  else                        printf 'no\n'  > "$BACKUP_BLE_EXISTED"; fi
  log "Backed up prior state to ${BACKUP_DIR}"

  # --- Apply -----------------------------------------------------------------
  for d in "${EATABIT_DIRS[@]}"; do
    chmod "$TARGET_MODE" "$d" || fail "failed to chmod ${d}. Roll back with: sudo $SELF --rollback"
    log "  ${d} -> $(dir_mode "$d")"
  done

  install -m 0644 -o root -g root "$SRC_MQTT_CONF" "$MQTT_CONF" \
    || fail "failed to install ${MQTT_CONF}. Roll back with: sudo $SELF --rollback"
  log "  installed ${MQTT_CONF} ($(file_sha "$MQTT_CONF"))"

  install -m 0644 -o root -g root "$SRC_BLE_CONF" "$BLE_CONF" \
    || fail "failed to install ${BLE_CONF}. Roll back with: sudo $SELF --rollback"
  log "  installed ${BLE_CONF} ($(file_sha "$BLE_CONF"))"

  # --- Verify ----------------------------------------------------------------
  is_fixed || fail "post-apply verification FAILED -- the device is not in the expected end state. Roll back with: sudo $SELF --rollback"

  # The real proof is logrotate's own dry run: it is what refused before, so it is what
  # must stop refusing. Unit state is NOT evidence -- a freshly rebooted device reports
  # logrotate.service as 'inactive' merely because the daily timer has not fired yet,
  # which reads as healthy whether or not this patch worked (ISSUE-068 Phase 1).
  local rc=0
  local out; out="$(logrotate --debug "$MQTT_CONF" 2>&1)" || rc=$?
  if printf '%s' "$out" | grep -q 'insecure permissions'; then
    log "VERIFY FAILED -- logrotate still reports insecure permissions:"
    printf '%s\n' "$out" | tail -5
    fail "rotation is still blocked. Roll back with: sudo $SELF --rollback"
  fi
  log "Verified: logrotate --debug no longer reports insecure permissions (rc=${rc})."

  local pid_after; pid_after="$(mqtt_main_pid)"
  log "mqtt-client MainPID after : ${pid_after}"
  if [[ $pid_before == "$pid_after" ]]; then
    log "mqtt-client was NOT restarted, as intended."
  else
    log "NOTE: mqtt-client MainPID changed (${pid_before} -> ${pid_after})."
    log "This patch restarts nothing, so it did not cause that -- but investigate before trusting this apply."
  fi

  log "State after:"
  report_state

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Nothing was restarted."
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
  log ""
  log "Rotation will occur on the next logrotate run (daily timer). To rotate now:"
  log "  sudo logrotate -f ${MQTT_CONF}"
}

do_rollback() {
  require_root
  assert_not_template
  start_logging rollback
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"

  log "State before rollback:"
  report_state

  if [[ -r $BACKUP_MODES ]]; then
    local m d
    while read -r m d; do
      [[ -n ${m:-} && -n ${d:-} ]] || continue
      chmod "$m" "$d" 2>/dev/null && log "  restored ${d} to ${m}" || log "  WARNING: could not restore ${d} to ${m}"
    done < "$BACKUP_MODES"
  else
    log "  WARNING: ${BACKUP_MODES} missing -- directory modes left as they are."
  fi

  if [[ -r $BACKUP_MQTT_CONF ]]; then
    install -m 0644 -o root -g root "$BACKUP_MQTT_CONF" "$MQTT_CONF" \
      && log "  restored ${MQTT_CONF}"
  else
    log "  WARNING: ${BACKUP_MQTT_CONF} missing -- ${MQTT_CONF} left as it is."
  fi

  if [[ -r $BACKUP_BLE_EXISTED ]] && [[ "$(cat "$BACKUP_BLE_EXISTED")" == "no" ]]; then
    rm -f "$BLE_CONF" && log "  removed ${BLE_CONF} (it did not exist before this patch)"
  fi

  rm -f "$MARKER_FILE"
  log "State after rollback:"
  report_state
  log "Rollback complete. Nothing was restarted."
}

# =============================================================================
#  Entry point
# =============================================================================
ACTION="apply"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inline)   FORCE_INLINE=1; shift ;;
    --detach)   FORCE_DETACH=1; shift ;;
    --check)    ACTION="check"; shift ;;
    --rollback) ACTION="rollback"; shift ;;
    -h|--help)
      sed -n '2,90p' "$SELF"
      exit 0 ;;
    *) fail "unknown argument: $1 (try --help)" ;;
  esac
done

case "$ACTION" in
  check)    do_check ;;
  rollback) do_rollback ;;
  apply)    do_apply ;;
esac
