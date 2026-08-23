#!/bin/bash
# =============================================================================
#  BUG-045 -- MQTT keep-alive has no tolerance for a late PINGRESP
# =============================================================================
#  Adds configBuilder.with_ping_timeout_ms(10_000) to mqtt-client.js, widening the
#  PINGRESP response window from the AWS CRT default of 3000 ms to 10 s.
#
#  The connection was being torn down at keep_alive + ping_timeout = 33.2 s whenever
#  one PINGRESP arrived late -- with the WiFi association never dropping and signal at
#  -47 dBm. Every observed disconnect was AWS_ERROR_MQTT_TIMEOUT at n x 30 s + ~3.2 s.
#
#  Cost: genuine-offline detection moves 33 s -> 40 s, still far below the Layer 1
#  watchdog's MAX_DISCONNECT_DURATION_MS (150 s) and systemd's WatchdogSec (180 s).
#
#  NOT a fix for genuine packet LOSS. The CRT MQTT311 client sends one PINGREQ per
#  keep-alive interval and tears down if no response arrives inside ping_timeout;
#  there is no missed-ping counter and no retry inside the window. This buys tolerance
#  for LATENCY only.
#
#  Lineage: mqtt-client -- chains after 2026-08-20-ngrok-session-reclaim (see below).
#  Machinery above the PATCH-SPECIFIC divider is from patches/_template. In particular
#  do NOT "tidy" the sshd* glob in is_remote_session() -- see the note there.
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-19-mqtt-keepalive-tolerance"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
SERVICE="mqtt-client.service"             # the unit this patch restarts
MQTT_CLIENT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
VERSION_FILE="/usr/local/lib/eatabit/version"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Gates -------------------------------------------------------------------
# Checksums are the authoritative gate; version lists are informational. Refusing
# on an unrecognised sha, and PRINTING the observed sha, is what makes a patch safe
# to hand to an operator who cannot inspect the device first.
FIXED_SHA="b009b68c8692314ed8476f3bbb3b1d479c3d97fca67240f7bcf96e44444ed339"

# DELIBERATELY NARROW -- exactly one accepted prior.
#
# This patch installs a mqtt-client.js derived from the 2026-08-20-ngrok-session-reclaim
# generation, which stores its device-ready guard flag at /run/eatabit/device-ready-printed.
# That directory exists only because that patch's UNIT declares RuntimeDirectory=eatabit.
# Stock units (v1.0.8-v1.0.10 / v1.1.2-v1.1.4) carry PrivateTmp=true and NO RuntimeDirectory
# -- verified against v1.1.4:stage3/03-install-mqtt-client/00-run.sh, 2026-08-23.
#
# So accepting a stock sha here would install js that needs /run/eatabit onto a device whose
# unit never creates it, silently reintroducing BUG-039 on a js-only patch that touches no
# unit. The lineage head is self-contained and already fleet-applied, so requiring it costs
# nothing. Run 2026-08-20-ngrok-session-reclaim first; this refuses anything else.
ACCEPTED_PRIOR_SHAS=(
  "1d49a43a401d782bf9d72f69f2c9346c21405a17685185bdbd50f03986d60121" # output of 2026-08-20-ngrok-session-reclaim (== repo source at hw/1.0 and hw/1.1)
)

# Informational only; the checksums above are the authoritative gate. 1.1.0 is listed
# because bench device 0000000003c45d6d reports it while running head files -- a field
# patch does not change VERSION. There is no v1.1.0 release tag.
KNOWN_VERSIONS=("1.0.8" "1.0.9" "1.0.10" "1.1.0" "1.1.2" "1.1.3" "1.1.4")

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

current_version() {
  [[ -f $VERSION_FILE ]] || fail "$VERSION_FILE not found -- is this an eatabit Pi image?"
  tr -d '[:space:]' < "$VERSION_FILE"
}

