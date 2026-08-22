#!/bin/bash
# Patch: 2026-05-12-watchdog-exit-hang
# Fixes Layer 1 watchdog process.exit() being unreachable due to an awaited
# hanging MQTT publish, and moves systemd StartLimit* keys into [Unit].
#
# Affected versions: v1.0.2–v1.0.7, v1.1.0–v1.1.1
# Permanent fix shipped in: v1.0.8, v1.1.2
#
# Usage:
#   sudo ./apply.sh             # apply patch
#   sudo ./apply.sh --rollback  # restore originals from backup
#
# Restarting mqtt-client.service CLOSES an SSH session opened over the ngrok
# tunnel, because ngrok runs inside that process. Over SSH the restart+verify
# therefore re-execs DETACHED and logs to the patch state dir; --inline and
# --detach override the detection. Added 2026-08-22 by BUG-047: this script
# previously restarted the service inline on BOTH the apply and rollback paths.

set -euo pipefail

PATCH_ID="2026-05-12-watchdog-exit-hang"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MQTT_CLIENT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
UNIT_FILE="/etc/systemd/system/mqtt-client.service"
VERSION_FILE="/usr/local/lib/eatabit/version"
BACKUP_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}/backup"
MARKER_FILE="/usr/local/lib/eatabit/patches/${PATCH_ID}/applied"
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
LOG="${PATCH_STATE_DIR}/apply.log"
SERVICE="mqtt-client.service"
FORCE_INLINE=0
FORCE_DETACH=0

AFFECTED_VERSIONS=("1.0.2" "1.0.3" "1.0.4" "1.0.5" "1.0.6" "1.0.7" "1.1.0" "1.1.1")

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "must be run as root (use: sudo $0)"
  fi
}

current_version() {
  if [[ ! -f $VERSION_FILE ]]; then
    fail "$VERSION_FILE not found — is this an eatabit Pi image?"
  fi
  tr -d '[:space:]' < "$VERSION_FILE"
}

