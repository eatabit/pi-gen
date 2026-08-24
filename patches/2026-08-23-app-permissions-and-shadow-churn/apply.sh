#!/bin/bash
# =============================================================================
#  2026-08-23-app-permissions-and-shadow-churn  (ISSUE-068, Phase 2 -- app half)
# =============================================================================
#  The application-code half of ISSUE-068. Companion to
#  2026-08-23-log-permissions-and-rotation, which fixes the same problem from the
#  filesystem side. Either can be applied first; see "Ordering" below.
#
#  TWO FIXES.
#
#  1. PERMISSIVE MODES IN THE APPLICATIONS. mqtt-client.js and ble-config.js create
#     /usr/local/lib/eatabit/{log,config,reset} with mode 0o777 and their log files
#     with 0o666 whenever they find them MISSING. logrotate refuses to rotate a file
#     whose parent directory is world-writable unless the config carries an `su`
#     directive, so those directories are why mqtt-client.log had never once been
#     rotated. The companion patch narrows the directories that exist NOW; this one
#     stops the applications RE-CREATING them wide open. Neither is sufficient alone:
#     without this patch, one service start against an absent directory silently undoes
#     the companion patch and rotation breaks again. 14 sites: 8 in mqtt-client.js,
#     6 in ble-config.js.
#
#  2. shadow-*.json REWRITE CHURN -- fixed by MOVING THE FILES TO tmpfs.
#     persistShadowToFile() rewrote the whole file on every call into
#     /usr/local/lib/eatabit/config, which is NOT RAM-buffered (log2ram only ever
#     managed /var/log). The health shadow fires every 15 minutes: 96 whole-file
#     rewrites a day, ~159 KiB/day straight to the SD card, roughly 7x the write volume
#     of the entire log directory.
#
#     THE FIX IS THE LOCATION. The files now live in /run/eatabit -- tmpfs. systemd
#     already creates that directory for this unit (RuntimeDirectory=eatabit,
#     RuntimeDirectoryPreserve=restart), so it survives a service restart and is
#     discarded on stop. That is the correct lifetime: these files are WRITE-ONLY.
#     Nothing in the image or on a device reads them back -- the authoritative shadow
#     lives in AWS IoT Core, this is a debugging snapshot, and service packs explicitly
#     list config/shadow-*.json as never-managed. Losing them on reboot costs nothing;
#     each is rewritten within one heartbeat. Card writes for this state: zero.
#
#     A skip-if-unchanged guard is also present, and it is NOT the fix. MEASURED ON
#     HARDWARE (bench .126, 2026-08-24): it does NOT reduce the health shadow's write
#     rate, because that shadow's `state` legitimately changes every cycle -- it embeds
#     its own timestamp, uptime.seconds, freeMemory and disk usage. The guard was
#     written expecting it to help; it does not. It is kept because it is correct and
#     does skip genuinely redundant writes (the private shadow at start-up, for one).
#     Recorded here so nobody cites it as the card-wear fix, or re-derives this the
#     hard way.
#
#     The comparison covers `state` ONLY, because the wrapper's own `timestamp` changes
#     on every serialisation and a whole-content check would never skip. `timestamp`
#     therefore means LAST CHANGE, not last check -- safe, since the 15-minute MQTT
#     publish to AWS IoT Core is untouched and the heartbeat stays in mqtt-client.log.
#
#  THIS PATCH RESTARTS SERVICES. Unlike its companion, it replaces running code, so
#  mqtt-client.service and ble-config.service must both be restarted to take effect.
#  RESTARTING mqtt-client DROPS IN-FLIGHT PRINT JOBS (BUG-049) and CLOSES an ngrok SSH
#  session, because ngrok runs inside that process. run_detached_if_ssh() is therefore
#  restored from patches/_template VERBATIM -- including the sshd* glob and the
#  `bash "$SELF"` re-exec, both of which are BUG-047 and both of which have been got
#  wrong here before. Do not hand-roll either.
#
#  PAYLOADS ARE THE IMAGE SOURCE, byte for byte.
#    mqtt-client.js  == iot-pi stage3/03-install-mqtt-client/files/mqtt-client.js
#    ble-config.js   == iot-pi stage3/08-ble-config/files/ble-config.js
#  as of ISSUE-068 Phase 2. A patched device and a device reflashed to the next release
#  therefore converge on exactly the same bytes rather than drifting into two
#  similar-but-different states.
#
#  A NOTE ON THE PRIOR STATE, because an earlier draft of this work got it backwards.
#  The deployed mqtt-client.js (b009b68c...) is IDENTICAL to the pre-ISSUE-068 image
#  source -- the 2026-08-20-ngrok-session-reclaim and 2026-08-19-mqtt-keepalive-tolerance
#  fixes were already merged into the image, exactly as patches/README.md requires
#  ("the same fix is ALSO committed to the image source ... the image is the source of
#  truth"). Installing this payload therefore REVERTS NOTHING: it is that same file plus
#  the ISSUE-068 changes. Verified by comparing the deployed sha against
#  `git show <ref>:stage3/03-install-mqtt-client/files/mqtt-client.js`.
#
#  ble-config.js HAS FIVE VARIANTS across the 15 releases, and they are not
#  interchangeable -- so this patch ships FIVE payloads, one per variant, selected by
#  OBSERVED SHA. THE SPLIT IS BY RELEASE HISTORY, NOT BY HARDWARE LINE: v1.1.0 shares a
#  variant with v1.0.4-v1.0.6, and v1.0.10 shares one with v1.1.3/v1.1.4. Two devices on
#  the same line can need different payloads; two on different lines can need the same
#  one. Never key this on the version string or the branch.
#
#  Each payload is THAT VARIANT'S OWN FILE with only the six permissive-mode literals
#  narrowed (3x 0o777, 3x 0o666 -- identical in all five), so a v1.0.3 device gets
#  v1.0.3's file fixed rather than v1.1.4's. Only the 2cda3a88 payload equals the current
#  image source; the other four converge on "that release plus this fix", which is
#  correct for those devices and deliberately not the same bytes.
#
#  An earlier draft shipped only TWO payloads, generalised from the three bench devices.
#  That covered 8 of 15 releases and would have REFUSED on v1.0.1, v1.0.2, v1.0.3,
#  v1.0.7, v1.0.8, v1.1.1 and v1.1.2 -- and the mqtt prerequisite would NOT have masked
#  it, since nothing in that lineage touches ble-config.js. Enumerated properly across
#  all 15 tags on 2026-08-24. No field patch has ever modified ble-config.js (this is the
#  first), so a device's deployed sha always equals its image's and these five are
#  exhaustive for any released image.
#
#  PREREQUISITE. This patch REQUIRES 2026-08-19-mqtt-keepalive-tolerance to have been
#  applied -- its output sha is this patch's only accepted prior. MOST FIELD DEVICES ARE
#  NOT AT THAT HEAD, so this patch will refuse on them until the lineage is brought up:
#  apply 2026-08-20-ngrok-session-reclaim, then 2026-08-19-mqtt-keepalive-tolerance,
#  then this. A refusal prints exactly that sequence rather than a bare sha mismatch.
#  The prerequisite's marker file is checked and reported, but is NEVER the gate: a
#  device reflashed to an image that already contains the keepalive code has the right
#  sha and no marker, and must still be accepted.
#
#  ORDERING. Lineage `mqtt-client` (shares /usr/local/lib/eatabit/bin/mqtt-client.js with
#  2026-08-19-mqtt-keepalive-tolerance, whose output is this patch's accepted prior) and
#  lineage `ble-config` (new; no other patch ships ble-config.js). It shares NO file with
#  its companion 2026-08-23-log-permissions-and-rotation -- that one touches directory
#  modes and /etc/logrotate.d, this one touches /usr/local/lib/eatabit/bin -- so the two
#  are independent of each other and may be applied in either order. Applying BOTH is
#  what actually closes ISSUE-068 on a deployed device.
# =============================================================================
set -uo pipefail