node_check() {
  local node_bin
  node_bin="$(command -v node || true)"
  [[ -x $node_bin ]] || node_bin="/usr/bin/node"
  [[ -x $node_bin ]] || { log "WARNING: node not found, skipping syntax check"; return 0; }
  "$node_bin" --check "$1"
}

restore_backup() {
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] && install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  return 0
}

refuse_unrecognized() {
  local path=$1 observed=$2; shift 2
  local candidates=("$@") a
  {
    printf '\n[ERROR] Refusing to overwrite an unrecognized file.\n'
    printf '  file:            %s\n' "$path"
    printf '  observed sha256: %s\n' "$observed"
    printf '  device version:  %s\n' "$(current_version 2>/dev/null || echo unknown)"
    printf '  checked against:\n'
    for a in "${candidates[@]}"; do printf '    %s\n' "$a"; done
    printf '\n  This patch is NARROW by design: it accepts only the output of\n'
    printf '  2026-08-20-ngrok-session-reclaim, the head of the mqtt-client lineage.\n'
    printf '  Its payload expects /run/eatabit, which only that patch'"'"'s unit creates.\n'
    printf '  Apply 2026-08-20-ngrok-session-reclaim first, then re-run this patch.\n'
    printf '  A build outside the patch set gets the fix via the v1.0.11 / v1.1.5 image.\n'
    printf '  Report the observed sha256 above (see README.md -> Coverage).\n'
    printf '  Nothing has been modified.\n\n'
  } >&2
  exit 1
}

# The finalize steps are re-exec targets: they run in a SEPARATE process, detached,
# when the patch is applied over SSH. They therefore take everything they need as
# ARGUMENTS -- they cannot see locals from do_apply/do_rollback.
__finalize_apply() {
  local v=$1
  assert_not_template
  log "Restarting $SERVICE..."
  systemctl restart "$SERVICE"
  sleep 3
  local state; state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    log "Auto-restoring the pre-patch mqtt-client.js and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    sleep 3
    log "After auto-restore, service is: $(systemctl is-active "$SERVICE" || true)"
    fail "$SERVICE did not return to active; original file restored."
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
  systemctl restart "$SERVICE"
  rm -f "$MARKER_FILE"
  log "Rollback complete. Service is: $(systemctl is-active "$SERVICE" || true)"
}

# Exit convention, matching the lineage head:
#   0 = no-op / already patched    1 = would refuse    2 = would apply
do_check() {
  assert_not_template
  local v js_sha js_state prior
  v="$(current_version 2>/dev/null || echo unknown)"
  [[ -f $MQTT_CLIENT_JS ]] || fail "$MQTT_CLIENT_JS not found."
  js_sha="$(file_sha "$MQTT_CLIENT_JS")"

  js_state=refuse
  if [[ $js_sha == "$FIXED_SHA" ]]; then
    js_state=current
  else
    for prior in "${ACCEPTED_PRIOR_SHAS[@]}"; do [[ $js_sha == "$prior" ]] && js_state=upgrade; done
  fi

  printf 'patch          %s\n' "$PATCH_ID"
  printf 'version        %s\n' "$v"
  printf 'js    sha256   %s  [%s]\n' "$js_sha" "$js_state"
  if is_remote_session; then printf 'detection      REMOTE -- a real run would DETACH\n'
  else                       printf 'detection      LOCAL -- a real run would go INLINE\n'; fi

  case $js_state in
    current)
      if [[ -f $MARKER_FILE ]]; then
        printf 'RESULT         NO-OP -- already patched\n'; return 0
      fi
      printf 'RESULT         WOULD APPLY -- file is patched but the apply never completed\n'
      printf '               (no marker); a real run would restart %s to finish it\n' "$SERVICE"
      return 2 ;;
    upgrade) printf 'RESULT         WOULD APPLY -- installs mqtt-client.js, then ONE mqtt-client restart\n'; return 2 ;;
    *)       printf 'RESULT         WOULD REFUSE -- unrecognized mqtt-client.js; nothing would be modified\n'; return 1 ;;
  esac
}

