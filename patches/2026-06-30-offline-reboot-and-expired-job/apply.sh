#!/bin/bash
# Patch: 2026-06-30-offline-reboot-and-expired-job
# Combined mqtt-client.js rollup of two fixes (supersedes 2026-06-25-offline-reboot-loop):
#
#   1) Offline reboot loop — sends systemd READY=1 BEFORE connecting and treats
#      the initial connect as non-fatal (background retry), so a networkless device
#      stays up and waits instead of failing its start and tripping
#      StartLimitAction=reboot-force. See docs/bugfix/offline-reboot-loop.md
#   2) Expired-job stuck IN_PROGRESS — an expired job is terminated with a status
#      legal for its current execution state (FAILED when already IN_PROGRESS, else
#      REJECTED), and an expiry detected mid-download now FAILs instead of being
#      dropped — so a stuck execution can no longer block the job queue.
#      See iot-doc/issues/expired-job-stuck-in-progress-blocks-queue/
#
# These exact changes are also baked into the next image release on both lines
# (v1.0.10 on hw/1.0, v1.1.4 on hw/1.1); the bundled file is byte-identical to what
# those releases ship, so a device flashed to them lands on FIXED_SHA and this
# patch no-ops.
#
# Gating is by CHECKSUM, not version string: it replaces any recognized prior
# mqtt-client.js (stock v1.0.8+/v1.1.2+, or the superseded offline-reboot patch)
# and refuses anything else. Works regardless of the reported VERSION (a patched
# device keeps its old version string).
#
# NOTE: restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs
# inside that process). Over SSH this script runs the restart+verify DETACHED and
# logs to apply.log, so the dropped tunnel can't interrupt the verify/rollback.
#
# Usage:
#   sudo ./apply.sh             # apply patch
#   sudo ./apply.sh --rollback  # restore original mqtt-client.js from backup

set -euo pipefail

PATCH_ID="2026-06-30-offline-reboot-and-expired-job"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MQTT_CLIENT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
VERSION_FILE="/usr/local/lib/eatabit/version"
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
SERVICE="mqtt-client.service"
FORCE_INLINE=0
FORCE_DETACH=0

# sha256 of the deployed mqtt-client.js. FIXED_SHA is the desired end state (the
# combined rollup), identical to what v1.0.10 / v1.1.4 will ship. ACCEPTED_PRIOR_SHAS
# are the files we're willing to replace with it; backups preserve whatever was
# there first, keeping rollback correct.
FIXED_SHA="2f8848db0e8fba8a4ffdc10a517a8b154e181ac0a450d580cae9fca11b459866"
ACCEPTED_PRIOR_SHAS=(
  "e80b7a1749672b77e5d67c4e70a418ef30ebb946b9b20580ba4a346402790e20" # stock v1.0.8+/v1.1.2+
  "51a012aef50d802bfcec1ff40cf8d2b4d1ad3839f6c4a0be07d957b7d4d095f3" # superseded 2026-06-25-offline-reboot-loop patch
  "b30bc9c27f6654f309c3aeb3c9ada35f76a6ec978a50f4bc2ed541e7fedb137f" # superseded broken first cut of that patch
  "607f3d2888fbe9b01b5805da0f64f2267824ff5119e64236a94efd8981905bad" # previous combined rollup (pre connection-rebuild fix)
)