is_affected_version() {
  local v=$1
  for av in "${AFFECTED_VERSIONS[@]}"; do
    [[ $v == "$av" ]] && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# Rollback
# -----------------------------------------------------------------------------
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

do_rollback() {
  require_root
  log "Rolling back patch ${PATCH_ID}..."

  if [[ ! -d $BACKUP_DIR ]]; then
    fail "no backup directory at $BACKUP_DIR — nothing to roll back"
  fi

  if [[ -f "$BACKUP_DIR/mqtt-client.js" ]]; then
    cp -p "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
    log "Restored $MQTT_CLIENT_JS"
  fi

  if [[ -f "$BACKUP_DIR/mqtt-client.service" ]]; then
    cp -p "$BACKUP_DIR/mqtt-client.service" "$UNIT_FILE"
    log "Restored $UNIT_FILE"
  fi

  run_detached_if_ssh __finalize_rollback
}

__finalize_rollback() {
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  rm -f "$MARKER_FILE"
  log "Rollback complete. Service is: $(systemctl is-active "$SERVICE")"
}

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------
do_apply() {
  require_root

  local v
  v="$(current_version)"
  log "Detected device version: $v"

  if ! is_affected_version "$v"; then
    if [[ -f $MARKER_FILE ]]; then
      log "Patch already marked applied. Nothing to do."
      exit 0
    fi
    fail "version $v is not in the affected set (${AFFECTED_VERSIONS[*]}). Refusing to apply."
  fi

  # Idempotency check: look for the new code signature.
  if grep -q "setTimeout(() => process.exit(1), 3000).unref()" "$MQTT_CLIENT_JS"; then
    log "mqtt-client.js already contains the fix. Skipping JS patch."
    local js_already_patched=1
  else
    local js_already_patched=0
  fi

  if grep -q '^StartLimitIntervalSec=' "$UNIT_FILE" 2>/dev/null \
     && ! awk '/^\[Service\]/{s=1} /^\[/&&!/^\[Service\]/{s=0} s && /^StartLimitIntervalSec=/{found=1} END{exit !found}' "$UNIT_FILE"; then
    log "Unit file already has StartLimitIntervalSec in [Unit]. Skipping unit patch."
    local unit_already_patched=1
  else
    local unit_already_patched=0
  fi

  if (( js_already_patched && unit_already_patched )); then
    log "Both files already patched. Marking and exiting."
    mkdir -p "$(dirname "$MARKER_FILE")"
    touch "$MARKER_FILE"
    exit 0
  fi

  log "Backing up originals to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]]      || cp -p "$MQTT_CLIENT_JS" "$BACKUP_DIR/mqtt-client.js"
  [[ -f "$BACKUP_DIR/mqtt-client.service" ]] || cp -p "$UNIT_FILE"      "$BACKUP_DIR/mqtt-client.service"

  if (( ! js_already_patched )); then
    patch_mqtt_client_js
  fi

  if (( ! unit_already_patched )); then
    patch_unit_file
  fi

  run_detached_if_ssh __finalize_apply "$v"
}

__finalize_apply() {
  local v=$1
  log "Reloading systemd and restarting mqtt-client..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"

  # Brief settle, then verify.
  sleep 3
  local state
  state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    fail "$SERVICE did not return to active. Rollback with: sudo $SELF --rollback"
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"

  log "Patch applied successfully. Service: $state"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
}

# -----------------------------------------------------------------------------
# JS patch: replace the watchdog-trigger block.
# Uses Python for a multi-line, anchored, exact match — safer than sed.
# -----------------------------------------------------------------------------
patch_mqtt_client_js() {
  log "Patching $MQTT_CLIENT_JS"
  python3 - "$MQTT_CLIENT_JS" <<'PYEOF'
import io, sys

path = sys.argv[1]
with io.open(path, "r", encoding="utf-8") as f:
    src = f.read()

old = (
    '          watchdogTriggerCount++;\n'
    '\n'
    '          // Best-effort: publish event before exit (may fail if truly disconnected)\n'
    '          try {\n'
    '            await publishEvent("connectionWatchdogTriggered", {\n'
    '              disconnectedForMs: disconnectedMs,\n'
    '              lastConnectedAt: lastConnectedAt\n'
    '                ? new Date(lastConnectedAt).toISOString()\n'
    '                : null,\n'
    '              triggeredAt: new Date().toISOString(),\n'
    '            });\n'
    '          } catch (_) {\n'
    '            // Expected to fail if disconnected\n'
    '          }\n'
    '\n'
    '          process.exit(1);\n'
)

new = (
    '          watchdogTriggerCount++;\n'
    '\n'
    '          // The MQTT publish promise can hang forever when the SDK is wedged —\n'
    '          // awaiting it before process.exit() left devices stuck for 18h in the\n'
    '          // field. Fire-and-forget, then exit. Belt-and-suspenders setTimeout\n'
    '          // guarantees exit if any future code above introduces a sync hang.\n'
    '          setTimeout(() => process.exit(1), 3000).unref();\n'
    '\n'
    '          publishEvent("connectionWatchdogTriggered", {\n'
    '            disconnectedForMs: disconnectedMs,\n'
    '            lastConnectedAt: lastConnectedAt\n'
    '              ? new Date(lastConnectedAt).toISOString()\n'
    '              : null,\n'
    '            triggeredAt: new Date().toISOString(),\n'
    '          }).catch(() => {});\n'
    '\n'
    '          process.exit(1);\n'
)

if old not in src:
    print("ERROR: expected watchdog block not found in mqtt-client.js — refusing to patch.", file=sys.stderr)
    sys.exit(2)

if src.count(old) != 1:
    print(f"ERROR: watchdog block matched {src.count(old)} times, expected 1. Refusing.", file=sys.stderr)
    sys.exit(3)

patched = src.replace(old, new)
with io.open(path, "w", encoding="utf-8") as f:
    f.write(patched)

print("mqtt-client.js patched.")
PYEOF
}

# -----------------------------------------------------------------------------
# Unit file patch: replace the entire file with the corrected version shipped
# alongside this script. Safer than in-place section edits with awk.
# -----------------------------------------------------------------------------
patch_unit_file() {
  log "Patching $UNIT_FILE"
  local src="$SCRIPT_DIR/mqtt-client.service"
  if [[ ! -f $src ]]; then
    fail "missing $src — patch directory is incomplete"
  fi
  install -m 0644 "$src" "$UNIT_FILE"
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
  apply)      do_apply ;;
  --rollback) do_rollback ;;
  __finalize_apply)     __finalize_apply "${2:?missing version}" ;;
  __finalize_rollback)  __finalize_rollback ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--inline|--detach] [apply|--rollback]
  apply       (default) apply the patch
  --rollback  restore the pre-patch files from backup
  --inline    force the restart+verify to run in the foreground
  --detach    force the restart+verify to run detached

Restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside it),
so over SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
