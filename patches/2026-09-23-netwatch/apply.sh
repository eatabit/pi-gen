#!/bin/bash
# =============================================================================
#  2026-09-23-netwatch -- BUG-094: iot-pi never recovers from a network outage
# =============================================================================
#  Installs netwatch, a network-recovery watchdog independent of mqtt-client, and
#  the three changes it needs in existing files:
#
#    NEW       /usr/local/lib/eatabit/bin/netwatch.js
#    NEW       /etc/systemd/system/netwatch.service, netwatch.timer
#    NEW       /etc/logrotate.d/eatabit-netwatch
#    NEW       /usr/local/lib/eatabit/state/            (card-backed state dir)
#    REPLACED  /usr/local/lib/eatabit/bin/mqtt-client.js   status file, print flag,
#              receipt suppression, reconnect-summary publish
#    REPLACED  /usr/local/lib/eatabit/bin/boot-print.sh    receipt suppression
#    REPLACED  /usr/local/lib/eatabit/bin/health-monitor.js  bssid + live RSSI
#
#  Lineage: mqtt-client, AFTER 2026-08-23-app-permissions-and-shadow-churn. Its only
#  accepted mqtt-client.js prior is that patch's end state 7ecbf0ea... -- which is
#  also what v1.0.11 / v1.1.5 ship. See ../README.md -> Lineages.
#
#  RESTARTS mqtt-client.service -- over SSH the restart+verify runs DETACHED.
#
#      sudo ./apply.sh --check      # dry run, no root, changes nothing
#      sudo ./apply.sh              # apply
#      sudo ./apply.sh --rollback   # restore the backed-up files, remove netwatch
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-09-23-netwatch"            # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
SERVICE="mqtt-client.service"             # the unit this patch restarts, if any
VERSION_FILE="/usr/local/lib/eatabit/version"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Gates: see PATCH-SPECIFIC below ------------------------------------------

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

# --- Safety: this file is a TEMPLATE, not a patch -----------------------------
# Without this guard, `sudo ./apply.sh` on an unedited template would sail past the
# unwritten TODOs and reach run_detached_if_ssh -> __finalize_apply, which RESTARTS
# mqtt-client.service on a live device: no gates checked, nothing installed, service
# bounced for nothing. The leading underscore and the header are conventions; this is
# the part that actually enforces it. Setting PATCH_ID to your real directory name is
# what disarms it -- which is step one of using the template anyway.
PLACEHOLDER_PATCH_ID="YYYY-MM-DD-short-slug"
assert_not_template() {
  [[ $PATCH_ID != "$PLACEHOLDER_PATCH_ID" ]] || fail \
    "this is patches/_template -- a skeleton, not a patch. Copy it, then set PATCH_ID to the new directory name. See ./README.md"
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
    # Re-exec via `bash "$SELF"` rather than executing $SELF directly: if this patch
    # directory were delivered by any route that drops the executable bit (a zip, tar
    # without -p, copy-paste into a new file), a direct exec fails with "Permission
    # denied" INSIDE the detached child -- while the foreground has already logged
    # "running DETACHED" and exited 0. The operator sees success and nothing ran.
    # scp -r preserves the bit and these files are 100755 in git, so this is belt and
    # braces, not a live defect (BUG-047, 2026-08-22).
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
#  PATCH-SPECIFIC -- everything below is yours to write.
# =============================================================================

# --- Targets -------------------------------------------------------------------
# Each target: <name>|<installed path>|<mode>|<fixed sha>|<accepted prior sha, or
# "absent" for a new file>. The payload is ${SCRIPT_DIR}/<name>.
#
# Every REPLACED file has exactly one accepted prior, and each was checked:
#   mqtt-client.js    7ecbf0ea...  end state of 2026-08-23-app-permissions-and-shadow-churn
#                                  == image source at v1.0.11 / v1.1.5
#   boot-print.sh     2998dd94...  byte-identical in all 17 release tags v1.0.1-v1.1.5
#   health-monitor.js e251ba26...  byte-identical in all 17 release tags v1.0.1-v1.1.5
TARGETS=(
  "mqtt-client.js|/usr/local/lib/eatabit/bin/mqtt-client.js|0755|fff9838f188034bf53db970858451efacd7ebd59058c1687e815354600cc01b8|7ecbf0ead594437934e3d0e501689a3bf99a1df77acdefb4369b57fc5655a34a"
  "boot-print.sh|/usr/local/lib/eatabit/bin/boot-print.sh|0755|b4ced89e1ff01b69bef09817cb5565b928fea1ecab366257eb59f8f03aaab025|2998dd94358a614fedc717a917af37bc5ff5ea22b4deac17d0b8d0bd4f6606d1"
  "health-monitor.js|/usr/local/lib/eatabit/bin/health-monitor.js|0755|5285fb5cd65ba85ed48bdb9aa417d197cf9d7f8d0eba5d5449aa6172f7a23ba3|e251ba26eca9a3934cadfe4484f5fef9b3d137320b8390602b79f21d33308192"
  "netwatch.js|/usr/local/lib/eatabit/bin/netwatch.js|0755|43638740a76b4619f9db85e398527da7cf9bb01d3314a467ef0b986f2c1f6424|absent"
  "netwatch.service|/etc/systemd/system/netwatch.service|0644|0a41893f2709a06cfb2fae416739f33f3ea63f162d5fba26cb63e9584b41aee8|absent"
  "netwatch.timer|/etc/systemd/system/netwatch.timer|0644|fa651de76737a8306eeef2bb1392d32092a1eb3bd7ee68a01869f6d505f59182|absent"
  "eatabit-netwatch|/etc/logrotate.d/eatabit-netwatch|0644|df9db55848d81fafb94a69152a5307e6e311a9155d1edff6bdfae49a976ab4b8|absent"
)
STATE_DIR="/usr/local/lib/eatabit/state"
TIMER="netwatch.timer"

start_logging() {
  mkdir -p "$PATCH_STATE_DIR"
  exec > >(tee -a "$LOG") 2>&1
  log "---- $(date -Iseconds) :: $PATCH_ID :: $* ----"
}

# Classify one target: fixed | upgrade | install | refuse
target_state() {
  local path=$1 fixed=$2 prior=$3 sha
  if [[ ! -e $path ]]; then
    [[ $prior == absent ]] && { printf install; return; }
    printf refuse; return
  fi
  sha="$(file_sha "$path")"
  if [[ $sha == "$fixed" ]]; then printf fixed
  elif [[ $prior != absent && $sha == "$prior" ]]; then printf upgrade
  else printf refuse
  fi
}

# Walk every target, print its state, and set OVERALL to fixed | apply | refuse.
OVERALL=""
survey() {
  local t name path mode fixed prior st sha
  OVERALL=fixed
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r name path mode fixed prior <<<"$t"
    st="$(target_state "$path" "$fixed" "$prior")"
    sha="$( [[ -e $path ]] && file_sha "$path" || printf '<absent>')"
    printf '  %-18s %-8s %s\n' "$name" "[$st]" "$sha"
    case $st in
      refuse) OVERALL=refuse
              printf '  %-18s          want %s or %s\n' "" "${fixed:0:16}..." \
                "$( [[ $prior == absent ]] && printf 'absent' || printf '%s...' "${prior:0:16}")" ;;
      upgrade|install) if [[ $OVERALL == fixed ]]; then OVERALL=apply; fi ;;
    esac
  done
}