# --- SUPERSEDED: states this patch must NOT touch (ISSUE-065) -----------------
# A device whose mqtt-client.js is DOWNSTREAM of FIXED_SHA already carries this fix
# plus everything that landed after it. Such a sha is NOT a prior: ACCEPTED_PRIOR_SHAS
# means "install my payload over this", and this patch's payload IS 2f8848db -- so
# accepting a downstream sha would OVERWRITE newer code with older.
#
# Recorded in the fleet rollout log (iot-doc/ops/Pi-Rollout-Log.md) against device db996da7, where this very patch was
# declined by hand: "Applying it would have been a downgrade." That judgement now lives
# in the gate instead of relying on an operator to make it again.
SUPERSEDED_SHAS=(
  "d4647dab55ee858206446c9cc0be5c284ac40554f04a75252cc90abafcbc3376" # BUG-039 device-ready guard
  "323299afb4d62508be5543d3ecb6c7240f8e05dba7ad566f9eb0644017d026c0" # BUG-049 first cut -- superseded, but still downstream of us
  "1d49a43a401d782bf9d72f69f2c9346c21405a17685185bdbd50f03986d60121" # 2026-08-20-ngrok-session-reclaim
  "b009b68c8692314ed8476f3bbb3b1d479c3d97fca67240f7bcf96e44444ed339" # 2026-08-19-mqtt-keepalive-tolerance
  "4cafe4db9f942825c5ced68a83591a3ba9663140e6b7d0b5ca708cf866ba3c09" # ISSUE-068 logrotate/permissions
  "7ecbf0ead594437934e3d0e501689a3bf99a1df77acdefb4369b57fc5655a34a" # ISSUE-068 tmpfs snapshots == image source at v1.0.11 / v1.1.5
)

# Versions whose stock mqtt-client.js matches the stock prior sha (informational;
# the checksum is the authoritative gate, so patched / older units also match).
KNOWN_VERSIONS=("1.0.9" "1.1.3")

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "must be run as root (use: sudo $0)"
  fi
}

current_version() {
  [[ -f $VERSION_FILE ]] || fail "$VERSION_FILE not found — is this an eatabit Pi image?"
  tr -d '[:space:]' < "$VERSION_FILE"
}

file_sha() { sha256sum "$1" | awk '{print $1}'; }

node_check() {
  local node_bin
  node_bin="$(command -v node || true)"
  [[ -x $node_bin ]] || node_bin="/usr/bin/node"
  [[ -x $node_bin ]] || { log "WARNING: node not found, skipping syntax check"; return 0; }
  "$node_bin" --check "$1"
}

# Is this an SSH session? The obvious test -- $SSH_CONNECTION -- is NOT sufficient:
# sudo's env_reset strips SSH_CONNECTION/SSH_CLIENT/SSH_TTY, and the documented way to
# run this script is `sudo ./apply.sh`. Checking only the environment therefore reports
# "local console" over SSH, the restart runs inline, and it kills the ngrok tunnel it is
# running over -- the precise failure the detach exists to prevent. So fall back to
# walking the parent process chain for sshd, which survives sudo.
# Added 2026-08-22 by BUG-047, replacing the $SSH_CONNECTION-only guard this script
# shipped with. Kept byte-identical to the 2026-08-20 patches' copy on purpose.
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

