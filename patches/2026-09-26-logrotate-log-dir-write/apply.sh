#!/bin/bash
# =============================================================================
#  2026-09-26-logrotate-log-dir-write  (BUG-097)
# =============================================================================
#  Lets the stock logrotate.service write /usr/local/lib/eatabit/log.
#
#  Debian's stock /usr/lib/systemd/system/logrotate.service ships
#  ProtectSystem=full, which mounts /usr READ-ONLY inside that unit's own mount
#  namespace. The eatabit logs live under /usr (/usr/local/lib/eatabit/log), so
#  every rename and create logrotate attempts there fails with EROFS -- on every
#  device, every night, since the 2026-08-23 rotation configs were installed. The
#  filesystem itself is fine: a root shell writes there without complaint, which is
#  why a manual `logrotate -f` from a shell "works" and proves nothing.
#
#  The failure is worse than the disk it costs:
#    - logrotate exits 1, which fails the WHOLE run: nothing on the device rotates;
#    - it still advances its state file, so the failure is silent until tomorrow;
#    - the error names .7.gz/.8.gz files that never existed, because rename()
#      checks for a read-only mount before it resolves the source (EROFS, not
#      ENOENT), so the log reads like a different bug.
#
#  The fix is one systemd drop-in naming the DIRECTORY:
#      /etc/systemd/system/logrotate.service.d/eatabit.conf
#      [Service]
#      ReadWritePaths=-/usr/local/lib/eatabit/log
#  That covers every stanza pointing into the directory -- eatabit-mqtt-client,
#  eatabit-ble-config and eatabit-netwatch -- without touching any of them. The
#  leading '-' makes a missing directory a no-op rather than a unit failure. It is
#  the same mechanism mqtt-client.service already uses to write this directory
#  under the STRICTER ProtectSystem=strict. ProtectSystem=full itself is left in
#  place: the rest of /usr stays read-only to logrotate.
#
#  Verified before this patch was written (BUG-097 planning.md -> Evidence):
#  sandbox must-hit/must-miss on both hardware lines, and the real scheduled
#  logrotate.service run on bench ce4c5d90 (hw/1.0) with this exact drop-in:
#  Result=success, a rotated ble-config.log.1, mqtt-client.log's pending .1 gzipped.
#
#  Built from patches/_template (BUG-047). Two deliberate deviations from it, the
#  same two 2026-08-19-log2ram-timer-hourly-sync and 2026-08-19-gateway-timezone-utc
#  make and for the same reason:
#
#  1. NO SERVICE RESTART. The template's __finalize_* restart mqtt-client.service;
#     that is REMOVED here, not merely left unreached. THIS PATCH RESTARTS NOTHING
#     and is safe on a live, printing device with no maintenance window.
#     `systemctl daemon-reload` IS kept and IS required -- a new drop-in is
#     invisible to systemd otherwise -- but it only re-reads unit files. logrotate
#     is a timer-driven oneshot, so the next scheduled run simply picks the drop-in
#     up. mqtt-client's MainPID is captured before and after as evidence.
#
#  2. NO DETACH. run_detached_if_ssh() exists to survive a restart killing the ngrok
#     tunnel the operator is patching over. Nothing restarts, so it is absent by
#     design. is_remote_session() IS kept, verbatim from the template including the
#     sshd* glob, so --check can report the session context and so a future revision
#     that does need a restart starts from correct detection. If you add a restart,
#     restore run_detached_if_ssh from patches/_template/apply.sh.
#
#  NEVER verify this patch by running `logrotate -f` from a shell: that runs outside
#  the sandbox, where the bug does not exist. And an exit 0 from logrotate.service is
#  not proof either -- it is also what a run with nothing due looks like. The proof
#  is the NEXT nightly run rotating a file. See BUG-097 planning.md -> Test plan.
#
#  Lineage: logrotate-unit. Target file /etc/systemd/system/logrotate.service.d/
#  eatabit.conf. NO OTHER PATCH IN THIS TREE TOUCHES IT, so this is a new,
#  independent lineage sharing no checksum with any other. It may be applied at any
#  point in a campaign. It complements 2026-08-23-log-permissions-and-rotation
#  (which installs the stanzas this makes runnable) but does not require it.
#
#  Gate: this patch REPLACES no file, so there is no replaced-file payload sha. The
#  deployed STATE is the gate: the sha of the drop-in (absent / ours / unrecognised)
#  and whether logrotate.service is loaded. Same principle as the sha gates
#  elsewhere -- refuse an unrecognised state, PRINT what was observed.
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-09-26-logrotate-log-dir-write"   # MUST equal this directory's name
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
UNIT="logrotate.service"
LOG_DIR="/usr/local/lib/eatabit/log"
DROPIN_DIR="/etc/systemd/system/logrotate.service.d"
DROPIN="${DROPIN_DIR}/eatabit.conf"

