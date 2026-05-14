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

set -euo pipefail

PATCH_ID="2026-05-12-watchdog-exit-hang"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQTT_CLIENT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
UNIT_FILE="/etc/systemd/system/mqtt-client.service"
VERSION_FILE="/usr/local/lib/eatabit/version"
BACKUP_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}/backup"
MARKER_FILE="/usr/local/lib/eatabit/patches/${PATCH_ID}/applied"

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

  systemctl daemon-reload
  systemctl restart mqtt-client.service
  rm -f "$MARKER_FILE"
  log "Rollback complete. Service is: $(systemctl is-active mqtt-client.service)"
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

  log "Reloading systemd and restarting mqtt-client..."
  systemctl daemon-reload
  systemctl restart mqtt-client.service

  # Brief settle, then verify.
  sleep 3
  local state
  state="$(systemctl is-active mqtt-client.service || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u mqtt-client.service -n 20 --no-pager || true
    fail "mqtt-client.service did not return to active. Rollback with: $0 --rollback"
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"

  log "Patch applied successfully. Service: $state"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $0 --rollback"
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
case "${1:-apply}" in
  apply)      do_apply ;;
  --rollback) do_rollback ;;
  -h|--help)
    cat <<EOF
Usage: $0 [apply|--rollback]
  apply       (default) apply the patch
  --rollback  restore the pre-patch files from backup
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