explain_refusal() {
  log ""
  log "WHY THIS REFUSED: a target above is in a state this patch does not recognise."
  log "  mqtt-client.js must be at 7ecbf0ea... -- the end state of"
  log "  2026-08-23-app-permissions-and-shadow-churn, and what v1.0.11 / v1.1.5 ship."
  log "  A device behind that point must first climb the mqtt-client lineage:"
  log "    2026-08-20-ngrok-session-reclaim -> 2026-08-19-mqtt-keepalive-tolerance ->"
  log "    2026-08-23-app-permissions-and-shadow-churn -> this patch."
  log "  The lineage entry point accepts only stock v1.0.8-v1.0.10 / v1.1.2-v1.1.4, so a"
  log "  device on v1.0.1-v1.0.7, v1.1.0 or v1.1.1 cannot take this patch; it needs a"
  log "  reflash. See patches/README.md -> Lineages."
  log "  If the observed sha matches none of the above, report it rather than forcing."
}

do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed. (No root required.)"
  log "Device version: $(cat "$VERSION_FILE" 2>/dev/null || echo unknown) (informational)"
  survey
  case $OVERALL in
    fixed)
      if [[ -f $MARKER_FILE ]]; then log "RESULT: already patched -- a real run would NO-OP. (exit 0)"; exit 0; fi
      log "RESULT: files are in place but the apply never completed (no marker);"
      log "        a real run would enable ${TIMER} and restart ${SERVICE}. (exit 2)"
      exit 2 ;;
    refuse)
      log "RESULT: would REFUSE. (exit 1)"
      explain_refusal
      exit 1 ;;
  esac
  if is_remote_session; then log "Detection: REMOTE -- a real run would DETACH (restarting ${SERVICE} closes this session)."
  else                       log "Detection: LOCAL -- a real run would go INLINE."; fi
  log "NOTE: a real run RESTARTS ${SERVICE}, which DROPS IN-FLIGHT PRINT JOBS (BUG-049)."
  log "RESULT: would APPLY. (exit 2)"
  exit 2
}