# Run a finalize step (which restarts mqtt-client and thus drops an ngrok SSH
# tunnel). Over SSH, re-exec it detached via setsid so the session drop can't
# kill it mid-restart; results go to $LOG. On a local console, run inline.
run_detached_if_ssh() {
  local internal_cmd=$1; shift
  if is_remote_session; then
    mkdir -p "$PATCH_STATE_DIR"
    log "Over SSH: restarting $SERVICE will CLOSE this session (ngrok runs inside it)."
    log "Running '$internal_cmd' DETACHED so the tunnel drop can't interrupt it; logging to:"
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

# -----------------------------------------------------------------------------
# Finalize steps (restart + verify). Invoked inline or re-exec'd detached.
# -----------------------------------------------------------------------------
__finalize_apply() {
  require_root
  local v=$1
  mkdir -p "$PATCH_STATE_DIR"
  log "Restarting $SERVICE..."
  systemctl restart "$SERVICE"

  sleep 3
  local state
  state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    log "Restoring backup and restarting..."
    install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "$SERVICE did not return to active; original restored. Rollback (if needed): $0 --rollback"
  fi

  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Service: $state"
  log "Original backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $0 --rollback"
}

__finalize_rollback() {
  require_root
  systemctl restart "$SERVICE"
  rm -f "$MARKER_FILE"
  sleep 3
  log "Rollback complete. Service is: $(systemctl is-active "$SERVICE" || true)"
}

# -----------------------------------------------------------------------------
# Rollback
# -----------------------------------------------------------------------------
do_rollback() {
  require_root
  log "Rolling back patch ${PATCH_ID}..."

  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR — nothing to roll back"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] || fail "no backup of mqtt-client.js in $BACKUP_DIR"

  install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  log "Restored $MQTT_CLIENT_JS"

  run_detached_if_ssh __finalize_rollback
}

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------
do_apply() {
  require_root

  local v deployed_sha
  v="$(current_version)"
  log "Detected device version: $v"

  [[ -f $MQTT_CLIENT_JS ]] || fail "$MQTT_CLIENT_JS not found."

  deployed_sha="$(file_sha "$MQTT_CLIENT_JS")"

  # Idempotency: already carries the fix.
  if [[ $deployed_sha == "$FIXED_SHA" ]]; then
    log "mqtt-client.js already contains the fix. Nothing to do."
    mkdir -p "$PATCH_STATE_DIR"
    [[ -f $MARKER_FILE ]] || printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
    exit 0
  fi

  # ISSUE-065: superseded is checked BEFORE prior, and exits 0. The device is ahead of
  # this patch; applying the payload would downgrade it. Nothing to do, nothing wrong.
  local sup
  for sup in "${SUPERSEDED_SHAS[@]}"; do
    if [[ $deployed_sha == "$sup" ]]; then
      log "mqtt-client.js (sha $deployed_sha) is DOWNSTREAM of this patch."
      log "The device already carries this fix and later ones -- applying would DOWNGRADE it."
      log "Nothing to do."
      exit 0
    fi
  done

  # Safety: only replace a recognized prior file (stock, or the superseded build).
  local accepted=0 prior
  for prior in "${ACCEPTED_PRIOR_SHAS[@]}"; do [[ $deployed_sha == "$prior" ]] && accepted=1; done
  if (( ! accepted )); then
    fail "deployed mqtt-client.js (sha $deployed_sha) is not a recognized pre-fix file (known versions: ${KNOWN_VERSIONS[*]}). Refusing to overwrite an unrecognized file."
  fi

  local known=0 kv
  for kv in "${KNOWN_VERSIONS[@]}"; do [[ $v == "$kv" ]] && known=1; done
  (( known )) || log "NOTE: version $v not in ${KNOWN_VERSIONS[*]}, but its mqtt-client.js matches a recognized pre-fix checksum — proceeding."

  log "Backing up original to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] || cp -p "$MQTT_CLIENT_JS" "$BACKUP_DIR/mqtt-client.js"

  local src="$SCRIPT_DIR/mqtt-client.js"
  [[ -f $src ]] || fail "missing $src — patch directory is incomplete"
  [[ "$(file_sha "$src")" == "$FIXED_SHA" ]] || fail "bundled mqtt-client.js sha mismatch — patch directory is corrupt."

  log "Installing fixed mqtt-client.js"
  install -m 0755 "$src" "$MQTT_CLIENT_JS"

  if ! node_check "$MQTT_CLIENT_JS"; then
    log "Installed mqtt-client.js failed syntax check — restoring backup."
    install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
    fail "syntax check failed; original restored."
  fi

  # Restart + verify. This drops the ngrok SSH tunnel, so run it detached over SSH.
  run_detached_if_ssh __finalize_apply "$v"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inline)  FORCE_INLINE=1; shift ;;
    --detach)  FORCE_DETACH=1; shift ;;
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
  --rollback  restore the pre-patch mqtt-client.js from backup
  --inline    force the restart+verify to run in the foreground
  --detach    force the restart+verify to run detached

Restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside it),
so over SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
