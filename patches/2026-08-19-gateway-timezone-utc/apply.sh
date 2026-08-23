#!/bin/bash
# =============================================================================
#  2026-08-19-gateway-timezone-utc  (BUG-042)
# =============================================================================
#  Sets the gateway timezone to Etc/UTC. Every image inherits pi-gen's
#  TIMEZONE_DEFAULT="Europe/London" untouched, so every device reports a UK clock
#  regardless of where it is installed -- an 11-hour offset on a device in Hawaii,
#  and a DST discontinuity twice a year on every device.
#
#  Built from patches/_template (BUG-047). Two deliberate deviations from it,
#  both required by this record's acceptance criteria:
#
#  1. NO SERVICE RESTART. The template's __finalize_apply/__finalize_rollback run
#     `systemctl daemon-reload` + `systemctl restart mqtt-client.service`. Those are
#     REMOVED here, not merely left unreached. `timedatectl set-timezone` affects
#     newly written log lines on its own; nothing needs to be reloaded or bounced.
#
#  2. NO DETACH. run_detached_if_ssh() exists to survive a restart killing the ngrok
#     tunnel the operator is patching over. This patch restarts nothing, so there is
#     nothing to survive and the helper is absent by design -- keeping it would be
#     dead code whose log text ("restarting ... will CLOSE this session") is false
#     here. is_remote_session() IS kept, verbatim from the template including the
#     sshd* glob, because --check reports the session context and because a future
#     revision that ever does need a restart must use the correct detection rather
#     than reinvent it. If you add a restart, restore run_detached_if_ssh from
#     patches/_template/apply.sh -- do not hand-roll one.
#
#  APPLYING THIS PATCH MUST INTERRUPT NEITHER THE CONNECTED MQTT SESSION NOR THE SSH
#  SESSION APPLYING IT. That is a hard requirement, not a hope: `timedatectl
#  set-timezone` changes only how instants are RENDERED locally -- it moves neither
#  the absolute (UTC) instant nor the monotonic clock, so MQTT keepalive/PINGREQ
#  timers and the TLS session are untouched. Do not add anything here that signals,
#  reloads or restarts mqtt-client.
#
#  Gate: this patch does not replace a file, so there is no payload sha to compare.
#  The deployed STATE is the gate -- the contents of /etc/timezone and the target of
#  the /etc/localtime symlink. Same principle as the sha gates elsewhere (refuse an
#  unrecognised state, print what was observed); different observable.
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-19-gateway-timezone-utc"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
VERSION_FILE="/usr/local/lib/eatabit/version"
# No SERVICE variable: this patch restarts nothing. See the header.

BACKUP_TZ="${BACKUP_DIR}/etc-timezone"
BACKUP_LINK="${BACKUP_DIR}/etc-localtime.target"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Gates -------------------------------------------------------------------
# The deployed timezone is the authoritative gate; version lists are informational.
# Refusing on an unrecognised zone, and PRINTING the observed zone, is what makes this
# safe to hand to an operator who cannot inspect the device first -- and it is how an
# unsampled device reports its own state instead of merely failing.
FIXED_ZONE="Etc/UTC"                      # desired end state
# States we are willing to upgrade FROM.
#
# PROVISIONAL -- see ./README.md -> Accepted prior states. Europe/London is the
# pi-gen default proven present in all 14 released tags, so it is measured for the
# IMAGE. It is not yet measured for the FLEET: a device may have been set by hand.
# The read-only `--check` survey (BUG-042 task 3) is what fixes this list. Any zone
# found in the field that is not listed here is a deliberate decision -- add it with
# a reason in the README, or refuse it deliberately. Do not widen this list silently
# to make one device pass.
ACCEPTED_PRIOR_ZONES=("Europe/London")
KNOWN_VERSIONS=("v1.0.1" "v1.0.2" "v1.0.3" "v1.0.4" "v1.0.5" "v1.0.6" "v1.0.7" \
                "v1.0.8" "v1.0.9" "v1.0.10" \
                "v1.1.1" "v1.1.2" "v1.1.3" "v1.1.4")   # informational only

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

# The zone as systemd reports it -- authoritative, and what `timedatectl` acts on.
current_zone() { timedatectl show -p Timezone --value 2>/dev/null || true; }