__finalize_apply() {
  local v=$1
  assert_not_template
  systemctl daemon-reload
  log "Enabling ${TIMER}..."
  systemctl enable --now "$TIMER" || fail "could not enable ${TIMER}. Rollback with: sudo $SELF --rollback"
  log "Restarting ${SERVICE}..."
  systemctl restart "$SERVICE"
  sleep 3
  local state timer_state
  state="$(systemctl is-active "$SERVICE" || true)"
  timer_state="$(systemctl is-active "$TIMER" || true)"
  if [[ $state != active ]]; then
    log "WARNING: ${SERVICE} is '${state}'. Recent journal:"
    journalctl -u "$SERVICE" -n 25 --no-pager || true
    fail "${SERVICE} did not return to active. Rollback with: sudo $SELF --rollback"
  fi
  [[ $timer_state == active ]] || fail "${TIMER} is '${timer_state}'. Rollback with: sudo $SELF --rollback"
  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. ${SERVICE}=${state} ${TIMER}=${timer_state}"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
  log ""
  log "netwatch's first run is ~1 min after this (2 min after a boot). Then check:"
  log "  tail -n 3 /usr/local/lib/eatabit/log/netwatch.log   # expect a 'startup' entry"
  log "  cat /run/eatabit/mqtt-status.json                    # expect connected:true"
}

__finalize_rollback() {
  assert_not_template
  systemctl daemon-reload
  log "Restarting ${SERVICE}..."
  systemctl restart "$SERVICE" || true
  rm -f "$MARKER_FILE"
  log "Rollback complete. ${SERVICE}=$(systemctl is-active "$SERVICE" || true)"
}

do_apply() {
  require_root
  assert_not_template
  start_logging apply
  local v; v="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  log "Detected device version: $v (informational; the shas are the gate)"
  log "State before:"
  survey

  if [[ $OVERALL == fixed && -f $MARKER_FILE ]]; then
    log "Already patched. Nothing to do."
    exit 0
  fi
  if [[ $OVERALL == refuse ]]; then
    explain_refusal
    fail "unrecognised target state. Nothing was changed."
  fi

  local t name path mode fixed prior st
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r name path mode fixed prior <<<"$t"
    [[ -r ${SCRIPT_DIR}/${name} ]] || fail "payload ${SCRIPT_DIR}/${name} is missing. Nothing was changed."
    [[ "$(file_sha "${SCRIPT_DIR}/${name}")" == "$fixed" ]] \
      || fail "payload ${name} does not match its expected sha -- corrupt copy? Nothing was changed."
  done

  # --- Back up BEFORE touching anything --------------------------------------
  mkdir -p "$BACKUP_DIR"
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r name path mode fixed prior <<<"$t"
    if [[ -e $path && ! -e ${BACKUP_DIR}/${name} && $(file_sha "$path") != "$fixed" ]]; then
      cp -p "$path" "${BACKUP_DIR}/${name}"
      log "Backed up ${path}"
    fi
  done

  # --- Install ---------------------------------------------------------------
  mkdir -p "$STATE_DIR"; chmod 0755 "$STATE_DIR"
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r name path mode fixed prior <<<"$t"
    st="$(target_state "$path" "$fixed" "$prior")"
    [[ $st == fixed ]] && continue
    install -D -m "$mode" -o root -g root "${SCRIPT_DIR}/${name}" "$path" \
      || fail "failed to install ${path}. Roll back with: sudo $SELF --rollback"
    log "  installed ${path}"
  done

  # --- Verify bytes BEFORE restarting ----------------------------------------
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r name path mode fixed prior <<<"$t"
    [[ "$(file_sha "$path")" == "$fixed" ]] || fail \
      "post-install sha mismatch on ${path}. Nothing was restarted. Roll back with: sudo $SELF --rollback"
  done
  log "Byte-level verification passed."

  run_detached_if_ssh __finalize_apply "$v"
}

do_rollback() {
  require_root
  assert_not_template
  start_logging rollback
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"

  systemctl disable --now "$TIMER" 2>/dev/null || true
  local t name path mode fixed prior
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r name path mode fixed prior <<<"$t"
    if [[ $prior == absent ]]; then
      rm -f "$path" && log "  removed ${path}"
    elif [[ -r ${BACKUP_DIR}/${name} ]]; then
      install -m "$mode" -o root -g root "${BACKUP_DIR}/${name}" "$path" && log "  restored ${path}"
    else
      log "  WARNING: no backup of ${name} -- left as it is."
    fi
  done
  # A leftover marker would mean nothing to the restored boot-print.sh, but remove it
  # so a later re-apply cannot inherit it. netwatch.log and the state dir are kept as
  # evidence.
  rm -f "${STATE_DIR}/netwatch-reboot"
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
  --rollback  restore the pre-patch files from backup and remove netwatch
  --inline    force the restart+verify to run in the foreground
  --detach    force the restart+verify to run detached

Restarting $SERVICE drops the ngrok SSH tunnel (ngrok runs inside it), so over
SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
