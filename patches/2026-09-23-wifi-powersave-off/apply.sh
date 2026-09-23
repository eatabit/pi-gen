#!/bin/bash
# =============================================================================
#  2026-09-23-wifi-powersave-off  (BUG-093)
# =============================================================================
#  Turns 802.11 power-save OFF on the gateway's Wi-Fi, persistently. No image sets
#  it, so every gateway inherits the brcmfmac driver default -- ON -- and NM's
#  per-connection `802-11-wireless.powersave = 0 (default)` asks for nothing.
#
#  HARDENING, NOT A DIAGNOSED FIX. See ./README.md -> Honest scope. Power-save is a
#  known source of latency and drops on this chip; it is not proven to have caused
#  any specific outage. This patch removes a suspect.
#
#  What it installs: one NetworkManager conf.d file setting the global connection
#  default `wifi.powersave = 2` (disable). It then asks NM to re-read its config
#  (`nmcli general reload conf`) and turns power-save off on the live association
#  (`iw dev wlan0 set power_save off`), so the effect is immediate AND survives
#  every later reassociation and reboot -- NM re-applies the conf value at each
#  activation, which is what undoes a bare one-shot `iw` call.
#
#  Built from patches/_template (BUG-047). Deliberate deviations, same as
#  2026-08-19-gateway-timezone-utc:
#
#  1. NO SERVICE RESTART. The template's __finalize_* restart mqtt-client.service;
#     they are REMOVED here, not merely left unreached. Nothing this patch changes is
#     read by mqtt-client.
#
#  2. NO DETACH. run_detached_if_ssh() exists to survive a restart killing the ngrok
#     tunnel the operator is patching over. This patch restarts nothing, so the helper
#     is absent by design. is_remote_session() IS kept, verbatim from the template
#     including the sshd* glob, for the --check report and so that a future revision
#     that ever needs a restart uses the correct detection. If you add a restart,
#     restore run_detached_if_ssh from patches/_template/apply.sh -- do not hand-roll one.
#
#  APPLYING THIS PATCH MUST NOT DROP WI-FI. Wi-Fi is the only way in -- SSH and ngrok
#  both ride it, a Pi Zero 2 W has no Ethernet, and a device that fails to come back
#  is a truck roll. FORBIDDEN here: restarting or reloading NetworkManager (systemctl),
#  `nmcli con up/down`, `nmcli device reapply/disconnect`, `nmcli networking off`.
#  `nmcli general reload conf` re-reads NetworkManager.conf + conf.d only; it does not
#  touch connections or devices. `iw ... set power_save` changes the radio's PS mode on
#  the existing association without reassociating.
#
#  Gate: deployed STATE, not a version string and not a replaced-file sha (this
#  patch replaces nothing). Three observables -- see is_refused() -- plus `iw`
#  power_save, which is reported and converged but never refused on.
# =============================================================================
set -euo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-09-23-wifi-powersave-off"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
VERSION_FILE="/usr/local/lib/eatabit/version"
# No SERVICE variable: this patch restarts nothing. See the header.

PAYLOAD="${SCRIPT_DIR}/eatabit-wifi-powersave.conf"
TARGET="/etc/NetworkManager/conf.d/eatabit-wifi-powersave.conf"
BACKUP_CONF="${BACKUP_DIR}/eatabit-wifi-powersave.conf"   # present only if TARGET pre-existed
BACKUP_PRESTATE="${BACKUP_DIR}/prestate"

# Absolute paths: /usr/sbin is not on the `eatabit` user's PATH (measured on both
# bench units, 2026-09-23), so a bare `iw` fails with "command not found".
IW=/usr/sbin/iw
NM_BIN=/usr/sbin/NetworkManager
NMCLI=/usr/bin/nmcli
IFACE=wlan0