# --- Identity ----------------------------------------------------------------
PATCH_ID="2026-08-23-app-permissions-and-shadow-churn"   # MUST equal this directory's name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# --- On-device state ---------------------------------------------------------
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
VERSION_FILE="/usr/local/lib/eatabit/version"

SERVICE="mqtt-client.service"
BLE_SERVICE="ble-config.service"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Targets -----------------------------------------------------------------
BIN_DIR="/usr/local/lib/eatabit/bin"
MQTT_JS="${BIN_DIR}/mqtt-client.js"
BLE_JS="${BIN_DIR}/ble-config.js"

SRC_MQTT="${SCRIPT_DIR}/mqtt-client.js"
# ble-config.js payloads are named for the PRIOR sha they upgrade FROM:
#   ${SCRIPT_DIR}/ble-config-<prior8>.js
# See BLE_VARIANTS below for the full table.

# --- Gates -------------------------------------------------------------------
# Checksums are the authoritative gate; version lists are informational. Refusing on an
# unrecognised sha, and PRINTING it, is what makes a patch safe to hand to an operator
# who cannot inspect the device first.
FIXED_MQTT_SHA="7ecbf0ead594437934e3d0e501689a3bf99a1df77acdefb4369b57fc5655a34a"
ACCEPTED_MQTT_PRIOR_SHAS=(
  "b009b68c8692314ed8476f3bbb3b1d479c3d97fca67240f7bcf96e44444ed339"  # head of the mqtt-client lineage == pre-ISSUE-068 image source
  "${FIXED_MQTT_SHA}"                                                 # already fixed
)

