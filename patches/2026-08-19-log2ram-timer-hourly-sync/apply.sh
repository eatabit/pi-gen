#!/bin/bash
# =============================================================================
#  2026-08-19-log2ram-timer-hourly-sync  (BUG-041, Phase A)
# =============================================================================
#  Enables log2ram-daily.timer and overrides it to fire HOURLY.
#
#  The image installs log2ram-daily.timer but never enables it: stage3/
#  05-install-log2ram/00-run.sh installs the unit, then enables `log2ram` -- the
#  SERVICE -- and nothing ever enables the TIMER. /var/log is a 64M tmpfs, so with
#  no timer the RAM copy reaches the SD card ONLY via log2ram.service's stop action,
#  i.e. only on a clean shutdown. StartLimitAction=reboot-force (BUG-044) reboots
#  WITHOUT a clean stop, so everything logged since boot is destroyed by exactly the
#  event you most need to explain.
#
#  Two changes, both required; neither is sufficient alone:
#    1. systemctl enable --now log2ram-daily.timer
#    2. a drop-in overriding the stock OnCalendar=*-*-* 23:55:00 to hourly
#
#  Why (2) is not optional: the stock timer is a FIXED DAILY WALL-CLOCK INSTANT, not
#  a rolling 24h. Worst-case loss is therefore ~23h55m pegged to one moment. Hourly
#  costs a derived ceiling of ~1 MB/day of extra card writes, because log2ram syncs
#  with `rsync -aAXv --sparse --inplace --no-whole-file --delete-after`: only CHANGED
#  BLOCKS are written, so the same appended bytes reach the card either way and
#  raising the frequency multiplies only partial-tail-block amplification, not log
#  volume. log2ram exists for card longevity and that reason is respected here, not
#  undone. Full reasoning: BUG-041 planning.md -> F1, F2, D2.
#
#  REJECTED, recorded so it is not re-proposed: making journald persistent
#  (Storage=persistent, SystemMaxUse=50M). It would place a 50 MB journal inside a
#  64 MB RAM disk on a device with ~415 MB total RAM, and -- because /var/log IS the
#  tmpfs -- it would STILL not survive a forced reboot. See planning.md -> D4.
#
#  Built from patches/_template (BUG-047). Two deliberate deviations from it, the
#  same two the 2026-08-19-gateway-timezone-utc patch makes and for the same reason:
#
#  1. NO SERVICE RESTART. The template's __finalize_apply/__finalize_rollback run
#     `systemctl daemon-reload` + `systemctl restart mqtt-client.service`. The
#     RESTART is REMOVED here, not merely left unreached. THIS PATCH RESTARTS
#     NOTHING and is safe to apply to a live, printing device with no maintenance
#     window. `systemctl daemon-reload` IS kept and IS required -- this patch writes
#     a unit drop-in and systemd will not see it otherwise -- but daemon-reload only
#     re-reads unit files: it restarts no service and signals mqtt-client not at all.
#     mqtt-client's MainPID is captured before and after as evidence (BUG-041 V6).
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
#  Lineage: log2ram. Target files /etc/systemd/system/log2ram-daily.timer.d/
#  hourly.conf and /etc/log2ram.conf. NO OTHER PATCH IN THIS TREE TOUCHES EITHER, so
#  this is a new, independent lineage sharing no checksum with mqtt-client,
#  bluetooth or timezone. It may be applied at any point in a campaign, before or
#  after any of them, or entirely on its own.
#
#  Gate: this patch REPLACES no file -- it adds a drop-in and enables a unit -- so
#  there is no replaced-file payload sha. The deployed STATE is the gate: the sha of
#  the drop-in (absent / ours / unrecognised), and whether the timer is enabled.
#  /etc/log2ram.conf is asserted but never modified: it is a sanity check that this
#  really is a stock eatabit image. Same principle as the sha gates elsewhere
#  (refuse an unrecognised state, PRINT what was observed); different observable.
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-19-log2ram-timer-hourly-sync"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
VERSION_FILE="/usr/local/lib/eatabit/version"
# No SERVICE variable: this patch restarts nothing. See the header.