# /etc/timezone's contents, trimmed. May disagree with the link; that disagreement is
# part of what this patch exists to eliminate, so both are read and both are checked.
current_tz_file() {
  [[ -r /etc/timezone ]] || { printf '(missing)'; return; }
  tr -d '[:space:]' < /etc/timezone
}

# The zone named by the /etc/localtime symlink. `readlink` WITHOUT -f on purpose:
# -f resolves through zoneinfo's own internal symlinks (Etc/UTC -> ../UTC on some
# builds) and would report a different zone name than the one actually configured.
current_tz_link() {
  local t
  t="$(readlink /etc/localtime 2>/dev/null || true)"
  [[ -n $t ]] || { printf '(not a symlink)'; return; }
  printf '%s' "${t##*zoneinfo/}"
}

in_list() { local n=$1; shift; local x; for x in "$@"; do [[ $x == "$n" ]] && return 0; done; return 1; }

# True when the device is fully in the desired end state -- ALL observables agree.
is_fixed() {
  [[ "$(current_zone)"    == "$FIXED_ZONE" ]] &&
  [[ "$(current_tz_file)" == "$FIXED_ZONE" ]] &&
  [[ "$(current_tz_link)" == "$FIXED_ZONE" ]]
}

# True when SOME observable is already at the target but not all of them -- an
# inconsistent, half-applied state. It is reachable if an earlier run died between
# `timedatectl set-timezone` and the explicit /etc/timezone write, or if someone set
# the zone by hand in a way that left the two disagreeing. Such a device must be
# CONVERGED, not refused: refusing would strand it in exactly the split-reading
# condition this record exists to eliminate, and re-running toward the target can
# only move it closer. Checked only after is_fixed has already returned false.
is_partial() {
  [[ "$(current_zone)"    == "$FIXED_ZONE" ]] ||
  [[ "$(current_tz_file)" == "$FIXED_ZONE" ]] ||
  [[ "$(current_tz_link)" == "$FIXED_ZONE" ]]
}

# Is this an SSH session? The obvious test -- $SSH_CONNECTION -- is NOT sufficient:
# sudo's env_reset strips SSH_CONNECTION/SSH_CLIENT/SSH_TTY, and the documented way to
# run this script is `sudo ./apply.sh`. Checking only the environment therefore reports
# "local console" over SSH, the restart runs inline, and it kills the ngrok tunnel it is
# running over -- the precise failure the detach exists to prevent, and the precise
# failure this patch is about. So fall back to walking the parent process chain for
# sshd, which survives sudo. Carried by hand from the 2026-08-19 patch (BUG-047).
#
# NOTE the glob in the walk below. OpenSSH 9.8+ splits the per-connection process out
# as `sshd-session` and keeps the bare name `sshd` only for the top-level listener. So
# an exact `== sshd` test does NOT match the processes directly above us -- it succeeds
# only by climbing all the way past both sshd-session frames to the listener, which is
# not what this walk is meant to be doing. Under systemd socket activation (ssh.socket)
# sshd-session is spawned by systemd and the chain becomes
#   sudo -> sshd-session -> sshd-session -> systemd(1)
# with no `sshd` anywhere: detection would report "local console", the restart would run
# INLINE, and this exact bug would reappear silently inside a patch that reads as fixed.
# `sshd*` matches sshd-session at the immediate parent. It is a strict superset of the
# old test, so it cannot regress a unit where `sshd` already worked (including
# OpenSSH < 9.8, which has no sshd-session at all), and sshd-session/sshd-auth exist
# only to service a real SSH connection, so it cannot false-positive.
# Measured on Debian 13 / OpenSSH_10.0p2, both hardware lines, 2026-08-22 (BUG-047).
# The socket-activation case above is a reasoned projection from measured process
# topology, NOT an observed failure -- ssh.socket is disabled on both bench devices.
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

# --- Safety: inherited from patches/_template --------------------------------
# Disarmed here because PATCH_ID is set to this directory's name. Kept for parity
# with the template so the guard is never the thing a copy drops.
PLACEHOLDER_PATCH_ID="YYYY-MM-DD-short-slug"
assert_not_template() {
  [[ $PATCH_ID != "$PLACEHOLDER_PATCH_ID" ]] || fail \
    "this is patches/_template -- a skeleton, not a patch. Copy it, then set PATCH_ID to the new directory name. See ./README.md"
}