# ble-config.js: FIVE variants exist across the 15 releases, and the split is by
# RELEASE HISTORY, not by hardware line -- v1.1.0 shares a variant with v1.0.4-v1.0.6,
# and v1.0.10 shares one with v1.1.3/v1.1.4. So this table is keyed on the OBSERVED SHA,
# never on the version string or the branch. Enumerated across all 15 tags 2026-08-24;
# no field patch has ever modified ble-config.js, so a device's deployed sha always
# equals its image's, and these five are exhaustive for any released image.
#
# Each row: <prior sha>:<fixed sha>:<payload filename>
# Every payload is that variant's own file with only the six permissive-mode literals
# narrowed (3x 0o777 -> 0o755, 3x 0o666 -> 0o644) -- identical in all five -- so no
# device receives unrelated changes from another release.
BLE_VARIANTS=(
  "eac92d783265578b667dd7a149b44208fa8e052c716e76e742e319790f8b6699:b5a67b58661b66aacb0405a9f27d00b4953482be417bfd0fc9a9f4f59ffd076f:ble-config-eac92d78.js"  # v1.0.1, v1.0.2
  "4654037f1544f99ed2db618b8806f3b9f4b4144d3191fd7b6123ed96e6a167ca:999d9a98ef795e060fe6895bf6b4442a55592e6ba973207e5aaec7e7bf9e04cf:ble-config-4654037f.js"  # v1.0.3
  "d70edf02fa4b1adb0b294e6215204ed1a3fe163656171d8860d93a7d9c1867b2:a912dda06995ce35208c3c3dd622109e621824de79e77a162e4c3ab4123ee577:ble-config-d70edf02.js"  # v1.0.4-v1.0.6, v1.1.0
  "ecbf9a06f9b699d7e5296c8087fec816d111c6792ab67ae2d62752947b0965a0:fff83fb7d3ea28a9a6681ad5de7e5218680e4b58e4e758ae548d697adefbb860:ble-config-ecbf9a06.js"  # v1.0.7, v1.0.8, v1.1.1, v1.1.2
  "2cda3a88dc7ea08a0c8875253d4d36eca3b95b12ef81010416b202a8b5235740:a1730cdb2928f2938d8eb9cd89f4462ddef114b860cefa7356b7d10411f65435:ble-config-2cda3a88.js"  # v1.0.9, v1.0.10, v1.1.3, v1.1.4
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

# Is this an SSH session? Carried VERBATIM from patches/_template (BUG-047). The obvious
# test -- $SSH_CONNECTION -- is NOT sufficient: sudo's env_reset strips
# SSH_CONNECTION/SSH_CLIENT/SSH_TTY and the documented invocation is `sudo ./apply.sh`,
# so an environment-only check reports "local console" over SSH, runs the restart inline,
# and is killed by the tunnel drop it just caused -- taking the verify step and the
# automatic rollback with it. Matching `sshd` EXACTLY is also insufficient: OpenSSH 9.8+
# splits the per-connection process out as `sshd-session`, and under socket activation
# there is no `sshd` in the chain at all. Hence the parent walk and the sshd* glob.
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
    # Re-exec via `bash "$SELF"` rather than executing $SELF directly: if this directory
    # were delivered by any route that drops the executable bit, a direct exec fails with
    # "Permission denied" INSIDE the detached child while the foreground has already
    # logged "running DETACHED" and exited 0 -- success on screen, nothing applied.
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

mqtt_sha() { [[ -f $MQTT_JS ]] && file_sha "$MQTT_JS" || printf ''; }
ble_sha()  { [[ -f $BLE_JS  ]] && file_sha "$BLE_JS"  || printf ''; }

# --- Prerequisite: 2026-08-19-mqtt-keepalive-tolerance ------------------------
# This patch REQUIRES that patch to have been applied. Its output sha IS this patch's
# accepted prior, so the sha check alone is authoritative -- but a bare "unrecognised
# sha" refusal tells an operator nothing about what to do next, and MOST FIELD DEVICES
# ARE NOT AT THE LINEAGE HEAD. So when the prior does not match, work out WHY and say
# so: which prerequisite is missing, and in what order to apply them.
#
# The marker file is corroborating evidence only, never the gate. A device reflashed to
# an image that already contains the keepalive code has the correct sha and NO marker,
# and must still be accepted -- gating on the marker would refuse exactly the devices
# that need no prerequisite at all.
PREREQ_PATCH="2026-08-19-mqtt-keepalive-tolerance"
PREREQ_MARKER="/usr/local/lib/eatabit/patches/${PREREQ_PATCH}/applied"
# Priors of the lineage, so a refusal can name where the device actually sits.
LINEAGE_STOCK_SHAS_NOTE="stock v1.0.8-v1.0.10 / v1.1.2-v1.1.4 (never patched)"
NGROK_PATCH="2026-08-20-ngrok-session-reclaim"
NGROK_OUTPUT_SHA="1d49a43a401d782b"   # short; informational, for the operator message

prereq_state() {
  if [[ -f $PREREQ_MARKER ]]; then printf 'marker-present'; else printf 'no-marker'; fi
}

# Explain a failed prior check in terms the operator can act on.
explain_prior_mismatch() {
  local observed=$1
  log ""
  log "WHY THIS REFUSED:"
  log "  This patch requires ${PREREQ_PATCH} to have been applied first."
  log "  Its output is this patch's only accepted prior:"
  log "    ${ACCEPTED_MQTT_PRIOR_SHAS[0]}"
  log "  This device has:"
  log "    ${observed:-<mqtt-client.js absent>}"
  log "  Prerequisite marker on this device: $(prereq_state)"
  log ""
  log "WHAT TO DO:"
  log "  Apply the mqtt-client lineage up to its head, then re-run this patch:"
  log "    1. ${NGROK_PATCH}   (self-contained; accepts ${LINEAGE_STOCK_SHAS_NOTE},"
  log "       and the output of every earlier patch in the lineage; output ${NGROK_OUTPUT_SHA}...)"
  log "    2. ${PREREQ_PATCH}  (requires 1)"
  log "    3. this patch"
  log "  Each ships its own --check dry run. See patches/README.md -> Lineages."
  log ""
  log "  If the observed sha above matches none of those, report it rather than forcing:"
  log "  it means this device carries something this tree does not know about."
}

report_state() {
  local m b
  m="$(mqtt_sha)"; log "  ${MQTT_JS} sha: ${m:-<absent>}"
  b="$(ble_sha)";  log "  ${BLE_JS} sha: ${b:-<absent>}"
}

# Which ble payload does this device's observed sha call for? Echoes "<src>|<fixed>".
# Matches either the PRIOR (needs upgrading) or the FIXED sha (already done, so the
# same row is returned and the caller no-ops). Empty output means the observed sha is
# not one this patch knows how to upgrade -- refuse, do not guess.
ble_plan() {
  local b row prior fixed file
  b="$(ble_sha)"
  [[ -n $b ]] || { printf ''; return; }
  for row in "${BLE_VARIANTS[@]}"; do
    prior="${row%%:*}"
    fixed="${row#*:}"; fixed="${fixed%%:*}"
    file="${row##*:}"
    if [[ $b == "$prior" || $b == "$fixed" ]]; then
      printf '%s|%s' "${SCRIPT_DIR}/${file}" "$fixed"
      return
    fi
  done
  printf ''
}

# True only when BOTH files are at their fixed shas. For ble that means the fixed sha of
# THIS DEVICE'S variant -- not any fixed sha, since a device must not be considered done
# because it happens to match another release's end state.
is_fixed() {
  [[ "$(mqtt_sha)" == "$FIXED_MQTT_SHA" ]] || return 1
  local plan; plan="$(ble_plan)"
  [[ -n $plan ]] || return 1
  [[ "$(ble_sha)" == "${plan##*|}" ]] || return 1
  return 0
}

do_check() {
  assert_not_template
  log "DRY RUN -- nothing will be changed. (No root required.)"
  log "Payloads shipped with this patch:"
  log "  mqtt-client.js       : $(file_sha "$SRC_MQTT")"
  local row file
  for row in "${BLE_VARIANTS[@]}"; do
    file="${row##*:}"
    log "  ${file} : $(file_sha "${SCRIPT_DIR}/${file}")"
  done
  log "State on this device:"
  report_state

  if is_fixed; then
    log "RESULT: already patched -- a real run would NO-OP. (exit 0)"
    exit 0
  fi

  log "Prerequisite ${PREREQ_PATCH}: $(prereq_state) (corroborating only; the sha is the gate)"

  local m; m="$(mqtt_sha)"
  if [[ -z $m ]]; then
    log "RESULT: would REFUSE -- ${MQTT_JS} is missing. (exit 1)"; exit 1
  fi
  if ! in_list "$m" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}"; then
    log "RESULT: would REFUSE -- unrecognised ${MQTT_JS}. (exit 1)"
    explain_prior_mismatch "$m"
    exit 1
  fi

  local plan; plan="$(ble_plan)"
  if [[ -z $plan ]]; then
    log "RESULT: would REFUSE -- unrecognised ${BLE_JS} (observed $(ble_sha)). (exit 1)"
    log "  accepted priors (one per released variant):"
    local row
    for row in "${BLE_VARIANTS[@]}"; do log "    ${row%%:*}"; done
    exit 1
  fi
  log "ble-config payload selected: $(basename "${plan%%|*}")"

  if is_remote_session; then
    log "Detection: REMOTE -- a real run would DETACH (restarting ${SERVICE} closes this session)."
  else
    log "Detection: LOCAL -- a real run would go INLINE."
  fi
  log "NOTE: a real run RESTARTS ${SERVICE} and ${BLE_SERVICE}."
  log "      Restarting ${SERVICE} DROPS IN-FLIGHT PRINT JOBS (BUG-049)."
  log "RESULT: would APPLY. (exit 2)"
  exit 2
}

