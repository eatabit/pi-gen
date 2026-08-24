#!/bin/bash
# =============================================================================
#  2026-08-24-ble-config-permissions  (ISSUE-068)
# =============================================================================
#  Narrows the six permissive-mode literals in ble-config.js.
#
#  ble-config.js creates /usr/local/lib/eatabit/{config,log} with mode 0o777 and its
#  config and log files with 0o666, whenever it finds them missing. logrotate refuses
#  to rotate a file whose parent directory is world-writable unless the config carries
#  an `su` directive, so those directories are part of why mqtt-client.log had never
#  once been rotated. The companion patch 2026-08-23-log-permissions-and-rotation
#  narrows the directories that exist NOW; this one stops ble-config re-creating them
#  wide open.
#
#  SIX EDITS, and nothing else:
#    3x  mode: 0o777  ->  mode: 0o755
#    3x  mode: 0o666  ->  mode: 0o644
#
#  WHY THIS TRANSFORMS IN PLACE INSTEAD OF SHIPPING A FILE
#
#  ble-config.js has FIVE distinct variants across the 15 releases (see the table
#  below), and the split is by RELEASE HISTORY, not by hardware line -- v1.1.0 shares a
#  variant with v1.0.4-v1.0.6, and v1.0.10 shares one with v1.1.3/v1.1.4.
#
#  Shipping one file for everyone would install some other release's application logic
#  -- dozens of unrelated lines of BLE pairing and WiFi-config code -- in order to
#  deliver six one-word edits. Shipping five files fixes that but leaves the patch
#  unable to touch any variant nobody enumerated, including every future release.
#
#  Transforming in place gives the same result as either. The substitution is
#  deterministic, so for a KNOWN variant `sed(prior)` is byte-identical to the file a
#  whole-file payload would have installed -- verified on-device against GNU sed:
#  d70edf02... transforms to exactly a912dda0..., the sha the shipped payload had.
#  So this patch keeps the known-variant table as ASSERTIONS: transform, then if the
#  observed prior was known, require the result to equal that row's expected sha. Same
#  guarantee as a payload. If the prior is NOT known, the transform still applies and
#  verification falls back to properties (no permissive literals remain, the file still
#  parses), with the observed prior and result recorded in the marker so the pair can be
#  enumerated later.
#
#  RESTARTS ONLY ble-config.service, and does NOT detach. ngrok runs inside
#  mqtt-client, not this service, so restarting ble-config does not drop an SSH session
#  and does not touch in-flight print jobs. run_detached_if_ssh() is therefore absent by
#  design -- keeping it would be dead code whose log text ("restarting ... will CLOSE
#  this session") is false here. is_remote_session() IS kept, verbatim from
#  patches/_template including the sshd* glob (BUG-047), because --check reports the
#  session context and a future revision that ever does need a restart of a
#  tunnel-carrying service must use the correct detection rather than reinvent it.
#
#  LINEAGE: `ble-config`. Target file /usr/local/lib/eatabit/bin/ble-config.js. This is
#  the FIRST patch in this tree to modify it -- 2026-08-20-ble-classic-scan-off reads its
#  sha for diagnostics but explicitly does not modify it. It shares no file with the
#  mqtt-client, bluetooth, timezone or log2ram lineages.
#
#  It is INDEPENDENT OF THE mqtt-client LINEAGE, which is the point of it being its own
#  patch. Its sibling 2026-08-23-app-permissions-and-shadow-churn requires the
#  mqtt-client lineage head, and that lineage's entry point only accepts stock
#  v1.0.8-v1.0.10 / v1.1.2-v1.1.4 -- so devices on v1.0.1-v1.0.7, v1.1.0 or v1.1.1
#  cannot enter it at all. Welding the two fixes together would have let that dead end
#  govern this one as well. Split, this patch reaches every released variant today.
#
#  Note that 2026-08-20-ble-classic-scan-off also restarts ble-config.service and then
#  VERIFIES it, scanning its journal since a timestamp. Running the two concurrently can
#  make that scan see restart noise it did not cause. They share no file, so ordering is
#  free -- just run them back to back rather than at the same time.
# =============================================================================
set -uo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-24-ble-config-permissions"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
BACKUP_JS="${BACKUP_DIR}/ble-config.js"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
VERSION_FILE="/usr/local/lib/eatabit/version"