# mqtt-client's MainPID, read-only. This patch must not restart the service, so the
# PID is captured before and after and reported: the apply log then carries its own
# evidence for BUG-042 V10(a) instead of relying on the operator to have checked.
mqtt_main_pid() { systemctl show -p MainPID --value mqtt-client.service 2>/dev/null || printf 'unknown'; }

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

# Informational only -- the deployed timezone is the gate, never the version string.
# A field-patched device keeps its old VERSION, so this can only ever be a hint.
note_version() {
  if in_list "$1" "${KNOWN_VERSIONS[@]}"; then
    log "Version '$1' is a known release (informational; the timezone is the gate)."
  else
    log "Version '$1' is not in the known-release list (informational only, not a refusal)."
  fi
}

report_state() {
  log "  timedatectl Timezone : $(current_zone)"
  log "  /etc/timezone        : $(current_tz_file)"
  log "  /etc/localtime    -> : $(current_tz_link)"
}

# Exit codes follow the repo convention (../README.md):
#   0 = already patched   1 = would refuse   2 = would apply
do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed."
  local v; v="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  log "Device version: $v"
  report_state
  if is_remote_session; then log "Detection: REMOTE (SSH)."
  else                       log "Detection: LOCAL console."; fi
  log "This patch restarts nothing, so that detection is informational only."

  if is_fixed; then
    log "RESULT: already ${FIXED_ZONE}. A real run would NO-OP."
    exit 0
  fi
  if is_partial; then
    log "RESULT: INCONSISTENT -- some observables are already ${FIXED_ZONE}, others are not."
    log "A real run would CONVERGE this device to ${FIXED_ZONE}."
    exit 2
  fi
  local z; z="$(current_zone)"
  if in_list "$z" "${ACCEPTED_PRIOR_ZONES[@]}"; then
    log "RESULT: would APPLY (${z} -> ${FIXED_ZONE})."
    exit 2
  fi
  log "RESULT: would REFUSE -- observed zone '${z}' is not in the accepted prior set:"
  log "  accepted: ${ACCEPTED_PRIOR_ZONES[*]}"
  log "Report this zone: an unlisted value is a decision for BUG-042, not a device fault."
  exit 1
}

set_zone() {
  local zone=$1
  command -v timedatectl >/dev/null 2>&1 || fail "timedatectl not found -- cannot set the timezone safely"
  timedatectl set-timezone "$zone" \
    || fail "timedatectl set-timezone $zone failed (is systemd-timedated available?). Nothing was changed."
  # systemd owns /etc/localtime; whether it also rewrites /etc/timezone is
  # distribution-dependent. Write it explicitly so the two CANNOT disagree -- a
  # disagreement between them is precisely the confusion BUG-042 exists to remove.
  if [[ "$(current_tz_file)" != "$zone" ]]; then
    printf '%s\n' "$zone" > /etc/timezone
    log "Wrote /etc/timezone explicitly (timedatectl left it as '$(current_tz_file)')."
  fi
}