__finalize_apply() {
  local v=$1
  assert_not_template
  log "Restarting ${SERVICE} and ${BLE_SERVICE}..."
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  systemctl restart "$BLE_SERVICE"
  sleep 3

  local s1 s2
  s1="$(systemctl is-active "$SERVICE" || true)"
  s2="$(systemctl is-active "$BLE_SERVICE" || true)"
  if [[ $s1 != active || $s2 != active ]]; then
    log "WARNING: ${SERVICE}=${s1} ${BLE_SERVICE}=${s2}. Recent journal:"
    journalctl -u "$SERVICE" -u "$BLE_SERVICE" -n 25 --no-pager || true
    fail "a service did not return to active. Rollback with: sudo $SELF --rollback"
  fi

  # Retire the old on-card snapshots, AFTER the restart so the pre-patch process cannot
  # recreate them. Left in place they would be frozen at the moment of patching while
  # still looking like live state -- a trap for whoever next reads one to debug. They are
  # backed up first, so --rollback puts them back.
  local old_shadow_dir="/usr/local/lib/eatabit/config"
  local moved=0 f
  for f in "$old_shadow_dir"/shadow-*.json; do
    [[ -e $f ]] || continue
    mkdir -p "${BACKUP_DIR}/config-shadows"
    if cp -p "$f" "${BACKUP_DIR}/config-shadows/" && rm -f "$f"; then
      moved=$((moved + 1))
    else
      log "  WARNING: could not retire $(basename "$f") -- left in place."
    fi
  done
  if [[ $moved -gt 0 ]]; then
    log "Retired ${moved} stale on-card shadow snapshot(s) from ${old_shadow_dir}"
    log "  (backed up under ${BACKUP_DIR}/config-shadows; live copies are now in /run/eatabit)"
  fi

  mkdir -p "$(dirname "$MARKER_FILE")"
  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. ${SERVICE}=${s1} ${BLE_SERVICE}=${s2}"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $SELF --rollback"
  log ""
  log "To confirm the shadow-churn fix, check the snapshots are on tmpfs and NOT on card:"
  log "  ls /run/eatabit/shadow-*.json                              # expect 3"
  log "  ls /usr/local/lib/eatabit/config/shadow-*.json             # expect none"
  log "  findmnt -no FSTYPE /run                                    # expect tmpfs"
  log "That is the fix: these files still rewrite every 15 minutes, but on tmpfs, so"
  log "they cost ZERO SD-card writes. Do not expect the mtime to stop advancing --"
  log "the health shadow's state genuinely changes every cycle (uptime, freeMemory)."
}