do_apply() {
  require_root
  assert_not_template

  local v js_sha is_accepted prior
  v="$(current_version)"
  log "Detected device version: $v"

  [[ -f $MQTT_CLIENT_JS ]] || fail "$MQTT_CLIENT_JS not found."
  js_sha="$(file_sha "$MQTT_CLIENT_JS")"

  # Idempotency -- but ONLY when the apply actually completed.
  #
  # The file being at FIXED_SHA is NOT sufficient. do_apply installs the file and THEN
  # restarts; if it is interrupted between those two steps -- a dropped tunnel, a SIGPIPE,
  # an operator ^C -- the device is left with the new file on disk and the OLD code still
  # running in memory. A naive "sha matches, nothing to do" would then write a success
  # marker and exit 0, reporting a fix that is not actually in effect until something else
  # happens to restart the service. Observed on a bench device 2026-08-23.
  #
  # The marker is written only by __finalize_apply, AFTER the service comes back active. So
  # "at FIXED_SHA with no marker" means an interrupted apply: finish it by restarting.
  if [[ $js_sha == "$FIXED_SHA" ]]; then
    if [[ -f $MARKER_FILE ]]; then
      log "mqtt-client.js already contains the fix and the apply completed. Nothing to do."
      exit 0
    fi
    log "mqtt-client.js is at the fixed sha but no completion marker is present."
    log "This is an interrupted apply -- finishing it now by restarting $SERVICE."
    mkdir -p "$PATCH_STATE_DIR"
    run_detached_if_ssh __finalize_apply "$v"
    exit 0
  fi

  is_accepted=0
  for prior in "${ACCEPTED_PRIOR_SHAS[@]}"; do [[ $js_sha == "$prior" ]] && is_accepted=1; done
  (( is_accepted )) || refuse_unrecognized "$MQTT_CLIENT_JS" "$js_sha" "${ACCEPTED_PRIOR_SHAS[@]}" "$FIXED_SHA"

  local known=0 kv
  for kv in "${KNOWN_VERSIONS[@]}"; do [[ $v == "$kv" ]] && known=1; done
  (( known )) || log "NOTE: version $v not in ${KNOWN_VERSIONS[*]}, but its file matches a recognized checksum -- proceeding."

  local src_js="$SCRIPT_DIR/mqtt-client.js"
  [[ -f $src_js ]] || fail "missing $src_js -- patch directory is incomplete"
  [[ "$(file_sha "$src_js")" == "$FIXED_SHA" ]] || fail "bundled mqtt-client.js sha mismatch -- patch directory is corrupt."

  # Verify the candidate BEFORE installing. An unparseable JS means a service that will
  # not start, on a device we may not be able to reach again.
  node_check "$src_js" || fail "bundled mqtt-client.js failed node --check -- refusing to install it."
  log "node --check: bundled mqtt-client.js is clean."

  log "Backing up original to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] || cp -p "$MQTT_CLIENT_JS" "$BACKUP_DIR/mqtt-client.js"

  log "Installing fixed mqtt-client.js"
  install -m 0755 "$src_js" "$MQTT_CLIENT_JS"
  if ! node_check "$MQTT_CLIENT_JS"; then
    log "Installed mqtt-client.js failed syntax check -- restoring backup."
    restore_backup
    fail "syntax check failed; original restored."
  fi

  # Restart + verify. This drops the ngrok SSH tunnel, so run it detached over SSH.
  run_detached_if_ssh __finalize_apply "$v"
}

do_rollback() {
  require_root
  assert_not_template
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]] || fail "no mqtt-client.js in $BACKUP_DIR -- nothing to roll back"
  log "Restoring mqtt-client.js from $BACKUP_DIR"
  restore_backup
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
