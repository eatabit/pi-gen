#!/bin/bash
# =============================================================================
#  2026-08-24-mqtt-never-connected-watchdog -- BUG-057
# =============================================================================
#  Arms the Layer 1 connection watchdog for a process that has NEVER connected
#  (bounded at 3 restarts), and rebuilds the ClientBootstrap -- which owns the CRT
#  host resolver -- on every initial-connect attempt.
#
#  *** DO NOT INSTALL ON ANY FIELD DEVICE. BENCH ONLY. ***
#  Field rollout is a separate, later, explicitly authorized decision. See README.md.
#
#  Built from patches/_template. Everything above the "PATCH-SPECIFIC" divider is
#  the template's machinery, copied VERBATIM -- in particular the sshd* glob in
#  is_remote_session(), which must not be "tidied" (BUG-047).
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-24-mqtt-never-connected-watchdog"   # MUST equal this directory's name
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

# --- Gates -------------------------------------------------------------------
# Checksums are the authoritative gate; version lists are informational. Refusing
# on an unrecognised sha, and PRINTING the observed sha, is what makes a patch safe
# to hand to an operator who cannot inspect the device first.
MQTT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
PAYLOAD="${SCRIPT_DIR}/mqtt-client.js"

FIXED_SHA="cade85490c64b651f5b505263dba744428fbdf17b9d47f333eaf431208b19d03"

# EXACTLY ONE accepted prior: the head of the mqtt-client lineage,
# 2026-08-23-app-permissions-and-shadow-churn (ISSUE-068), whose FIXED_MQTT_SHA this
# is, and which is also image source on hw/1.0 and hw/1.1.
#
# DO NOT WIDEN THIS GATE. Precedent and reasoning: BUG-045's patch carries a single
# accepted prior for the same reason -- see iot-doc BUG-045 -> "Do not widen this
# gate". Bringing a device UP the lineage is the operator's own step, run in order;
# this patch is the last link in a known chain, not a reconstructor of arbitrary
# device states. Widening it would also make this a rollup: the payload is built on
# top of ISSUE-068's file, so applying it to a pre-ISSUE-068 device (b009b68c...)
# would silently deliver ISSUE-068's changes too. Refusal is the correct outcome.
ACCEPTED_PRIOR_SHAS=(
  "7ecbf0ead594437934e3d0e501689a3bf99a1df77acdefb4369b57fc5655a34a"  # 2026-08-23-app-permissions-and-shadow-churn end state == image source
)

# Informational only -- the checksum is the authoritative gate. v1.1.0 IS a real
# released tag (3772bd8 / commit 5146b0c); earlier patch READMEs that treat it as a
# phantom are wrong, so it is listed here deliberately.
KNOWN_VERSIONS=(1.0.8 1.0.9 1.0.10 1.1.0 1.1.1 1.1.2 1.1.3 1.1.4)

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

# Not provided by the template -- defined here rather than copied from a neighbouring
# patch (BUG-047 was the copy-a-neighbour defect four times over).
in_list() {
  local needle=$1; shift
  local x
  for x in "$@"; do [[ $x == "$needle" ]] && return 0; done
  return 1
}

# The finalize steps are re-exec targets: they run in a SEPARATE process, detached,
# when the patch is applied over SSH. They therefore take everything they need as
# ARGUMENTS -- they cannot see locals from do_apply/do_rollback.
__finalize_apply() {
  local v=$1
  assert_not_template
  log "Restarting $SERVICE..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  sleep 3
  local state; state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    fail "$SERVICE did not return to active. Rollback with: sudo $SELF --rollback"
  fi
  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Service: $state"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
}

__finalize_rollback() {
  assert_not_template
  log "Restarting $SERVICE..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  rm -f "$MARKER_FILE"
  log "Rollback complete. Service is: $(systemctl is-active "$SERVICE")"
}