SERVICE="ble-config.service"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Target ------------------------------------------------------------------
BLE_JS="/usr/local/lib/eatabit/bin/ble-config.js"

# --- Gates -------------------------------------------------------------------
# The structural gate: exactly these counts must be present, or this is a file this
# patch does not understand and it refuses rather than transforming blindly. Verified
# identical in all five released variants (2026-08-24).
EXPECT_777=3
EXPECT_666=3

# Known variants, kept as ASSERTIONS rather than payloads: <prior>:<expected result>.
# Enumerated across all 15 release tags 2026-08-24. A prior found here has its post-
# transform sha checked exactly; a prior not found here still transforms, and falls back
# to property verification.
KNOWN_VARIANTS=(
  "eac92d783265578b667dd7a149b44208fa8e052c716e76e742e319790f8b6699:b5a67b58661b66aacb0405a9f27d00b4953482be417bfd0fc9a9f4f59ffd076f"  # v1.0.1, v1.0.2
  "4654037f1544f99ed2db618b8806f3b9f4b4144d3191fd7b6123ed96e6a167ca:999d9a98ef795e060fe6895bf6b4442a55592e6ba973207e5aaec7e7bf9e04cf"  # v1.0.3
  "d70edf02fa4b1adb0b294e6215204ed1a3fe163656171d8860d93a7d9c1867b2:a912dda06995ce35208c3c3dd622109e621824de79e77a162e4c3ab4123ee577"  # v1.0.4-v1.0.6, v1.1.0
  "ecbf9a06f9b699d7e5296c8087fec816d111c6792ab67ae2d62752947b0965a0:fff83fb7d3ea28a9a6681ad5de7e5218680e4b58e4e758ae548d697adefbb860"  # v1.0.7, v1.0.8, v1.1.1, v1.1.2
  "2cda3a88dc7ea08a0c8875253d4d36eca3b95b12ef81010416b202a8b5235740:a1730cdb2928f2938d8eb9cd89f4462ddef114b860cefa7356b7d10411f65435"  # v1.0.9, v1.0.10, v1.1.3, v1.1.4
)

KNOWN_VERSIONS=(1.0.1 1.0.2 1.0.3 1.0.4 1.0.5 1.0.6 1.0.7 1.0.8 1.0.9 1.0.10
                1.1.0 1.1.1 1.1.2 1.1.3 1.1.4)

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

in_list() {
  local needle=$1; shift
  local x
  for x in "$@"; do [[ $x == "$needle" ]] && return 0; done
  return 1
}

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

PLACEHOLDER_PATCH_ID="YYYY-MM-DD-short-slug"
assert_not_template() {
  [[ $PATCH_ID != "$PLACEHOLDER_PATCH_ID" ]] || fail \
    "this is patches/_template -- a skeleton, not a patch. Copy it, then set PATCH_ID to the new directory name. See ./README.md"
}

# Kept verbatim from patches/_template (BUG-047) even though this patch never detaches:
# --check reports the session context, and a future revision that DOES restart a
# tunnel-carrying service must use the correct detection rather than reinvent it.
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

# =============================================================================
#  PATCH-SPECIFIC
# =============================================================================

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

ble_sha() { [[ -f $BLE_JS ]] && file_sha "$BLE_JS" || printf ''; }

# NOTE: `grep -c` PRINTS "0" and EXITS NON-ZERO when there are no matches. A naive
# `grep -c ... || printf '0'` therefore emits "0" TWICE -- which lands in every numeric
# comparison as the string "0\n0" and makes `[[ ... -eq 0 ]]` a syntax error, so an
# already-patched file reads as needing work. Capture the output, discard the status,
# and fall back to 0 only when nothing was printed at all (e.g. the file is missing).
count_literal() {
  local n; n="$(grep -c "$1" "$BLE_JS" 2>/dev/null)"
  printf '%s' "${n:-0}"
}
count_777() { count_literal 'mode: 0o777'; }
count_666() { count_literal 'mode: 0o666'; }

# Expected post-transform sha for a known prior; empty if the prior is not enumerated.
expected_result_for() {
  local prior=$1 row
  for row in "${KNOWN_VARIANTS[@]}"; do
    [[ ${row%%:*} == "$prior" ]] && { printf '%s' "${row##*:}"; return; }
  done
  printf ''
}