# --- Targets -----------------------------------------------------------------
TIMER="log2ram-daily.timer"
DROPIN_DIR="/etc/systemd/system/log2ram-daily.timer.d"
DROPIN="${DROPIN_DIR}/hourly.conf"
LOG2RAM_CONF="/etc/log2ram.conf"

BACKUP_ENABLED_STATE="${BACKUP_DIR}/timer.is-enabled"
BACKUP_DROPIN_EXISTED="${BACKUP_DIR}/hourly.conf.existed"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Gates -------------------------------------------------------------------
# Checksums are the authoritative gate; version lists are informational. Refusing on
# an unrecognised sha, and PRINTING the observed sha, is what makes a patch safe to
# hand to an operator who cannot inspect the device first.
#
# FIXED_SHA is the sha256 of the drop-in this patch installs. It is ALSO asserted
# against the bytes we actually write (see write_dropin), so this constant and the
# heredoc below cannot drift apart silently -- and so a device reflashed to
# v1.0.11/v1.1.5 lands on exactly this sha and the patch no-ops (BUG-041 V8).
FIXED_SHA="2ab148d15a6b96479c936b58443eeb971eb043528fe1502f6b15546c4efcee07"

# /etc/log2ram.conf is ASSERTED, never modified. TWO accepted shas:
#
#   244f4c5a...  the conf as shipped on all 15 release tags (v1.0.1-v1.0.10,
#                v1.1.0-v1.1.4), verified 2026-08-23 by hashing the file at every tag --
#                a single distinct sha came back. This is what every FIELD device has.
#   7bfdcc52...  the conf after ISSUE-068 Phase 3, which removed four keys log2ram never
#                read (LOG_DIRS, COMP, MAIL, ENABLED) and left only the two it does
#                (SIZE, USE_RSYNC). Devices reflashed to a post-ISSUE-068 image carry this.
#
# THE SECOND ENTRY IS NOT OPTIONAL. This patch REFUSES on an unrecognised conf, so
# without it every device running a post-ISSUE-068 image would be rejected by a patch
# that is otherwise perfectly applicable to it -- the conf is only asserted here, never
# modified, and neither key this patch depends on changed. Added in the same change that
# altered the conf, exactly as ISSUE-068's acceptance criteria require.
#
# NOTE for whoever cuts v1.0.11 / v1.1.5: BUG-041's V8 byte-identity requirement -- that
# the patched device match the next release byte for byte -- must be re-established
# against the NEW conf, since the release will ship 7bfdcc52 rather than 244f4c5a. That
# check cannot be completed until those tags exist.
ACCEPTED_CONF_SHAS=(
  "244f4c5ad6d1231321685052f9016bbd5016a1848de6f46460afd17bfb1d0c46"  # v1.0.1-v1.1.4 (all field devices today)
  "7bfdcc52bda347f040e866a500803236810973580eb7eaf30313d1bbd814bfb9"  # post-ISSUE-068 image
)

KNOWN_VERSIONS=("1.0.1" "1.0.2" "1.0.3" "1.0.4" "1.0.5" "1.0.6" "1.0.7" \
                "1.0.8" "1.0.9" "1.0.10" \
                "1.1.0" "1.1.1" "1.1.2" "1.1.3" "1.1.4")   # informational only

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
in_list() { local n=$1; shift; local x; for x in "$@"; do [[ $x == "$n" ]] && return 0; done; return 1; }

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

# --- Safety: this file is a TEMPLATE, not a patch -----------------------------
# Retained from _template. PATCH_ID is set above, so this is disarmed; it stays so
# that a future copy of THIS file inherits the guard rather than losing it.
PLACEHOLDER_PATCH_ID="YYYY-MM-DD-short-slug"
assert_not_template() {
  [[ $PATCH_ID != "$PLACEHOLDER_PATCH_ID" ]] || fail \
    "this is patches/_template -- a skeleton, not a patch. Copy it, then set PATCH_ID to the new directory name. See ./README.md"
}