__finalize_rollback() {
  assert_not_template
  log "Restarting ${SERVICE} and ${BLE_SERVICE}..."
  systemctl daemon-reload
  systemctl restart "$SERVICE" || true
  systemctl restart "$BLE_SERVICE" || true
  rm -f "$MARKER_FILE"
  log "Rollback complete. ${SERVICE}=$(systemctl is-active "$SERVICE" || true) ${BLE_SERVICE}=$(systemctl is-active "$BLE_SERVICE" || true)"
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

  if is_fixed; then
    log "Both applications are already at the fixed shas. Nothing to do."
    exit 0
  fi

  # --- Gates, before anything is touched -------------------------------------
  log "Prerequisite ${PREREQ_PATCH}: $(prereq_state) (corroborating only; the sha is the gate)"

  local m; m="$(mqtt_sha)"
  [[ -n $m ]] || fail "${MQTT_JS} is missing. Nothing was changed."
  if ! in_list "$m" "${ACCEPTED_MQTT_PRIOR_SHAS[@]}"; then
    explain_prior_mismatch "$m"
    fail "unrecognised ${MQTT_JS}. Nothing was changed. See the prerequisite steps above."
  fi

  local plan; plan="$(ble_plan)"
  if [[ -z $plan ]]; then
    log "Observed ${BLE_JS}: $(ble_sha)"
    log "Accepted priors (one per released variant):"
    local row
    for row in "${BLE_VARIANTS[@]}"; do log "  ${row%%:*}"; done
    fail "unrecognised ${BLE_JS}. Nothing was changed. Report the observed sha -- it means this device carries a ble-config.js this tree does not know about."
  fi
  local ble_src="${plan%%|*}" ble_expect="${plan##*|}"
  [[ -r $ble_src  ]] || fail "payload ${ble_src} is missing from this patch directory."
  [[ -r $SRC_MQTT ]] || fail "payload ${SRC_MQTT} is missing from this patch directory."
  log "ble-config payload selected: $(basename "$ble_src")"

  # --- Back up BEFORE touching anything --------------------------------------
  mkdir -p "$BACKUP_DIR"
  cp -p "$MQTT_JS" "${BACKUP_DIR}/mqtt-client.js"
  cp -p "$BLE_JS"  "${BACKUP_DIR}/ble-config.js"
  log "Backed up prior files to ${BACKUP_DIR}"

  # --- Install ---------------------------------------------------------------
  install -m 0755 -o root -g root "$SRC_MQTT" "$MQTT_JS" \
    || fail "failed to install ${MQTT_JS}. Roll back with: sudo $SELF --rollback"
  log "  installed ${MQTT_JS} ($(mqtt_sha))"

  install -m 0755 -o root -g root "$ble_src" "$BLE_JS" \
    || fail "failed to install ${BLE_JS}. Roll back with: sudo $SELF --rollback"
  log "  installed ${BLE_JS} ($(ble_sha))"

  # --- Verify bytes BEFORE restarting anything -------------------------------
  # A restart is the expensive, disruptive step (it drops in-flight print jobs), so
  # prove the files landed correctly first rather than discovering it afterwards.
  [[ "$(mqtt_sha)" == "$FIXED_MQTT_SHA" ]] || fail \
    "post-install sha mismatch on ${MQTT_JS} (got $(mqtt_sha), want ${FIXED_MQTT_SHA}). Nothing was restarted. Roll back with: sudo $SELF --rollback"
  [[ "$(ble_sha)" == "$ble_expect" ]] || fail \
    "post-install sha mismatch on ${BLE_JS} (got $(ble_sha), want ${ble_expect}). Nothing was restarted. Roll back with: sudo $SELF --rollback"
  log "Byte-level verification passed for both files."

  run_detached_if_ssh __finalize_apply "$v"
}