# Is this sha one of the enumerated RESULTS (i.e. already transformed)?
is_known_result() {
  local s=$1 row
  for row in "${KNOWN_VARIANTS[@]}"; do
    [[ ${row##*:} == "$s" ]] && return 0
  done
  return 1
}

# Already done when no permissive literals remain.
is_fixed() {
  [[ -f $BLE_JS ]] || return 1
  [[ "$(count_777)" -eq 0 && "$(count_666)" -eq 0 ]] || return 1
  return 0
}

report_state() {
  local s; s="$(ble_sha)"
  log "  ${BLE_JS}"
  log "    sha           : ${s:-<absent>}"
  log "    mode: 0o777 x : $(count_777)   (expect ${EXPECT_777} before, 0 after)"
  log "    mode: 0o666 x : $(count_666)   (expect ${EXPECT_666} before, 0 after)"
  if [[ -n $s ]]; then
    local exp; exp="$(expected_result_for "$s")"
    if [[ -n $exp ]]; then
      log "    variant       : KNOWN prior -> result asserted against ${exp:0:16}..."
    elif is_known_result "$s"; then
      log "    variant       : KNOWN result (already transformed)"
    else
      log "    variant       : NOT enumerated -- transform still applies, verified by properties"
    fi
  fi
}

do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed. (No root required.)"
  log "State on this device:"
  report_state

  if [[ ! -f $BLE_JS ]]; then
    log "RESULT: would REFUSE -- ${BLE_JS} is missing. (exit 1)"; exit 1
  fi
  if is_fixed; then
    log "RESULT: already patched -- a real run would NO-OP. (exit 0)"; exit 0
  fi

  local c7 c6; c7="$(count_777)"; c6="$(count_666)"
  if [[ $c7 -ne $EXPECT_777 || $c6 -ne $EXPECT_666 ]]; then
    log "RESULT: would REFUSE -- unexpected literal counts. (exit 1)"
    log "  found 0o777 x${c7} and 0o666 x${c6}; expected x${EXPECT_777} and x${EXPECT_666}."
    log "  This is a ble-config.js this patch does not understand. Report the sha above"
    log "  rather than forcing -- transforming a file whose shape is unknown is how a"
    log "  mechanical patch turns into a functional change."
    exit 1
  fi

  local s exp; s="$(ble_sha)"; exp="$(expected_result_for "$s")"
  if [[ -n $exp ]]; then
    log "Prior is an enumerated variant; the result will be asserted to equal:"
    log "  ${exp}"
  else
    log "Prior is NOT enumerated. The transform still applies; the result will be verified"
    log "by properties (no permissive literals remain, file still parses) and the"
    log "prior/result pair recorded in the marker for later enumeration."
  fi

  if is_remote_session; then log "Detection: REMOTE session."
  else                       log "Detection: LOCAL console."; fi
  log "A real run restarts ${SERVICE} only. ngrok runs in mqtt-client, not here, so this"
  log "neither drops an SSH session nor disturbs in-flight print jobs."
  log "RESULT: would APPLY. (exit 2)"
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

  [[ -f $BLE_JS ]] || fail "${BLE_JS} is missing. Nothing was changed."

  if is_fixed; then
    log "No permissive literals remain. Nothing to do."
    exit 0
  fi

  # --- Structural gate, before anything is touched ---------------------------
  local c7 c6; c7="$(count_777)"; c6="$(count_666)"
  [[ $c7 -eq $EXPECT_777 && $c6 -eq $EXPECT_666 ]] || fail \
    "unexpected literal counts in ${BLE_JS} (found 0o777 x${c7}, 0o666 x${c6}; expected x${EXPECT_777}, x${EXPECT_666}; sha $(ble_sha)). Nothing was changed. Report this rather than forcing."

  local prior exp
  prior="$(ble_sha)"
  exp="$(expected_result_for "$prior")"

  # --- Back up BEFORE touching anything --------------------------------------
  mkdir -p "$BACKUP_DIR"
  cp -p "$BLE_JS" "$BACKUP_JS" || fail "could not back up ${BLE_JS}. Nothing was changed."
  log "Backed up prior file to ${BACKUP_JS}"

  # --- Transform, via a temp file so a failure cannot leave a half-written JS --
  # The temp file MUST end in .js. `node --check` resolves module format from the
  # extension and throws ERR_UNKNOWN_FILE_EXTENSION on anything else -- so a bare
  # mktemp suffix makes the parse check below fail on a file that is perfectly valid,
  # which reads as "the transform broke the file" when nothing is wrong. mktemp's
  # --suffix is GNU-only, so rename instead of relying on it.
  local tmp tmp_base
  tmp_base="$(mktemp "${BLE_JS}.XXXXXX")" || fail "could not create a temp file next to ${BLE_JS}."
  tmp="${tmp_base}.js"
  mv -f "$tmp_base" "$tmp" || { rm -f "$tmp_base"; fail "could not name the temp file with a .js suffix."; }
  if ! sed 's/mode: 0o777/mode: 0o755/g; s/mode: 0o666/mode: 0o644/g' "$BLE_JS" > "$tmp"; then
    rm -f "$tmp"; fail "sed failed. Nothing was changed."
  fi
  chown --reference="$BLE_JS" "$tmp" 2>/dev/null || true
  chmod --reference="$BLE_JS" "$tmp" 2>/dev/null || chmod 0755 "$tmp"

  # --- Verify the TEMP file before it becomes the live one -------------------
  local t7 t6
  t7="$(grep -c 'mode: 0o777' "$tmp" || true)"
  t6="$(grep -c 'mode: 0o666' "$tmp" || true)"
  if [[ $t7 -ne 0 || $t6 -ne 0 ]]; then
    rm -f "$tmp"; fail "transform left permissive literals behind (0o777 x${t7}, 0o666 x${t6}). Nothing was changed."
  fi
  if command -v node >/dev/null 2>&1; then
    node --check "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; fail "transformed file does not parse as JavaScript. Nothing was changed."; }
    log "Transformed file parses (node --check)."
  else
    log "WARNING: node not found; skipped the parse check."
  fi

  local got; got="$(file_sha "$tmp")"
  if [[ -n $exp ]]; then
    [[ $got == "$exp" ]] || { rm -f "$tmp"; fail "transform produced ${got}, but this enumerated variant must produce ${exp}. Nothing was changed."; }
    log "Result matches the expected sha for this variant: ${exp}"
  else
    log "Prior ${prior} is not enumerated; result ${got} verified by properties only."
    log "Record this pair so it can be added to KNOWN_VARIANTS:"
    log "  ${prior}:${got}"
  fi

  mv -f "$tmp" "$BLE_JS" || { rm -f "$tmp"; fail "could not move the transformed file into place. Nothing was changed."; }
  log "Installed transformed ${BLE_JS} ($(ble_sha))"

  # --- Restart. No detach: ngrok is not in this service. ----------------------
  log "Restarting ${SERVICE}..."
  systemctl restart "$SERVICE"
  sleep 3
  local state; state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: ${SERVICE} is '${state}'. Recent journal:"
    journalctl -u "$SERVICE" -n 25 --no-pager || true
    fail "${SERVICE} did not return to active. Roll back with: sudo $SELF --rollback"
  fi

  log "State after:"
  report_state

  mkdir -p "$(dirname "$MARKER_FILE")"
  {
    printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v"
    printf 'prior_sha=%s\nresult_sha=%s\nenumerated=%s\n' "$prior" "$(ble_sha)" "$([[ -n $exp ]] && echo yes || echo no)"
  } > "$MARKER_FILE"
  log "Patch applied successfully. ${SERVICE}=${state}"
  log "Rollback command: sudo $SELF --rollback"
}

do_rollback() {
  require_root
  assert_not_template
  start_logging rollback
  [[ -r $BACKUP_JS ]] || fail "no backup at ${BACKUP_JS} -- nothing to roll back"

  log "State before rollback:"
  report_state

  install -m 0755 -o root -g root "$BACKUP_JS" "$BLE_JS" || fail "could not restore ${BLE_JS}"
  log "  restored ${BLE_JS} ($(ble_sha))"

  systemctl restart "$SERVICE" || true
  rm -f "$MARKER_FILE"
  log "State after rollback:"
  report_state
  log "Rollback complete. ${SERVICE}=$(systemctl is-active "$SERVICE" || true)"
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
  apply)          do_apply ;;
  --check|check)  do_check ;;
  --rollback)     do_rollback ;;
  -h|--help)
    cat <<EOF
Usage: $0 [apply|--check|--rollback]
  apply       (default) narrow the six permissive-mode literals in ble-config.js
  --check     DRY RUN, no root needed, changes nothing
  --rollback  restore the pre-patch file from backup

Restarts $SERVICE only. ngrok runs in mqtt-client, not here, so this does not drop
an SSH session and does not disturb in-flight print jobs.
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