# Is this an SSH session? Kept VERBATIM from _template/apply.sh including the sshd*
# glob -- see that file's comment block for why $SSH_CONNECTION alone and a bare
# `sshd` match are both insufficient (BUG-047). This patch restarts nothing, so
# nothing here is load-bearing today; it exists so --check can report the session
# context, and so a future revision that DOES restart something starts from correct
# detection rather than reinventing it. Do not "tidy" the glob.
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

# mqtt-client's MainPID, read-only. This patch must not restart the service, so the
# PID is captured before and after and reported: the apply log then carries its own
# evidence for BUG-041 V6 instead of relying on the operator to have checked.
mqtt_main_pid() { systemctl show -p MainPID --value mqtt-client.service 2>/dev/null || printf 'unknown'; }

# =============================================================================
#  PATCH-SPECIFIC
# =============================================================================

# Everything an apply/rollback prints also lands in $LOG, so a device keeps its own
# record. The template got this for free from the detached redirect; this patch does
# not detach (it restarts nothing), so it is done explicitly. --check never calls
# this: it is read-only and must work without root.
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

# NOTE: `systemctl is-enabled` exits NON-ZERO for a disabled/static unit while still
# PRINTING the state on stdout. A naive `systemctl is-enabled ... || printf unknown`
# therefore emits "disabled" AND "unknown" concatenated -- which lands in the log, in
# the backup file, and in every refusal message. Capture stdout, discard the status,
# and fall back only when nothing was printed at all.
timer_enabled_state() {
  local s; s="$(systemctl is-enabled "$TIMER" 2>/dev/null)" || true
  printf '%s' "${s:-unknown}"
}
dropin_sha()          { [[ -f $DROPIN ]] && file_sha "$DROPIN" || printf ''; }
conf_sha()            { [[ -f $LOG2RAM_CONF ]] && file_sha "$LOG2RAM_CONF" || printf ''; }

report_state() {
  log "  ${TIMER} is-enabled : $(timer_enabled_state)"
  local d; d="$(dropin_sha)"
  log "  hourly.conf sha      : ${d:-<absent>}"
  log "  /etc/log2ram.conf sha: $(conf_sha)"
}

# True only when BOTH observables are in the desired end state. A drop-in with the
# right bytes but a disabled timer is NOT fixed -- the sync would never fire.
is_fixed() {
  [[ "$(dropin_sha)" == "$FIXED_SHA" ]] && [[ "$(timer_enabled_state)" == "enabled" ]]
}

# Write the drop-in, then PROVE the bytes match FIXED_SHA. Without this assertion the
# constant above and the heredoc below could drift apart in a future edit and the
# patch would install a file it then refuses to recognise on the next run.
write_dropin() {
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN" <<'HOURLY_CONF'
[Timer]
# OnCalendar= is a LIST in systemd. The empty assignment CLEARS the inherited
# 23:55 entry -- without it this timer fires hourly AND at 23:55. Do not delete it.
# systemd-analyze verify cannot catch that case: an additive list is legal.
# Assert with: systemctl show log2ram-daily.timer -p TimersCalendar  (exactly one entry)
OnCalendar=
OnCalendar=hourly
Persistent=true
HOURLY_CONF
  chmod 0644 "$DROPIN"
  local got; got="$(file_sha "$DROPIN")"
  [[ $got == "$FIXED_SHA" ]] || fail \
    "internal: wrote hourly.conf with sha ${got}, expected ${FIXED_SHA}. The heredoc and FIXED_SHA have drifted -- fix the patch, not the device."
}