# Every place NetworkManager reads config from, in its merge order. A key set in any
# of these other than TARGET means someone else already decided -- refuse, name it.
NM_CONF_FILES_GLOB=(
  /usr/lib/NetworkManager/conf.d/*.conf
  /run/NetworkManager/conf.d/*.conf
  /etc/NetworkManager/NetworkManager.conf
  /etc/NetworkManager/conf.d/*.conf
  /var/lib/NetworkManager/NetworkManager-intern.conf
)

FORCE_INLINE=0
FORCE_DETACH=0

# --- Gates -------------------------------------------------------------------
# The payload sha is the end state of observable 1; it is ALSO asserted against the
# payload file shipped beside this script, so a corrupted or edited copy refuses
# instead of installing something that is not what was reviewed. The image copy
# (stage2/02-net-tweaks/files/eatabit-wifi-powersave.conf) must be byte-identical --
# a freshly flashed device then reports "already fixed" here.
FIXED_SHA="7607004708149223e138a3dc16e3904d906e043a085ebd8880c0196256d2fcac"
# Per-profile 802-11-wireless.powersave values we accept. `default` (0) defers to the
# global default this patch sets; `disable` (2) is already what we want. `enable` (3)
# and `ignore` (1) are explicit per-profile decisions that override the global
# default -- refused, because silently leaving power-save on there would report fixed.
ACCEPTED_PROFILE_PS=("default" "disable" "0" "2")
KNOWN_VERSIONS=("1.0.1" "1.0.2" "1.0.3" "1.0.4" "1.0.5" "1.0.6" "1.0.7" \
                "1.0.8" "1.0.9" "1.0.10" "1.0.11" \
                "1.1.0" "1.1.1" "1.1.2" "1.1.3" "1.1.4" "1.1.5")   # informational only

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

in_list() { local n=$1; shift; local x; for x in "$@"; do [[ $x == "$n" ]] && return 0; done; return 1; }

# --- Safety: this file was a TEMPLATE -----------------------------------------
PLACEHOLDER_PATCH_ID="YYYY-MM-DD-short-slug"
assert_not_template() {
  [[ $PATCH_ID != "$PLACEHOLDER_PATCH_ID" ]] || fail \
    "this is patches/_template -- a skeleton, not a patch. Copy it, then set PATCH_ID to the new directory name. See ./README.md"
}

# Is this an SSH session? Verbatim from patches/_template/apply.sh (BUG-047) --
# including the sshd* glob; see the template for why. This patch restarts nothing,
# so here the answer is informational only.
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

mqtt_main_pid() { systemctl show -p MainPID --value mqtt-client.service 2>/dev/null || printf 'unknown'; }

# =============================================================================
#  PATCH-SPECIFIC
# =============================================================================

# Everything an apply/rollback prints also lands in $LOG, so a device keeps its own
# record. --check never calls this: it is read-only and must work without root.
start_logging() {
  mkdir -p "$PATCH_STATE_DIR"
  exec > >(tee -a "$LOG") 2>&1
  log "---- $(date -Iseconds) :: $PATCH_ID :: $* ----"
}

note_version() {
  if in_list "$1" "${KNOWN_VERSIONS[@]}"; then
    log "Version '$1' is a known release (informational; deployed state is the gate)."
  else
    log "Version '$1' is not in the known-release list (informational only, not a refusal)."
  fi
}

# --- Observables -------------------------------------------------------------
# 1. The target conf file: "absent", or its sha.
target_state() { [[ -e $TARGET ]] && file_sha "$TARGET" || printf 'absent'; }

# 2. Other config files that set wifi.powersave (anything but TARGET). Space-separated.
#    `NetworkManager --print-config` is NOT used as the observable: it re-parses the
#    files on disk, so it shows the merged file value, not what the RUNNING daemon
#    holds, and cannot tell you which file set a key. It is reported, not gated.
other_setters() {
  local f out=""
  for f in "${NM_CONF_FILES_GLOB[@]}"; do
    [[ -f $f && $f != "$TARGET" ]] || continue
    if grep -qE '^[[:space:]]*wifi\.powersave[[:space:]]*=' "$f" 2>/dev/null; then out="$out $f"; fi
  done
  printf '%s' "${out# }"
}

# Config files this process cannot read. Without root, netplan's generated
# /run/NetworkManager/conf.d/netplan.conf is mode 0640 (measured on both bench units,
# 2026-09-23), so a non-root --check cannot see a wifi.powersave set there and must
# say so rather than report a clean gate it did not fully evaluate.
unreadable_confs() {
  local f out=""
  for f in "${NM_CONF_FILES_GLOB[@]}"; do
    if [[ -f $f && ! -r $f ]]; then out="$out $f"; fi
  done
  printf '%s' "${out# }"
}

# 3. Every Wi-Fi profile's 802-11-wireless.powersave, one "name|value" per line.
#    nmcli -g prints the symbolic form (default/ignore/disable/enable).
wifi_profiles() {
  local uuid type name ps
  "$NMCLI" -t -f UUID,TYPE,NAME con show 2>/dev/null | while IFS=: read -r uuid type name; do
    [[ $type == 802-11-wireless ]] || continue
    ps="$("$NMCLI" -g 802-11-wireless.powersave con show "$uuid" 2>/dev/null || printf '?')"
    printf '%s|%s\n' "$name" "${ps:-?}"
  done
}

bad_profiles() {
  local line v out=""
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    v="${line##*|}"
    in_list "$v" "${ACCEPTED_PROFILE_PS[@]}" || out="$out ${line%%|*}=$v"
  done < <(wifi_profiles)
  printf '%s' "${out# }"
}

# Reported and converged, never gated: it is the thing this patch changes. Reading
# it needs root (nl80211); --check without root reports "unreadable".
iw_ps() {
  local s; s="$("$IW" dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}' || true)"
  printf '%s' "${s:-unreadable}"
}

print_config_ps() {
  local out
  # Fails without root (netplan.conf is 0640); say so rather than print "unset".
  out="$("$NM_BIN" --print-config 2>/dev/null)" || { printf 'unreadable (needs root)'; return 0; }
  out="$(awk '/^\[/{sec=$0} /^[[:space:]]*wifi\.powersave[[:space:]]*=/{gsub(/[[:space:]]/,""); print sec" "$0}' <<<"$out" \
         | paste -sd';' - || true)"
  printf '%s' "${out:-wifi.powersave unset}"
}

report_state() {
  log "  conf $TARGET : $(target_state)"
  log "  other files setting wifi.powersave : $(o="$(other_setters)"; printf '%s' "${o:-none}")"
  log "  NetworkManager --print-config (files on disk) : $(print_config_ps)"
  local line
  while IFS= read -r line; do
    [[ -n $line ]] && log "  profile '${line%%|*}' 802-11-wireless.powersave = ${line##*|}"
  done < <(wifi_profiles)
  log "  iw $IFACE power_save : $(iw_ps)"
}

# Refusal reasons, one per line; empty = not refused.
refusal_reasons() {
  local t o b
  [[ -x $NMCLI  ]] || printf 'nmcli not found at %s\n' "$NMCLI"
  [[ -x $IW     ]] || printf 'iw not found at %s\n' "$IW"
  [[ -x $NM_BIN ]] || printf 'NetworkManager not found at %s\n' "$NM_BIN"
  t="$(target_state)"
  [[ $t == absent || $t == "$FIXED_SHA" ]] || printf 'conf %s present with unrecognised sha %s\n' "$TARGET" "$t"
  o="$(other_setters)"
  [[ -z $o ]] || printf 'wifi.powersave is already set by another config file: %s\n' "$o"
  b="$(bad_profiles)"
  [[ -z $b ]] || printf 'Wi-Fi profile(s) set power-save explicitly, overriding the global default: %s\n' "$b"
}

is_fixed() {
  [[ "$(target_state)" == "$FIXED_SHA" ]] && [[ -z "$(refusal_reasons)" ]] && [[ "$(iw_ps)" == off ]]
}

# Half-applied: the conf is already ours but the live radio still reads on (e.g. an
# earlier run died between install and `iw`, or NM has not reactivated since).
# Converge forward rather than refuse -- this can only move the device toward target.
is_partial() {
  [[ "$(target_state)" == "$FIXED_SHA" ]] && [[ -z "$(refusal_reasons)" ]] && [[ "$(iw_ps)" != off ]]
}

# Log what NetworkManager itself said about the config reload, since
# --print-config cannot show whether the running daemon took the new value.
log_nm_reload_evidence() {
  local since=$1
  command -v journalctl >/dev/null 2>&1 || return 0
  local out; out="$(journalctl -u NetworkManager --since "@$since" --no-pager -o cat 2>/dev/null \
                    | grep -aiE 'config|reload|powersave' | tail -n 5 || true)"
  if [[ -n $out ]]; then
    log "NetworkManager journal since the reload:"
    while IFS= read -r l; do log "    $l"; done <<<"$out"
  else
    log "NetworkManager logged nothing about the reload (the conf still applies at the next activation)."
  fi
}

nm_reload_conf() {
  local t0; t0="$(date +%s)"
  if "$NMCLI" general reload conf; then
    log "nmcli general reload conf: OK (re-read NetworkManager.conf + conf.d; connections untouched)."
  else
    # Not fatal: the conf file is on disk and NM reads it at the next activation or
    # reboot; the `iw` call below covers the interim. Say so rather than fail.
    log "WARNING: 'nmcli general reload conf' failed. The conf takes effect at the next activation/reboot."
  fi
  sleep 1
  log_nm_reload_evidence "$t0"
}

set_iw_ps() {
  local want=$1
  "$IW" dev "$IFACE" set power_save "$want" || return 1
  [[ "$(iw_ps)" == "$want" ]]
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
  log "This patch restarts nothing and drops no connection, so that detection is informational only."
  local u; u="$(unreadable_confs)"
  [[ -z $u ]] || log "NOT FULLY CHECKED -- unreadable without root, so not scanned for wifi.powersave: $u (run with sudo for a complete gate)."

  local r; r="$(refusal_reasons)"
  if [[ -n $r ]]; then
    log "RESULT: would REFUSE:"
    while IFS= read -r l; do log "  - $l"; done <<<"$r"
    log "Report this state: each is an explicit decision someone else made, not a device fault."
    exit 1
  fi
  if is_fixed; then
    log "RESULT: already fixed (conf installed at the payload sha, power_save off). A real run would NO-OP."
    exit 0
  fi
  if is_partial; then
    log "RESULT: INCONSISTENT -- conf installed but power_save reads '$(iw_ps)'. A real run would CONVERGE."
    exit 2
  fi
  log "RESULT: would APPLY."
  exit 2
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

  local r; r="$(refusal_reasons)"
  if [[ -n $r ]]; then
    while IFS= read -r l; do log "  - $l"; done <<<"$r"
    fail "REFUSING: unrecognised state (above). Nothing was changed. See ./README.md -> Gate."
  fi

  # Idempotency: a device already correct -- a new image, or patched already -- must
  # NO-OP. No marker is written: the patch changed nothing.
  if is_fixed; then
    log "Already fixed on every observable. Nothing to do."
    exit 0
  fi

  [[ -r $PAYLOAD ]] || fail "payload missing: $PAYLOAD (copy the whole patch directory)."
  local ps; ps="$(file_sha "$PAYLOAD")"
  [[ $ps == "$FIXED_SHA" ]] || fail "payload $PAYLOAD has sha $ps, expected $FIXED_SHA -- corrupted or edited copy. Nothing was changed."

  local iw_before; iw_before="$(iw_ps)"
  if is_partial; then
    log "INCONSISTENT state -- conf already installed, power_save reads '${iw_before}'. Converging."
  fi

  # Back up. On every stock image TARGET is absent, so the backup mostly records
  # ABSENCE; the prestate file keeps all observables for the record and for rollback.
  mkdir -p "$BACKUP_DIR"
  if [[ ! -e $BACKUP_PRESTATE ]]; then
    {
      printf 'saved_at=%s\n' "$(date -Iseconds)"
      printf 'target_state=%s\n' "$(target_state)"
      printf 'iw_power_save=%s\n' "$iw_before"
      printf 'print_config=%s\n' "$(print_config_ps)"
      wifi_profiles | sed 's/^/profile=/'
    } > "$BACKUP_PRESTATE"
    [[ -e $TARGET ]] && cp -p "$TARGET" "$BACKUP_CONF"
    log "Backed up prior state to $BACKUP_DIR"
  else
    log "Keeping the existing prestate backup (from the first run): $BACKUP_PRESTATE"
  fi

  if [[ "$(target_state)" != "$FIXED_SHA" ]]; then
    install -D -m 644 "$PAYLOAD" "$TARGET"
    log "Installed $TARGET"
  fi
  [[ "$(target_state)" == "$FIXED_SHA" ]] || fail "installed conf does not match the payload sha -- investigate before re-running."

  nm_reload_conf

  if ! set_iw_ps off; then
    log "State now:"; report_state
    fail "power_save still reads '$(iw_ps)' after 'iw set power_save off'. The conf is installed and applies at the next reassociation/reboot; re-run to converge. Rollback: sudo $SELF --rollback"
  fi

  local pid_after; pid_after="$(mqtt_main_pid)"
  log "mqtt-client MainPID after : ${pid_after}"
  if [[ $pid_before != "$pid_after" ]]; then
    log "WARNING: mqtt-client MainPID CHANGED (${pid_before} -> ${pid_after})."
    log "This patch restarts nothing, so something else did -- record it and raise it."
  else
    log "mqtt-client MainPID unchanged -- no restart occurred."
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\npower_save_before=%s\npower_save_after=%s\nmqtt_mainpid_before=%s\nmqtt_mainpid_after=%s\nresult=success\n' \
    "$(date -Iseconds)" "$v" "$iw_before" "$(iw_ps)" "$pid_before" "$pid_after" > "$MARKER_FILE"

  log "State after:"
  report_state
  log "Patch applied successfully. No service was restarted; Wi-Fi was not reassociated."
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
}

do_rollback() {
  require_root
  assert_not_template
  start_logging rollback
  [[ -r $BACKUP_PRESTATE ]] || fail "no backup at $BACKUP_PRESTATE -- nothing to roll back"
  local prior_ps; prior_ps="$(awk -F= '$1=="iw_power_save"{print $2}' "$BACKUP_PRESTATE")"
  [[ $prior_ps == on || $prior_ps == off ]] || prior_ps=on   # driver default

  log "State before rollback:"
  report_state

  if [[ -e $BACKUP_CONF ]]; then
    install -m 644 "$BACKUP_CONF" "$TARGET"
    log "Restored prior $TARGET from backup."
  else
    rm -f "$TARGET"
    log "Removed $TARGET (it was absent before the patch)."
  fi

  nm_reload_conf

  if ! set_iw_ps "$prior_ps"; then
    log "State now:"; report_state
    fail "power_save reads '$(iw_ps)', expected '${prior_ps}' after rollback."
  fi
  rm -f "$MARKER_FILE"
  # The backup is removed so a later re-apply records a fresh prestate.
  rm -rf "$BACKUP_DIR"
  log "State after rollback:"
  report_state
  log "Rollback complete. No service was restarted; Wi-Fi was not reassociated."
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
  apply       (default) install $TARGET and turn Wi-Fi power-save off now
  --check     DRY RUN, no root needed, changes nothing
              exit 0 = already fixed   1 = would refuse   2 = would apply
  --rollback  remove the conf (or restore a pre-existing one) and restore the
              prior power_save state

This patch RESTARTS NOTHING and DROPS NO CONNECTION. It never restarts or reloads
NetworkManager and never brings a connection down or up: \`nmcli general reload
conf\` re-reads config only, and \`iw set power_save\` changes the radio mode on the
existing association. There is therefore no detached mode: the --inline / --detach
flags are accepted for consistency with the other patches but change nothing here.
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