do_rollback() {
  require_root
  assert_not_template
  start_logging rollback
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"

  log "State before rollback:"
  report_state

  if [[ -r ${BACKUP_DIR}/mqtt-client.js ]]; then
    install -m 0755 -o root -g root "${BACKUP_DIR}/mqtt-client.js" "$MQTT_JS" && log "  restored ${MQTT_JS}"
  else
    log "  WARNING: no backup of mqtt-client.js -- left as it is."
  fi
  if [[ -r ${BACKUP_DIR}/ble-config.js ]]; then
    install -m 0755 -o root -g root "${BACKUP_DIR}/ble-config.js" "$BLE_JS" && log "  restored ${BLE_JS}"
  else
    log "  WARNING: no backup of ble-config.js -- left as it is."
  fi

  # Put the on-card snapshots back, so a rolled-back device is indistinguishable from
  # one that never took this patch.
  if [[ -d ${BACKUP_DIR}/config-shadows ]]; then
    local restored=0 f
    for f in "${BACKUP_DIR}"/config-shadows/shadow-*.json; do
      [[ -e $f ]] || continue
      install -m 0644 -o root -g root "$f" "/usr/local/lib/eatabit/config/$(basename "$f")" \
        && restored=$((restored + 1))
    done
    [[ $restored -gt 0 ]] && log "  restored ${restored} on-card shadow snapshot(s) to /usr/local/lib/eatabit/config"
  fi

  log "State after rollback:"
  report_state
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

This patch REPLACES RUNNING CODE, so it restarts $SERVICE and $BLE_SERVICE.
Restarting $SERVICE drops in-flight print jobs (BUG-049) and drops the ngrok SSH
tunnel (ngrok runs inside it), so over SSH the restart+verify runs detached and
logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