# The assertion systemd-analyze verify CANNOT make. An additive OnCalendar= list is
# perfectly legal systemd, so `verify` passes on a timer firing hourly AND at 23:55.
# Exactly one calendar entry is the only proof the reset line took effect.
assert_single_calendar_entry() {
  local out n
  out="$(systemctl show "$TIMER" -p TimersCalendar --value 2>/dev/null || printf '')"
  n="$(printf '%s\n' "$out" | grep -c 'OnCalendar' || true)"
  log "  TimersCalendar: ${out:-<empty>}"
  [[ $n -eq 1 ]] || return 1
  printf '%s' "$out" | grep -q 'hourly\|\*-\*-\* \*:00:00' || return 1
  return 0
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
    log "RESULT: already enabled with the hourly override. A real run would NO-OP."
    exit 0
  fi

  local cs; cs="$(conf_sha)"
  if [[ -z $cs ]]; then
    log "RESULT: would REFUSE -- ${LOG2RAM_CONF} is missing. Is log2ram installed?"
    exit 1
  fi
  if ! in_list "$cs" "${ACCEPTED_CONF_SHAS[@]}"; then
    log "RESULT: would REFUSE -- unrecognised ${LOG2RAM_CONF}:"
    log "  observed: ${cs}"
    log "  accepted: ${ACCEPTED_CONF_SHAS[*]}"
    log "Report this sha: an unlisted value is a decision for BUG-041, not a device fault."
    exit 1
  fi

  local ds; ds="$(dropin_sha)"
  if [[ -n $ds && $ds != "$FIXED_SHA" ]]; then
    log "RESULT: would REFUSE -- an unrecognised drop-in already exists at ${DROPIN}:"
    log "  observed: ${ds}"
    log "  expected: ${FIXED_SHA}"
    log "Something else is managing this timer. Report it; do not delete it blindly."
    exit 1
  fi

  if [[ $ds == "$FIXED_SHA" ]]; then
    log "RESULT: would APPLY -- drop-in is correct but ${TIMER} is '$(timer_enabled_state)'."
    log "A real run would CONVERGE this device by enabling the timer."
  else
    log "RESULT: would APPLY -- install the hourly drop-in and enable ${TIMER}."
  fi
  exit 2
}

restore_from_backup() {
  log "Auto-restoring pre-patch state..."
  if [[ -r $BACKUP_DROPIN_EXISTED ]] && [[ "$(cat "$BACKUP_DROPIN_EXISTED")" == "no" ]]; then
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    log "  removed ${DROPIN} (it did not exist before this patch)"
  fi
  if [[ -r $BACKUP_ENABLED_STATE ]]; then
    local prior; prior="$(cat "$BACKUP_ENABLED_STATE")"
    if [[ $prior != "enabled" ]]; then
      systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
      log "  restored ${TIMER} to '${prior}'"
    fi
  fi
  systemctl daemon-reload || true
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
    log "Already enabled with the hourly override. Nothing to do."
    exit 0
  fi

  # --- Gates, before anything is touched -------------------------------------
  local cs; cs="$(conf_sha)"
  [[ -n $cs ]] || fail "${LOG2RAM_CONF} is missing -- is log2ram installed? Nothing was changed."
  in_list "$cs" "${ACCEPTED_CONF_SHAS[@]}" || fail \
    "unrecognised ${LOG2RAM_CONF} (observed ${cs}; accepted ${ACCEPTED_CONF_SHAS[*]}). Nothing was changed. Report this sha -- it is a decision for BUG-041, not a device fault."

  local ds; ds="$(dropin_sha)"
  if [[ -n $ds && $ds != "$FIXED_SHA" ]]; then
    fail "an unrecognised drop-in already exists at ${DROPIN} (observed ${ds}; expected ${FIXED_SHA}). Nothing was changed. Something else is managing this timer -- report it rather than deleting it."
  fi

  # --- Back up BEFORE touching anything --------------------------------------
  mkdir -p "$BACKUP_DIR"
  timer_enabled_state > "$BACKUP_ENABLED_STATE"
  if [[ -f $DROPIN ]]; then
    printf 'yes\n' > "$BACKUP_DROPIN_EXISTED"
    cp -p "$DROPIN" "${BACKUP_DIR}/hourly.conf.prior"
  else
    printf 'no\n' > "$BACKUP_DROPIN_EXISTED"
  fi
  log "Backed up prior state to ${BACKUP_DIR}"

  # From here on a failure auto-restores. Cleared on success below.
  trap 'restore_from_backup' ERR

  # --- Install ---------------------------------------------------------------
  write_dropin
  log "Installed ${DROPIN} (sha ${FIXED_SHA})"

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "/etc/systemd/system/${TIMER}" \
      || fail "systemd-analyze verify failed for ${TIMER}. Auto-restoring."
    log "systemd-analyze verify: OK"
  else
    log "WARNING: systemd-analyze not present -- skipping unit verification."
  fi

  # daemon-reload is REQUIRED (a new drop-in is invisible otherwise) and restarts
  # NOTHING. It does not signal mqtt-client. See the header.
  systemctl daemon-reload
  systemctl enable --now "$TIMER"
  log "Enabled ${TIMER}"

  assert_single_calendar_entry \
    || fail "${TIMER} does not have exactly one hourly OnCalendar entry -- the reset line did not take. Auto-restoring."
  log "TimersCalendar assertion: OK (exactly one hourly entry)"

  trap - ERR

  log "State after:"
  report_state
  log "Next elapse:"
  systemctl list-timers --all "$TIMER" --no-pager || true

  local pid_after; pid_after="$(mqtt_main_pid)"
  log "mqtt-client MainPID after : ${pid_after}"
  if [[ $pid_before != "$pid_after" ]]; then
    log "WARNING: mqtt-client MainPID CHANGED (${pid_before} -> ${pid_after})."
    log "This patch restarts nothing, so it did not cause that -- but investigate before trusting this apply."
  else
    log "mqtt-client MainPID unchanged -- no restart occurred (BUG-041 V6)."
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Nothing was restarted."
  log "Prior state backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
}

