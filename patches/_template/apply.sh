#!/bin/bash
# =============================================================================
#  TEMPLATE -- NOT A PATCH. DO NOT scp THIS DIRECTORY TO A DEVICE.
# =============================================================================
#  Starting point for a new field patch. Copy the directory, rename it to the
#  patch date + slug, then fill in the marked sections.
#
#      cp -r patches/_template patches/YYYY-MM-DD-short-slug
#
#  The directory name becomes PATCH_ID and therefore the on-device state path
#  /usr/local/lib/eatabit/patches/<PATCH_ID>/ -- see ../README.md -> Adding a patch.
#
#  Everything above the "PATCH-SPECIFIC" divider is machinery that every patch
#  needs and that has been got wrong before. Copy it verbatim. In particular do
#  NOT "tidy" the sshd* glob in is_remote_session() -- see the note there.
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="YYYY-MM-DD-short-slug"          # MUST equal this directory's name
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
FIXED_SHA=""                              # desired end state
ACCEPTED_PRIOR_SHAS=()                    # states we are willing to upgrade FROM
KNOWN_VERSIONS=()                         # informational only

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

do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed."
  log "Deployed sha: $(file_sha /path/to/target)"
  if is_remote_session; then log "Detection: REMOTE -- a real run would DETACH."
  else                       log "Detection: LOCAL -- a real run would go INLINE."; fi
}

do_apply() {
  require_root
  assert_not_template
  local v; v="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  log "Detected device version: $v"

  # TODO gate on the deployed sha; refuse unrecognised states and PRINT the sha.
  # TODO back up originals into $BACKUP_DIR before touching anything.
  # TODO install the fixed files.

  run_detached_if_ssh __finalize_apply "$v"
}

do_rollback() {
  require_root
  assert_not_template
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  # TODO restore originals from $BACKUP_DIR.
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