BACKUP_DROPIN_EXISTED="${BACKUP_DIR}/eatabit.conf.existed"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Gates -------------------------------------------------------------------
# FIXED_SHA is the sha256 of the drop-in this patch installs, byte-identical to the
# copy the image installs from stage3/05-install-log2ram/00-run.sh. It is ALSO
# asserted against the bytes actually written (see write_dropin), so this constant
# and the heredoc below cannot drift apart silently.
FIXED_SHA="8ec46a1e939f0e82caa970fb7547572df9fa466453187b94eec602f8d6bc0313"

KNOWN_VERSIONS=("1.0.1" "1.0.2" "1.0.3" "1.0.4" "1.0.5" "1.0.6" "1.0.7" \
                "1.0.8" "1.0.9" "1.0.10" "1.0.11" \
                "1.1.0" "1.1.1" "1.1.2" "1.1.3" "1.1.4" "1.1.5")   # informational only

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
# PID is captured before and after and reported as evidence.
mqtt_main_pid() { systemctl show -p MainPID --value mqtt-client.service 2>/dev/null || printf 'unknown'; }

# =============================================================================
#  PATCH-SPECIFIC
# =============================================================================

# Everything an apply/rollback prints also lands in $LOG, so a device keeps its own
# record. The template got this from the detached redirect; this patch does not
# detach, so it is done explicitly. --check never calls this: it is read-only and
# must work without root.
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

unit_prop()      { systemctl show "$UNIT" -p "$1" --value 2>/dev/null || printf ''; }
dropin_sha()     { [[ -f $DROPIN ]] && file_sha "$DROPIN" || printf ''; }
# True when the LOADED unit (not just the file on disk) grants the log dir. A drop-in
# written without a daemon-reload is on disk but not in effect.
grant_loaded()   { unit_prop ReadWritePaths | tr ' ' '\n' | grep -qxE -- "-?${LOG_DIR}"; }

report_state() {
  log "  ${UNIT} LoadState      : $(unit_prop LoadState)"
  log "  ${UNIT} ProtectSystem  : $(unit_prop ProtectSystem)"
  local rw; rw="$(unit_prop ReadWritePaths)"
  log "  ${UNIT} ReadWritePaths : ${rw:-<empty>}"
  local dp; dp="$(unit_prop DropInPaths)"
  log "  ${UNIT} DropInPaths    : ${dp:-<none>}"
  local d; d="$(dropin_sha)"
  log "  eatabit.conf sha            : ${d:-<absent>}"
  if [[ -d $LOG_DIR ]]; then log "  ${LOG_DIR} : present"
  else                       log "  ${LOG_DIR} : ABSENT (the '-' prefix makes that harmless)"; fi
}

# Fixed only when BOTH hold: our exact bytes on disk AND the loaded unit carries the
# grant. The right file without a daemon-reload is NOT fixed -- tonight's run would
# still fail.
is_fixed() {
  [[ "$(dropin_sha)" == "$FIXED_SHA" ]] && grant_loaded
}