do_rollback() {
  require_root
  assert_not_template
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  start_logging rollback
  log "State before rollback:"
  report_state

  local pid_before; pid_before="$(mqtt_main_pid)"

  if [[ -r $BACKUP_DROPIN_EXISTED ]] && [[ "$(cat "$BACKUP_DROPIN_EXISTED")" == "yes" ]]; then
    cp -p "${BACKUP_DIR}/hourly.conf.prior" "$DROPIN"
    log "Restored the pre-existing ${DROPIN}"
  else
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    log "Removed ${DROPIN}"
  fi

  local prior="enabled"
  [[ -r $BACKUP_ENABLED_STATE ]] && prior="$(cat "$BACKUP_ENABLED_STATE")"
  systemctl daemon-reload
  if [[ $prior == "enabled" ]]; then
    systemctl enable "$TIMER" >/dev/null 2>&1 || true
  else
    systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
  fi
  log "Restored ${TIMER} to its prior state: ${prior}"

  rm -f "$MARKER_FILE"
  log "State after rollback:"
  report_state

  local pid_after; pid_after="$(mqtt_main_pid)"
  if [[ $pid_before == "$pid_after" ]]; then
    log "mqtt-client MainPID unchanged -- no restart occurred."
  else
    log "WARNING: mqtt-client MainPID CHANGED (${pid_before} -> ${pid_after})."
  fi
  log "Rollback complete. Nothing was restarted."
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
  apply       (default) apply the patch
  --check     DRY RUN, no root needed, changes nothing
              exit 0 = already patched, 1 = would refuse, 2 = would apply
  --rollback  restore the pre-patch state from backup

THIS PATCH RESTARTS NOTHING. It enables ${TIMER} and installs an hourly
drop-in; \`systemctl daemon-reload\` re-reads unit files and bounces no service.
It is safe on a live, printing device and cannot drop the ngrok SSH tunnel, so
there is no detached mode -- there is nothing to detach from. --inline/--detach
are accepted for interface parity with the other patches and affect only how
--check reports the session context.

Log: $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