restore_from_backup() {
  [[ -r $BACKUP_TZ ]] || return 1
  local prior; prior="$(tr -d '[:space:]' < "$BACKUP_TZ")"
  [[ -n $prior ]] || return 1
  log "Restoring prior timezone: $prior"
  set_zone "$prior"
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

  # Idempotency: a device already correct -- reflashed to v1.0.11/v1.1.5, or patched
  # already -- must NO-OP, not be refused. No marker is written in this branch: the
  # patch did not change anything, and claiming otherwise would misreport the device.
  if is_fixed; then
    log "Already ${FIXED_ZONE} on all three observables. Nothing to do."
    exit 0
  fi

  local zone_before; zone_before="$(current_zone)"
  # Half-applied device: converge rather than refuse. See is_partial().
  if is_partial; then
    log "INCONSISTENT state -- some observables are already ${FIXED_ZONE}, others are not."
    log "Converging to ${FIXED_ZONE} rather than refusing; this can only move the device toward the target."
    mkdir -p "$BACKUP_DIR"
    [[ -e $BACKUP_TZ   ]] || printf '%s\n' "$zone_before"       > "$BACKUP_TZ"
    [[ -e $BACKUP_LINK ]] || printf '%s\n' "$(current_tz_link)" > "$BACKUP_LINK"
    set_zone "$FIXED_ZONE"
    is_fixed || { log "State now:"; report_state; fail "could not converge to ${FIXED_ZONE}."; }
    log "Converged. State after:"
    report_state
    log "SWITCHOVER INSTANT (record this for BUG-042 V9): $(date -Iseconds)"
    exit 0
  fi
  if ! in_list "$zone_before" "${ACCEPTED_PRIOR_ZONES[@]}"; then
    log "Observed zone: '${zone_before}'"
    log "Accepted prior zones: ${ACCEPTED_PRIOR_ZONES[*]}"
    fail "REFUSING: '${zone_before}' is not a recognised prior state. Report this zone -- an unlisted value is a decision for BUG-042 (see ./README.md -> Accepted prior states), not something to force."
  fi

  mkdir -p "$BACKUP_DIR"
  printf '%s\n' "$zone_before"          > "$BACKUP_TZ"
  printf '%s\n' "$(current_tz_link)"    > "$BACKUP_LINK"
  log "Backed up prior state to $BACKUP_DIR"

  log "Setting timezone: ${zone_before} -> ${FIXED_ZONE}"
  set_zone "$FIXED_ZONE"

  if ! is_fixed; then
    log "Verification FAILED after setting the timezone. State now:"
    report_state
    restore_from_backup || log "WARNING: automatic restore did not run -- backup unreadable."
    fail "patch did not reach ${FIXED_ZONE}; prior state restored where possible. Nothing else was touched."
  fi

  local pid_after; pid_after="$(mqtt_main_pid)"
  log "mqtt-client MainPID after : ${pid_after}"
  if [[ $pid_before != "$pid_after" ]]; then
    # Not caused by this script -- it issues no restart -- but if it happened during
    # the window it invalidates BUG-042 V10(a) and must not pass silently.
    log "WARNING: mqtt-client MainPID CHANGED (${pid_before} -> ${pid_after})."
    log "This patch restarts nothing, so something else did. BUG-042 V10(a) is NOT satisfied for this device -- record it and raise it."
  else
    log "mqtt-client MainPID unchanged -- no restart occurred (BUG-042 V10(a))."
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nprior_timezone=%s\nnew_timezone=%s\nmqtt_mainpid_before=%s\nmqtt_mainpid_after=%s\nresult=success\n' \
    "$(date -Iseconds)" "$v" "$zone_before" "$FIXED_ZONE" "$pid_before" "$pid_after" > "$MARKER_FILE"

  log "State after:"
  report_state
  log "Patch applied successfully. No service was restarted."
  log "SWITCHOVER INSTANT (record this for BUG-042 V9): $(date -Iseconds)"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
}

do_rollback() {
  require_root
  assert_not_template
  start_logging rollback
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  [[ -r $BACKUP_TZ  ]] || fail "no backup at $BACKUP_TZ -- nothing to roll back"
  local prior; prior="$(tr -d '[:space:]' < "$BACKUP_TZ")"
  [[ -n $prior ]] || fail "backup at $BACKUP_TZ is empty -- refusing to guess a timezone"

  log "State before rollback:"
  report_state
  log "Restoring timezone: $(current_zone) -> ${prior}"
  set_zone "$prior"

  if [[ "$(current_zone)" != "$prior" ]]; then
    log "State now:"; report_state
    fail "rollback did not reach '${prior}'."
  fi
  rm -f "$MARKER_FILE"
  log "State after rollback:"
  report_state
  log "Rollback complete. No service was restarted."
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
  -h|--help)
    cat <<EOF
Usage: $0 [--inline|--detach] [apply|--check|--rollback]
  apply       (default) set the gateway timezone to ${FIXED_ZONE}
  --check     DRY RUN, no root needed, changes nothing
              exit 0 = already ${FIXED_ZONE}   1 = would refuse   2 = would apply
  --rollback  restore the pre-patch timezone from backup

This patch RESTARTS NOTHING. \`timedatectl set-timezone\` affects newly written log
lines on its own, so applying it interrupts neither the connected MQTT session nor
the SSH session you are running it over. There is therefore no detached mode: the
--inline / --detach flags are accepted for consistency with the other patches in
this directory but change nothing here.
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