# Write the drop-in, then PROVE the bytes match FIXED_SHA. The content is exactly the
# image copy's -- no comments -- so a reflashed device and a patched one are
# byte-identical and this patch no-ops on the former.
write_dropin() {
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN" <<'DROPIN_CONF'
[Service]
ReadWritePaths=-/usr/local/lib/eatabit/log
DROPIN_CONF
  chmod 0644 "$DROPIN"
  local got; got="$(file_sha "$DROPIN")"
  [[ $got == "$FIXED_SHA" ]] || fail \
    "internal: wrote eatabit.conf with sha ${got}, expected ${FIXED_SHA}. The heredoc and FIXED_SHA have drifted -- fix the patch, not the device."
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
    log "RESULT: already patched -- drop-in present and loaded. A real run would NO-OP."
    exit 0
  fi

  if [[ "$(unit_prop LoadState)" != "loaded" ]]; then
    log "RESULT: would REFUSE -- ${UNIT} is not loaded (LoadState=$(unit_prop LoadState)). Is logrotate installed?"
    exit 1
  fi

  local ds; ds="$(dropin_sha)"
  if [[ -n $ds && $ds != "$FIXED_SHA" ]]; then
    log "RESULT: would REFUSE -- an unrecognised drop-in already exists at ${DROPIN}:"
    log "  observed: ${ds}"
    log "  expected: ${FIXED_SHA}"
    log "Something else is managing this unit. Report it; do not delete it blindly."
    exit 1
  fi

  if [[ $ds == "$FIXED_SHA" ]]; then
    log "RESULT: would APPLY -- drop-in is correct on disk but not loaded."
    log "A real run would CONVERGE this device with a daemon-reload."
  else
    log "RESULT: would APPLY -- install ${DROPIN} and daemon-reload."
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

  # Idempotency: a device already correct -- reflashed to an image carrying the
  # drop-in, or patched already -- must NO-OP, not be refused. No marker is written:
  # the patch changed nothing, and claiming otherwise would misreport the device.
  if is_fixed; then
    log "Already patched: drop-in present and loaded. Nothing to do."
    exit 0
  fi

  # --- Gates, before anything is touched -------------------------------------
  [[ "$(unit_prop LoadState)" == "loaded" ]] || fail \
    "${UNIT} is not loaded (LoadState=$(unit_prop LoadState)) -- is logrotate installed? Nothing was changed."

  local ds; ds="$(dropin_sha)"
  if [[ -n $ds && $ds != "$FIXED_SHA" ]]; then
    fail "an unrecognised drop-in already exists at ${DROPIN} (observed ${ds}; expected ${FIXED_SHA}). Nothing was changed. Something else is managing this unit -- report it rather than deleting it."
  fi

  # --- Back up BEFORE touching anything --------------------------------------
  # The only prior states the gates allow are "absent" and "already ours but not
  # loaded", so recording whether the file existed is a complete backup.
  mkdir -p "$BACKUP_DIR"
  if [[ -f $DROPIN ]]; then printf 'yes\n' > "$BACKUP_DROPIN_EXISTED"
  else                      printf 'no\n'  > "$BACKUP_DROPIN_EXISTED"; fi
  log "Backed up prior state to ${BACKUP_DIR}"

  # From here on a failure auto-restores. Cleared on success below.
  trap 'restore_from_backup' ERR

  # --- Install ---------------------------------------------------------------
  write_dropin
  log "Installed ${DROPIN} (sha ${FIXED_SHA})"

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$UNIT" \
      || fail "systemd-analyze verify failed for ${UNIT}. Auto-restoring."
    log "systemd-analyze verify: OK"
  else
    log "WARNING: systemd-analyze not present -- skipping unit verification."
  fi

  # daemon-reload is REQUIRED (a new drop-in is invisible otherwise) and restarts
  # NOTHING. See the header.
  systemctl daemon-reload

  # Must-hit: the loaded unit now grants the log dir.
  grant_loaded \
    || fail "${UNIT} does not list ${LOG_DIR} in ReadWritePaths after daemon-reload. Auto-restoring."
  log "ReadWritePaths assertion: OK (${UNIT} grants ${LOG_DIR})"

  trap - ERR

  log "State after:"
  report_state
  # Should-not-have-moved: hardening is untouched, only the log dir is opened.
  log "ProtectSystem is still '$(unit_prop ProtectSystem)' -- the rest of /usr stays read-only to logrotate."
  log "Next logrotate run:"
  systemctl list-timers --all logrotate.timer --no-pager || true

  local pid_after; pid_after="$(mqtt_main_pid)"
  log "mqtt-client MainPID after : ${pid_after}"
  if [[ $pid_before != "$pid_after" ]]; then
    log "WARNING: mqtt-client MainPID CHANGED (${pid_before} -> ${pid_after})."
    log "This patch restarts nothing, so it did not cause that -- but investigate before trusting this apply."
  else
    log "mqtt-client MainPID unchanged -- no restart occurred."
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Nothing was restarted."
  log "Verify with the NEXT scheduled logrotate run: it must ROTATE a file. Exit 0 alone is not proof."
  log "Do NOT verify with a shell 'logrotate -f' -- it runs outside the sandbox."
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
    log "${DROPIN} existed (with our bytes) before this patch -- leaving it in place."
  else
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    log "Removed ${DROPIN}"
  fi
  systemctl daemon-reload

  rm -f "$MARKER_FILE"
  log "State after rollback:"
  report_state

  local pid_after; pid_after="$(mqtt_main_pid)"
  if [[ $pid_before == "$pid_after" ]]; then
    log "mqtt-client MainPID unchanged -- no restart occurred."
  else
    log "WARNING: mqtt-client MainPID CHANGED (${pid_before} -> ${pid_after})."
  fi
  log "Rollback complete. Nothing was restarted. logrotate will fail with EROFS again from the next run."
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
  --rollback  remove the drop-in this patch installed

THIS PATCH RESTARTS NOTHING. It installs ${DROPIN}
and runs \`systemctl daemon-reload\`, which re-reads unit files and bounces no
service. It is safe on a live, printing device and cannot drop the ngrok SSH
tunnel, so there is no detached mode -- there is nothing to detach from.
--inline/--detach are accepted for interface parity with the other patches and
affect only how --check reports the session context.

Log: $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