# Exit codes are the contract in ../README.md:
#   0 = already patched   1 = would refuse   2 = would apply
do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed."
  local v; v="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  local m; m="$(file_sha "$MQTT_JS" || true)"
  log "Device version: $v"
  log "Deployed sha:   ${m:-<unreadable>}"
  if is_remote_session; then log "Detection: REMOTE -- a real run would DETACH."
  else                       log "Detection: LOCAL -- a real run would go INLINE."; fi

  if [[ $m == "$FIXED_SHA" ]]; then
    log "RESULT: already patched. Nothing to do."
    exit 0
  fi
  if in_list "$m" "${ACCEPTED_PRIOR_SHAS[@]}"; then
    log "RESULT: would apply -> $FIXED_SHA"
    exit 2
  fi
  log "RESULT: would REFUSE -- unrecognised state."
  log "  observed: ${m:-<unreadable>}"
  log "  accepted: ${ACCEPTED_PRIOR_SHAS[0]}"
  log "  Bring the device up the lineage first; see ../README.md -> Lineages."
  exit 1
}

do_apply() {
  require_root
  assert_not_template
  local v; v="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  log "Detected device version: $v"

  [[ -f $PAYLOAD ]] || fail "payload missing: $PAYLOAD"
  local ps; ps="$(file_sha "$PAYLOAD" || true)"
  [[ $ps == "$FIXED_SHA" ]] || fail \
    "bundled payload sha $ps != FIXED_SHA $FIXED_SHA -- this patch directory is corrupt; do not install it"

  local m; m="$(file_sha "$MQTT_JS" || true)"
  if [[ $m == "$FIXED_SHA" ]]; then
    log "Already at the fixed state ($FIXED_SHA). Nothing to do."
    exit 0
  fi
  # Refuse, and PRINT the observed sha -- an operator who cannot inspect the device
  # first needs to see what it actually has.
  if ! in_list "$m" "${ACCEPTED_PRIOR_SHAS[@]}"; then
    log "REFUSING: ${MQTT_JS} is in an unrecognised state."
    log "  observed: ${m:-<unreadable>}"
    log "  accepted: ${ACCEPTED_PRIOR_SHAS[0]}"
    fail "unrecognised prior state -- nothing was changed. Bring the device up the lineage first."
  fi

  mkdir -p "$BACKUP_DIR"
  if [[ ! -f ${BACKUP_DIR}/mqtt-client.js ]]; then
    cp -p "$MQTT_JS" "${BACKUP_DIR}/mqtt-client.js" \
      || fail "failed to back up ${MQTT_JS} -- nothing was changed"
    log "Backed up ${MQTT_JS} (sha $m) to ${BACKUP_DIR}/"
  else
    log "Backup already present at ${BACKUP_DIR}/mqtt-client.js -- keeping the original."
  fi

  install -m 0644 -o root -g root "$PAYLOAD" "$MQTT_JS" \
    || fail "failed to install ${MQTT_JS}. Roll back with: sudo $SELF --rollback"
  local post; post="$(file_sha "$MQTT_JS")"
  [[ $post == "$FIXED_SHA" ]] || fail \
    "post-install sha mismatch on ${MQTT_JS} (got $post, want $FIXED_SHA). Nothing was restarted. Roll back with: sudo $SELF --rollback"
  log "Installed ${MQTT_JS} -> $FIXED_SHA"

  run_detached_if_ssh __finalize_apply "$v"
}

do_rollback() {
  require_root
  assert_not_template
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  [[ -f ${BACKUP_DIR}/mqtt-client.js ]] || fail "no backup of mqtt-client.js in $BACKUP_DIR"
  install -m 0644 -o root -g root "${BACKUP_DIR}/mqtt-client.js" "$MQTT_JS" \
    || fail "failed to restore ${MQTT_JS} from backup"
  log "Restored ${MQTT_JS} -> $(file_sha "$MQTT_JS")"
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

Restarting $SERVICE drops the ngrok SSH tunnel (ngrok runs inside it), so over
SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
