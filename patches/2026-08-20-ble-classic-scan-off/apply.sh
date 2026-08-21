#!/bin/bash
# Patch: 2026-08-20-ble-classic-scan-off   (BUG-040)
#
# ---------------------------------------------------------------------------
# WHAT THIS PATCH DOES -- and, just as importantly, what it does NOT do
#
# It stops the device performing BR/EDR (Bluetooth "classic") page scan and
# inquiry scan. It does NOT gate, stop, mask, delay or otherwise touch the BLE
# provisioning path. LE advertising and the GATT server run exactly as before,
# permanently, on a provisioned device and an unprovisioned one alike.
#
# THIS MATTERS MORE THAN ANYTHING ELSE IN THIS FILE. BLE is the last-resort way
# into a Pi Zero 2 W: there is no Ethernet, SSH rides the WiFi, and the only
# other recovery is pulling the SD card out of a machine in a customer's
# building. A patch that made BLE conditional -- on NetworkManager state, on a
# dispatcher hook, on a timer -- would introduce a way for a device to become
# unreachable that does not exist today. This patch introduces no such way. The
# device is never less discoverable after it than before it. That property is
# the reason this shape was chosen over the three that BUG-040's planning.md
# proposed, all of which gated the provisioning path.
#
# ---------------------------------------------------------------------------
# WHY BR/EDR SCANNING COSTS ANYTHING
#
# The CYW43438 shares ONE 2.4 GHz front-end and ONE antenna between WiFi and
# Bluetooth, arbitrated by time-division coexistence. Bluetooth radio-on time is
# WiFi airtime taken away. A controlled on-device experiment (ISSUE-064 finding
# 10, run 2026-08-19 with WiFi configuration untouched between arms) measured,
# on the first wireless hop to the gateway:
#
#            avg RTT        worst case      jitter (mdev)
#   BT ON    16.910 ms      102.122 ms      22.363 ms
#   BT OFF    3.223 ms       15.019 ms       2.668 ms
#
# Jitter is the metric that matters: the MQTT client runs with
# with_keep_alive_seconds(30) and a ~3 s ping-response window, and every observed
# disconnect was AWS_ERROR_MQTT_TIMEOUT. One airtime stall past that window tears
# down an otherwise healthy connection.
#
# WHERE THE RADIO-ON TIME ACTUALLY GOES, per the kernel's own constants:
#
#   page scan, FastConnectable = true   INTERLACED, 160 ms interval / 11.25 ms
#                                       window  (hci_write_fast_connectable_sync:
#                                       cp.interval = 0x0100)      ~7% -> ~14%
#                                       once interlacing doubles radio-on time
#   page scan, kernel default           STANDARD, 1.28 s / 11.25 ms
#                                       (def_page_scan_int = 0x0800,
#                                        def_page_scan_window = 0x0012)   ~0.9%
#   inquiry scan while discoverable     1.28 s / 11.25 ms                 ~0.9%
#   LE advertising (bleno default)      100 ms, 3 channels                ~1.1%
#
# So classic scanning is roughly an order of magnitude more radio-on time than
# the LE advertising that provisioning actually needs -- and the product never
# uses classic scanning at all. ble-config.js advertises through
# @abandonware/bleno (LE advertising, LE GATT) and the mobile app discovers it
# with react-native-ble-plx startDeviceScan, which is LE-only and matches on the
# LE advertisement's local name. Nothing in the pairing flow issues a classic
# inquiry.
#
# EXPECTED, NOT PROVEN: this should recover most -- not all -- of the measured
# delta, leaving roughly the LE advertising term behind. The residual is what
# measure.sh exists to quantify. See README.md -> Validation status.
#
# ---------------------------------------------------------------------------
# THE TWO FILES, AND WHY THEY ARE BOTH REQUIRED
#
#   1) /etc/bluetooth/main.conf -- the eatabit block gains ControllerMode = le
#      (removes BR/EDR entirely: no PSCAN, no ISCAN) and flips FastConnectable
#      from true to false.
#
#   2) /etc/systemd/system/bluetooth-poweron.service -- drops the
#      `bluetoothctl discoverable on` ExecStart, which is what actually turned
#      inquiry scan on at every boot.
#
# Installing only (1) leaves a unit that re-asserts discoverability at each boot.
# Installing only (2) leaves the interlaced page scan running. Both, or neither.
#
# CORRECTING A CLAIM IN BUG-040's planning.md: it states that main.conf's
# `Discoverable = true` / `DiscoverableTimeout = 0` are "where permanent ISCAN
# comes from". `Discoverable` is NOT a BlueZ option -- it does not appear in
# bluez 5.79 src/main.conf, and trixie ships 5.79+. Neither are
# `InitiallyPowered`, `Pairable` (the real key is AlwaysPairable) or `[LE]
# Autoconnect` (the real key is Autoconnecttimeout). Four of the twelve keys in
# the shipped block have never done anything. Permanent ISCAN comes from
# `bluetoothctl discoverable on` in the power-on unit; DiscoverableTimeout = 0
# only stops it expiring. The inert keys are dropped here so the file stops
# implying a mechanism it does not have.
#
# ---------------------------------------------------------------------------
# GATING is by CHECKSUM, never by version string, and each surface is gated
# INDEPENDENTLY so a half-applied device is completed rather than refused. An
# unrecognized file is never overwritten, and the refusal PRINTS the observed
# sha256 so an unsampled field device reports its own state in one run.
#
# main.conf is gated on the sha of the EATABIT BLOCK, not of the whole file. The
# whole file is stock-BlueZ-for-that-image plus our appended block, so its sha
# varies with the base image and is not a usable gate. Conveniently,
# stage3/08-ble-config/00-run.sh is byte-identical across ALL FIFTEEN released
# tags (v1.0.1-v1.0.10, v1.1.0-v1.1.4, sha 463f9099...), so there is exactly one
# prior block sha and one prior unit sha to accept, not a matrix.
#
# ble-config.js is NOT modified and therefore NOT gated -- gating on a file you
# do not touch only refuses devices you could have helped. Its sha is recorded
# informationally so the run identifies the device's generation.
#
# ---------------------------------------------------------------------------
# THE mqtt-client TUNNEL. This patch does NOT touch mqtt-client.js or
# mqtt-client.service and never restarts mqtt-client.service, so it does not
# drop the ngrok SSH tunnel (ngrok runs inside that process). ISSUE-064 measured
# that restarting ble-config + bluetooth does NOT drop the tunnel either.
# Nevertheless the restart+verify still runs DETACHED over SSH: the cost is
# nothing and it removes a failure mode in which a dropped session kills the
# verify half-way and leaves the auto-rollback unrun. Remote-session detection
# is carried by hand from the 2026-08-20 rollup -- $SSH_CONNECTION alone is not
# sufficient because sudo's env_reset strips it (BUG-047), and there is no
# shared patch helper to source.
#
# Usage:
#   sudo ./apply.sh              # apply
#        ./apply.sh --check      # DRY RUN, no root needed, changes nothing
#   sudo ./apply.sh --rollback   # restore pre-patch files from backup

set -euo pipefail

PATCH_ID="2026-08-20-ble-classic-scan-off"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Test seam. The main.conf block rewrite is the most trap-laden part of this
# script (the shipped 00-run.sh appends with `cat >>`, so a naive re-run leaves
# two eatabit blocks and three [General] sections), and it is worth being able
# to exercise it against fixtures off-device. EATABIT_PATCH_ROOT is prefixed to
# the system paths; unset -- which is always the case in the field -- it is the
# empty string and these are the real paths.
_R="${EATABIT_PATCH_ROOT:-}"
BT_CONF="${_R}/etc/bluetooth/main.conf"
POWERON_UNIT="${_R}/etc/systemd/system/bluetooth-poweron.service"
BLE_CONFIG_JS="${_R}/usr/local/lib/eatabit/bin/ble-config.js"
BLE_LOG="${_R}/usr/local/lib/eatabit/log/ble-config.log"
VERSION_FILE="${_R}/usr/local/lib/eatabit/version"

PATCH_STATE_DIR="${_R}/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"

BEGIN_MARK="# >>> eatabit BLE configuration -- managed block, do not edit by hand >>>"
END_MARK="# <<< eatabit BLE configuration -- managed block, do not edit by hand <<<"
LEGACY_MARK="# Eatabit BLE Configuration"

FORCE_INLINE=0
FORCE_DETACH=0

# --- Desired end state -------------------------------------------------------
FIXED_CONF_BLOCK_SHA="65f8002b262ef3e47ca99cf79fa9b99a7fa7ae8f29e97a2b3d5669d61e3cf4e3"
FIXED_POWERON_SHA="ee9d76e7d70613478140183e182a4ef6744db863d261c9379150b302ab960749"

# --- Files we are willing to replace ----------------------------------------
# One entry each: 00-run.sh is byte-identical across all 15 released tags, so
# every fielded device that has not been hand-edited carries exactly these.
# The FIELD state is TWO eatabit blocks, not one: stage3/08-ble-config/00-run.sh
# appends one at image-build time and stage2/04-cloud-init appends a second,
# shorter one on first boot. Verified on real v1.0.10, v1.1.0 and v1.1.4 units --
# byte-identical on all three, three [General] sections each. The extraction below
# runs from the FIRST marker to EOF, so it spans both blocks and the rewrite
# consolidates them into one.
ACCEPTED_PRIOR_CONF_BLOCK_SHAS=(
  "792e8b9941f6d41c62c575d185e2defd1a1a714cb614f392f7427137cfa76f27" # FIELD state: stage3 block + cloud-init block (v1.0.10, v1.1.0, v1.1.4 confirmed)
  "a3209a4c006c98600cb937a267485150e45b70469d4dfd0e91343a9fdec93cc6" # stage3 block alone -- an image whose cloud-init append was already removed
)
ACCEPTED_PRIOR_POWERON_SHAS=(
  "183052ae66f8dd54ebe917b652fe62ab888141aed10d1a453fb8fe87bc2adbe0" # stock unit,  v1.0.1-v1.0.10 / v1.1.0-v1.1.4
)

# Informational only -- ble-config.js is NOT modified by this patch. Five
# distinct generations exist across the 15 tags; all are fine.
declare -a KNOWN_JS_SHAS=(
  "eac92d783265578b667dd7a149b44208fa8e052c716e76e742e319790f8b6699:v1.0.1,v1.0.2"
  "4654037f1544f99ed2db618b8806f3b9f4b4144d3191fd7b6123ed96e6a167ca:v1.0.3"
  "d70edf02fa4b1adb0b294e6215204ed1a3fe163656171d8860d93a7d9c1867b2:v1.0.4,v1.0.5,v1.0.6,v1.1.0"
  "ecbf9a06f9b699d7e5296c8087fec816d111c6792ab67ae2d62752947b0965a0:v1.0.7,v1.0.8,v1.1.1,v1.1.2"
  "2cda3a88dc7ea08a0c8875253d4d36eca3b95b12ef81010416b202a8b5235740:v1.0.9,v1.0.10,v1.1.3,v1.1.4"
)

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || fail "must be run as root (use: sudo $0)"; }

current_version() {
  [[ -f $VERSION_FILE ]] || fail "$VERSION_FILE not found -- is this an eatabit Pi image?"
  tr -d '[:space:]' < "$VERSION_FILE"
}

file_sha() { sha256sum "$1" | awk '{print $1}'; }
# Shas text the way file_sha shas a file: with exactly one trailing newline.
# $(...) strips trailing newlines, so `printf '%s'` here would make an extracted
# block hash differently from the identical bytes on disk.
string_sha() { printf '%s\n' "$1" | sha256sum | awk '{print $1}'; }

# Drop trailing blank lines, so repeated rewrites cannot accrete blank lines
# between the stock content and our block.
strip_trailing_blanks() {
  awk '{a[NR]=$0} END{n=NR; while (n>0 && a[n]=="") n--; for(i=1;i<=n;i++) print a[i]}'
}

# --- main.conf block handling ------------------------------------------------
# Two forms exist in the field: the LEGACY form that 00-run.sh appended with
# `cat >>` (starts at "# Eatabit BLE Configuration" and runs to EOF, with no end
# marker at all), and the MARKED form this patch installs. Extraction and
# replacement must handle both, and replacement must never leave two blocks --
# re-running the original `cat >>` is exactly how a device ends up with three
# [General] sections and a config nobody can reason about.
conf_block_form() {
  if grep -qF "$BEGIN_MARK" "$BT_CONF" 2>/dev/null; then echo marked
  elif grep -qxF "$LEGACY_MARK" "$BT_CONF" 2>/dev/null; then echo legacy
  else echo none; fi
}

extract_conf_block() {
  case "$(conf_block_form)" in
    marked) awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
              'index($0,b){f=1} f{print} index($0,e){exit}' "$BT_CONF" ;;
    legacy) awk -v m="$LEGACY_MARK" '$0==m{f=1} f' "$BT_CONF" ;;
    *)      : ;;
  esac
}

# Emit main.conf with the eatabit block removed. Everything before the block is
# preserved byte-for-byte -- the stock portion differs per base image and is not
# ours to normalise.
conf_without_block() {
  case "$(conf_block_form)" in
    marked) awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
              'index($0,b){f=1} !f{print} f && index($0,e){f=0; next}' "$BT_CONF" ;;
    legacy) awk -v m="$LEGACY_MARK" '$0==m{exit} {print}' "$BT_CONF" ;;
    *)      cat "$BT_CONF" ;;
  esac
}

# Replace whatever eatabit block is present -- legacy or marked -- with the one
# in $1, IN PLACE. Never appends a second block. Then verifies on this very
# device rather than trusting the logic: the block must read back at exactly the
# fixed sha, and the file must contain exactly ONE [General] section. Returns
# non-zero on either failure so the caller can restore the backup.
install_conf_block() {
  local src=$1 tmp readback generals before_generals
  log "Rewriting the eatabit block in $BT_CONF (in place -- never appending a second)"
  before_generals="$(grep -c '^\[General\]' "$BT_CONF" || true)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/${PATCH_ID}-main.conf.XXXXXX")"
  { conf_without_block | strip_trailing_blanks; printf '\n'; cat "$src"; } > "$tmp"
  install -m 0644 "$tmp" "$BT_CONF"
  rm -f "$tmp"

  readback="$(string_sha "$(extract_conf_block)")"
  if [[ $readback != "$FIXED_CONF_BLOCK_SHA" ]]; then
    log "Read-back of the rewritten block does not match the fixed sha:"
    log "  expected $FIXED_CONF_BLOCK_SHA"
    log "  observed $readback"
    return 1
  fi

  # Exactly one block, opened and closed once.
  local begins ends
  begins="$(grep -cF -- "$BEGIN_MARK" "$BT_CONF" || true)"
  ends="$(grep -cF -- "$END_MARK" "$BT_CONF" || true)"
  if [[ $begins -ne 1 || $ends -ne 1 ]]; then
    log "$BT_CONF has $begins block-begin and $ends block-end markers; expected exactly 1 of each."
    return 1
  fi

  # The [General] count must never GO UP. Asserting an absolute number would be
  # wrong -- the stock BlueZ file brings its own and differs per base image -- and
  # asserting it is unchanged would be wrong too: a field device carries TWO
  # eatabit blocks (image build + cloud-init) and this rewrite deliberately
  # consolidates them into one, so the count legitimately DROPS from 3 to 2. What
  # must never happen is an increase, which is exactly what the `cat >>` this
  # patch replaces would do.
  generals="$(grep -c '^\[General\]' "$BT_CONF" || true)"
  if [[ $generals -gt $before_generals ]]; then
    log "$BT_CONF went from $before_generals to $generals [General] sections; a rewrite must never add one."
    return 1
  fi
  if [[ $generals -lt 1 ]]; then
    log "$BT_CONF has no [General] section after the rewrite."
    return 1
  fi

  log "main.conf: exactly one eatabit block, [General] sections ${before_generals} -> ${generals}, sha matches."
  return 0
}

# Anything non-blank AFTER our end marker. This matters because BlueZ parses the
# whole file with GKeyFile semantics, where a later assignment of the same key
# wins. Our block is deliberately written LAST, which is what makes it override
# whatever the stock file said -- but it also means a hand-edit appended after
# it would override US, silently, and could put FastConnectable or
# ControllerMode straight back. Content BEFORE the block is harmless for the
# same reason: we win. Content after it is not, so it is a refusal.
conf_trailing_after_block() {
  [[ "$(conf_block_form)" == marked ]] || return 0
  awk -v e="$END_MARK" 'f && NF {print} index($0,e){f=1}' "$BT_CONF"
}

refuse_unrecognized() {
  local what=$1 observed=$2; shift 2
  local candidates=("$@") a
  {
    printf '\n[ERROR] Refusing to overwrite an unrecognized %s.\n' "$what"
    printf '  observed sha256: %s\n' "$observed"
    printf '  device version:  %s\n' "$(current_version 2>/dev/null || echo unknown)"
    printf '  checked against:\n'
    for a in "${candidates[@]}"; do printf '    %s\n' "$a"; done
    printf '\n  Every released tag (v1.0.1-v1.0.10, v1.1.0-v1.1.4) ships byte-identical\n'
    printf '  files here, so an unrecognized one means this device was hand-edited or\n'
    printf '  carries a build outside the released set. Report the observed sha256.\n'
    printf '  NOTHING HAS BEEN MODIFIED.\n\n'
  } >&2
  exit 1
}

unit_check() {
  local unit=$1 tmp rc=0
  command -v systemd-analyze >/dev/null 2>&1 || { log "WARNING: systemd-analyze not found, skipping unit verify"; return 0; }
  tmp="/run/${PATCH_ID}-candidate.service"
  cp "$unit" "$tmp"
  systemd-analyze verify "$tmp" || rc=$?
  rm -f "$tmp"
  return $rc
}

is_remote_session() {
  [[ $FORCE_INLINE -eq 1 ]] && return 1
  [[ $FORCE_DETACH -eq 1 ]] && return 0
  [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] && return 0
  local pid=${PPID:-0} comm guard=0
  while [[ $pid -gt 1 && $guard -lt 32 ]]; do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [[ $comm == sshd ]] && return 0
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
    log "Over SSH: running '$internal_cmd' DETACHED so a dropped session cannot"
    log "interrupt the verify or leave the auto-rollback unrun. Logging to:"
    log "  $LOG"
    log "This patch does NOT restart mqtt-client.service, so the ngrok tunnel"
    log "should survive; the detach is belt-and-braces. After it finishes:"
    log "  cat $LOG"
    if command -v setsid >/dev/null 2>&1; then
      setsid "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    else
      nohup  "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    fi
    disown 2>/dev/null || true
    exit 0
  fi
  "$internal_cmd" "$@"
}

restore_backup() {
  [[ -f "$BACKUP_DIR/main.conf" ]]                 && install -m 0644 "$BACKUP_DIR/main.conf" "$BT_CONF"
  [[ -f "$BACKUP_DIR/bluetooth-poweron.service" ]] && install -m 0644 "$BACKUP_DIR/bluetooth-poweron.service" "$POWERON_UNIT"
  systemctl daemon-reload || true
  return 0
}

bounce_bluetooth() {
  # Deliberately NOT mqtt-client. bluetooth-poweron is oneshot with
  # RemainAfterExit=yes, so it must be stopped before it will run again.
  systemctl daemon-reload
  systemctl restart bluetooth.service || true
  systemctl stop    bluetooth-poweron.service || true
  systemctl start   bluetooth-poweron.service || true
  systemctl restart ble-config.service || true
}

# -----------------------------------------------------------------------------
# THE RECOVERY SELF-CHECK
# -----------------------------------------------------------------------------
# BUG-040's acceptance criterion A9 requires the patch to prove, before it exits
# SUCCESS, that the device is still re-provisionable -- and to roll ITSELF back
# if it cannot. The rollout stages catch a bad patch; only the device can catch a
# device-specific failure (a BlueZ that behaves differently on that image, an
# adapter that will not come back LE-only, a bleno that fails to re-advertise).
#
# WHAT THIS PROVES: that after the change the adapter is up, BR/EDR scanning is
# gone, ble-config is running, and it has SUCCESSFULLY RE-ADVERTISED ITS GATT
# SERVICE since the restart. That last item is the recovery path: LE advertising
# is how the mobile app finds this device, and this patch does not make it
# conditional on anything, so if it is live now it is live after a WiFi loss too.
#
# WHAT IT CANNOT PROVE: that a phone completes a pairing. Nothing running on the
# device can prove that. That is step 8 of the prompt and it needs the app.
# ANY failure here restores both files and bounces Bluetooth back.
verify_recovery() {
  local since=$1 problems=()

  systemctl is-active --quiet ble-config.service || problems+=("ble-config.service is not active")
  systemctl is-active --quiet bluetooth.service  || problems+=("bluetooth.service is not active")

  local hci=""
  if command -v hciconfig >/dev/null 2>&1; then
    hci="$(hciconfig -a hci0 2>/dev/null || true)"
    [[ -n $hci ]] || problems+=("hciconfig reports no hci0")
    grep -q 'UP RUNNING' <<<"$hci" || problems+=("hci0 is not UP RUNNING")
    # The point of the patch. If these are still set the change did not take,
    # and the fix would be indistinguishable from a no-op on the radio.
    grep -qE 'PSCAN|ISCAN' <<<"$hci" && problems+=("hci0 still shows PSCAN/ISCAN -- BR/EDR scanning did NOT stop")
  else
    problems+=("hciconfig not present -- cannot confirm scan state")
  fi

  # Advertising must have come back AFTER the restart, not merely at some point
  # in the past. Check the journal window and the app's own log file.
  local adv=0 gatt=0 j
  j="$(journalctl -u ble-config.service --since "$since" --no-pager 2>/dev/null || true)"
  grep -q 'advertising started successfully' <<<"${j,,}" && adv=1
  grep -q 'gatt services configured successfully' <<<"${j,,}" && gatt=1
  if [[ $adv -eq 0 || $gatt -eq 0 ]] && [[ -f $BLE_LOG ]]; then
    local t; t="$(tail -n 200 "$BLE_LOG" 2>/dev/null || true)"
    grep -q 'advertising started successfully' <<<"${t,,}" && adv=1
    grep -q 'gatt services configured successfully' <<<"${t,,}" && gatt=1
  fi
  (( adv ))  || problems+=("no evidence ble-config restarted LE advertising")
  (( gatt )) || problems+=("no evidence the GATT service was re-registered")

  if (( ${#problems[@]} )); then
    log "RECOVERY SELF-CHECK FAILED:"
    printf '  - %s\n' "${problems[@]}"
    [[ -n $hci ]] && { log "hciconfig -a:"; printf '%s\n' "$hci"; }
    log "Recent ble-config journal:"
    journalctl -u ble-config.service -n 40 --no-pager 2>/dev/null || true
    return 1
  fi

  log "Recovery self-check PASSED:"
  log "  ble-config.service active, bluetooth.service active"
  log "  hci0 UP RUNNING with no PSCAN/ISCAN"
  log "  LE advertising restarted and GATT service re-registered since the bounce"
  return 0
}

# -----------------------------------------------------------------------------
# Finalize (restart + verify + auto-rollback). Inline, or re-exec'd detached.
# -----------------------------------------------------------------------------
__finalize_apply() {
  require_root
  local v=$1
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  mkdir -p "$PATCH_STATE_DIR"

  log "Bouncing bluetooth, bluetooth-poweron and ble-config (NOT mqtt-client)..."
  bounce_bluetooth
  sleep 10

  if ! verify_recovery "$since"; then
    log "Restoring originals and bouncing Bluetooth back..."
    restore_backup
    bounce_bluetooth
    sleep 5
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "recovery self-check failed; originals restored. The device is back to its pre-patch state."
  fi

  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log ""
  log "Patch applied successfully."
  log "  Originals backed up at: $BACKUP_DIR"
  log "  Rollback command:       sudo $0 --rollback"
  log ""
  log "STILL REQUIRED, and NOT provable from the device:"
  log "  1) Measure the radio. Run measure.sh and compare first-hop mdev against"
  log "     the 2.668 ms BT-off figure from ISSUE-064 finding 10. A log line"
  log "     saying scanning stopped is evidence a code path ran, nothing more."
  log "  2) Pair end to end from iot-expo: SSID, Password, Status notify, Apply,"
  log "     and the chunked Scan characteristic."
  log "  3) Take the AP away and confirm the device is still discoverable and"
  log "     re-provisionable. This patch does not gate BLE on anything, so it"
  log "     should be unchanged from before -- confirm that, do not assume it."
}

__finalize_rollback() {
  require_root
  bounce_bluetooth
  rm -f "$MARKER_FILE"
  sleep 5
  log "Rollback complete."
  log "  ble-config.service: $(systemctl is-active ble-config.service || true)"
  command -v hciconfig >/dev/null 2>&1 && hciconfig -a hci0 2>/dev/null | head -4 || true
}

# -----------------------------------------------------------------------------
do_rollback() {
  require_root
  log "Rolling back patch ${PATCH_ID}..."
  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  [[ -f "$BACKUP_DIR/main.conf" ]]                 || fail "no backup of main.conf in $BACKUP_DIR"
  [[ -f "$BACKUP_DIR/bluetooth-poweron.service" ]] || fail "no backup of bluetooth-poweron.service in $BACKUP_DIR"
  install -m 0644 "$BACKUP_DIR/main.conf"                 "$BT_CONF"
  install -m 0644 "$BACKUP_DIR/bluetooth-poweron.service" "$POWERON_UNIT"
  log "Restored $BT_CONF and $POWERON_UNIT"
  run_detached_if_ssh __finalize_rollback
}

# -----------------------------------------------------------------------------
# Check (dry run). No root needed; reads only.
# Exit codes: 0 = already patched   1 = would refuse   2 = would apply
# -----------------------------------------------------------------------------
do_check() {
  local v block block_sha poweron_sha block_state poweron_state prior rc js_sha entry

  v="$(current_version 2>/dev/null || echo unknown)"
  [[ -f $BT_CONF ]]      || fail "$BT_CONF not found."
  [[ -f $POWERON_UNIT ]] || fail "$POWERON_UNIT not found."

  block="$(extract_conf_block)"
  block_sha="$(string_sha "$block")"
  poweron_sha="$(file_sha "$POWERON_UNIT")"

  local trailing; trailing="$(conf_trailing_after_block)"

  block_state=refuse
  if [[ -n $trailing ]]; then
    block_state=trailing
  elif [[ -z $block ]]; then
    block_state=absent
  elif [[ $block_sha == "$FIXED_CONF_BLOCK_SHA" ]]; then
    block_state=current
  else
    for prior in "${ACCEPTED_PRIOR_CONF_BLOCK_SHAS[@]}"; do [[ $block_sha == "$prior" ]] && block_state=upgrade; done
  fi

  poweron_state=refuse
  if [[ $poweron_sha == "$FIXED_POWERON_SHA" ]]; then
    poweron_state=current
  else
    for prior in "${ACCEPTED_PRIOR_POWERON_SHAS[@]}"; do [[ $poweron_sha == "$prior" ]] && poweron_state=upgrade; done
  fi

  printf 'patch               %s\n' "$PATCH_ID"
  printf 'version             %s\n' "$v"
  printf 'main.conf block     form=%-6s sha256=%s  [%s]\n' "$(conf_block_form)" "$block_sha" "$block_state"
  printf 'bluetooth-poweron   sha256=%s  [%s]\n' "$poweron_sha" "$poweron_state"

  if [[ -f $BLE_CONFIG_JS ]]; then
    js_sha="$(file_sha "$BLE_CONFIG_JS")"
    local gen="UNRECOGNIZED (not modified by this patch; report it)"
    for entry in "${KNOWN_JS_SHAS[@]}"; do
      [[ $js_sha == "${entry%%:*}" ]] && gen="${entry##*:}"
    done
    printf 'ble-config.js       sha256=%s  [not modified; %s]\n' "$js_sha" "$gen"
  fi

  if command -v hciconfig >/dev/null 2>&1; then
    printf 'hci0 flags          %s\n' "$(hciconfig hci0 2>/dev/null | awk '/UP|DOWN/{$1=$1;print;exit}' || echo unknown)"
  fi

  if [[ $block_state == trailing ]]; then
    printf 'main.conf trailing  %s\n' "$(printf '%s' "$trailing" | tr '\n' ';')"
    printf 'RESULT              WOULD REFUSE -- content after the managed block would override it\n'
    rc=1
  elif [[ $block_state == refuse || $poweron_state == refuse ]]; then
    printf 'RESULT              WOULD REFUSE -- unrecognized file; nothing would be modified\n'
    rc=1
  elif [[ $block_state == current && $poweron_state == current ]]; then
    printf 'RESULT              NO-OP -- already patched\n'
    rc=0
  else
    printf 'RESULT              WOULD APPLY -- rewrites the main.conf eatabit block and/or the\n'
    printf '                    power-on unit, then bounces bluetooth + ble-config.\n'
    printf '                    mqtt-client is NOT touched and NOT restarted.\n'
    rc=2
  fi
  return $rc
}

# -----------------------------------------------------------------------------
do_apply() {
  require_root
  local v block block_sha poweron_sha need_block=0 need_poweron=0 is_accepted prior

  v="$(current_version)"
  log "Detected device version: $v"

  [[ -f $BT_CONF ]]      || fail "$BT_CONF not found."
  [[ -f $POWERON_UNIT ]] || fail "$POWERON_UNIT not found."

  local src_conf="$SCRIPT_DIR/main.conf.eatabit"
  local src_unit="$SCRIPT_DIR/bluetooth-poweron.service"
  [[ -f $src_conf ]] || fail "missing $src_conf -- patch directory is incomplete"
  [[ -f $src_unit ]] || fail "missing $src_unit -- patch directory is incomplete"
  [[ "$(file_sha "$src_conf")" == "$FIXED_CONF_BLOCK_SHA" ]] || fail "bundled main.conf.eatabit sha mismatch -- patch directory is corrupt."
  [[ "$(file_sha "$src_unit")" == "$FIXED_POWERON_SHA" ]]    || fail "bundled bluetooth-poweron.service sha mismatch -- patch directory is corrupt."

  local trailing; trailing="$(conf_trailing_after_block)"
  if [[ -n $trailing ]]; then
    { printf '\n[ERROR] %s has content AFTER the eatabit managed block:\n\n' "$BT_CONF"
      printf '%s\n' "$trailing" | sed 's/^/    /'
      printf '\n  BlueZ takes the LAST assignment of a key, so anything here overrides the\n'
      printf '  patch -- it could put FastConnectable or ControllerMode straight back and\n'
      printf '  the fix would look applied while changing nothing on the radio.\n'
      printf '  Remove it or fold it into the managed block, then re-run.\n'
      printf '  NOTHING HAS BEEN MODIFIED.\n\n'; } >&2
    exit 1
  fi

  block="$(extract_conf_block)"
  block_sha="$(string_sha "$block")"
  poweron_sha="$(file_sha "$POWERON_UNIT")"

  if [[ $block_sha == "$FIXED_CONF_BLOCK_SHA" && $poweron_sha == "$FIXED_POWERON_SHA" ]]; then
    log "main.conf block and bluetooth-poweron.service already contain the fix. Nothing to do."
    mkdir -p "$PATCH_STATE_DIR"
    [[ -f $MARKER_FILE ]] || printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
    exit 0
  fi

  if [[ $block_sha != "$FIXED_CONF_BLOCK_SHA" ]]; then
    if [[ -z $block ]]; then
      # No eatabit block at all. Not a shape any released tag produces, so do
      # not silently invent one -- that would be writing config to a device
      # whose Bluetooth setup we do not recognize.
      fail "$BT_CONF contains no eatabit block (neither the marked nor the legacy form). This is not a shape any released tag produces; refusing to guess. Nothing modified."
    fi
    is_accepted=0
    for prior in "${ACCEPTED_PRIOR_CONF_BLOCK_SHAS[@]}"; do [[ $block_sha == "$prior" ]] && is_accepted=1; done
    (( is_accepted )) || refuse_unrecognized "eatabit block in $BT_CONF" "$block_sha" \
        "${ACCEPTED_PRIOR_CONF_BLOCK_SHAS[@]}" "$FIXED_CONF_BLOCK_SHA"
    need_block=1
  else
    log "main.conf eatabit block already at the fixed sha."
  fi

  if [[ $poweron_sha != "$FIXED_POWERON_SHA" ]]; then
    is_accepted=0
    for prior in "${ACCEPTED_PRIOR_POWERON_SHAS[@]}"; do [[ $poweron_sha == "$prior" ]] && is_accepted=1; done
    (( is_accepted )) || refuse_unrecognized "$POWERON_UNIT" "$poweron_sha" \
        "${ACCEPTED_PRIOR_POWERON_SHAS[@]}" "$FIXED_POWERON_SHA"
    need_poweron=1
  else
    log "bluetooth-poweron.service already at the fixed sha."
  fi

  # Verify the candidate unit BEFORE installing anything. A unit that will not
  # parse means a Bluetooth stack that does not come up, on a device whose only
  # other way in is the SD card.
  if (( need_poweron )); then
    unit_check "$src_unit" || fail "systemd-analyze verify rejected the bundled unit -- refusing to install it."
    log "systemd-analyze verify: bundled unit is clean."
  fi

  log "Backing up originals to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$BACKUP_DIR/main.conf" ]]                 || cp -p "$BT_CONF"      "$BACKUP_DIR/main.conf"
  [[ -f "$BACKUP_DIR/bluetooth-poweron.service" ]] || cp -p "$POWERON_UNIT" "$BACKUP_DIR/bluetooth-poweron.service"

  if (( need_block )); then
    install_conf_block "$src_conf" || { restore_backup; fail "main.conf rewrite failed verification; original restored."; }
  fi

  if (( need_poweron )); then
    log "Installing fixed bluetooth-poweron.service"
    install -m 0644 "$src_unit" "$POWERON_UNIT"
  fi

  run_detached_if_ssh __finalize_apply "$v"
}

# -----------------------------------------------------------------------------
# Self-test. Exercises the main.conf block rewrite against fixtures in a temp
# root, with no device and no root. This is what makes BUG-040 acceptance
# criterion A8 -- "idempotent over main.conf; run it twice and there are still
# exactly two [General] sections, not three" -- checkable before the patch ever
# reaches hardware. (Two in the shipped layout means stock + ours; after this
# patch normalises the file there is exactly ONE, which is strictly better and
# is what the assertions below require.)
# -----------------------------------------------------------------------------
do_selftest() {
  local root pass=0 failn=0
  root="$(mktemp -d "${TMPDIR:-/tmp}/${PATCH_ID}-selftest.XXXXXX")"
  trap 'rm -rf "$root"' RETURN

  ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
  bad()  { printf '  FAIL  %s\n' "$1"; failn=$((failn+1)); }
  check(){ if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

  mkdir -p "$root/etc/bluetooth"
  # A stand-in for the stock BlueZ file. Its exact contents do not matter --
  # what matters is that the rewrite preserves them byte-for-byte, because they
  # differ per base image and are not ours to normalise.
  cat > "$root/etc/bluetooth/main.conf" <<'STOCK'
[General]
# stock BlueZ content, varies by base image
Name = BlueZ
#DiscoverableTimeout = 180

[Policy]
AutoEnable=true
STOCK
  cp "$root/etc/bluetooth/main.conf" "$root/stock.fixture"

  # Reproduce exactly what stage3/08-ble-config/00-run.sh does: append with
  # `cat >>`, producing the legacy two-[General] shape every fielded device has.
  cat >> "$root/etc/bluetooth/main.conf" <<'LEGACY'

# Eatabit BLE Configuration
[General]
InitiallyPowered = true
Discoverable = true
DiscoverableTimeout = 0
PairableTimeout = 0
Pairable = false
FastConnectable = true
Privacy = device

[LE]
MinConnectionInterval = 7
MaxConnectionInterval = 9
ConnectionLatency = 0
ConnectionSupervisionTimeout = 100
Autoconnect = true
LEGACY

  # The SECOND block, appended by stage2/04-cloud-init on first boot. This is the
  # real field shape -- confirmed byte-identical on v1.0.10, v1.1.0 and v1.1.4
  # units -- and it is what a repo-only derivation of the "prior" sha misses.
  cat >> "$root/etc/bluetooth/main.conf" <<'CLOUDINIT'

# Eatabit BLE Configuration
[General]
InitiallyPowered = true
DiscoverableTimeout = 0
PairableTimeout = 0
Pairable = false
CLOUDINIT

  printf 'Self-test: main.conf block rewrite\n'
  export EATABIT_PATCH_ROOT="$root"
  _R="$root"; BT_CONF="$root/etc/bluetooth/main.conf"

  check "field shape: 2 eatabit blocks" "$(grep -c '^# Eatabit BLE Configuration' "$BT_CONF")" "2"
  check "field shape: 3 [General]"      "$(grep -c '^\[General\]' "$BT_CONF")" "3"
  check "legacy form detected"        "$(conf_block_form)" "legacy"
  check "field block sha recognized (spans BOTH blocks)" "$(string_sha "$(extract_conf_block)")" "${ACCEPTED_PRIOR_CONF_BLOCK_SHAS[0]}"

  # Pass 1: legacy -> marked
  if install_conf_block "$SCRIPT_DIR/main.conf.eatabit" >/dev/null; then ok "pass 1 rewrite"; else bad "pass 1 rewrite"; fi
  check "pass 1 form"          "$(conf_block_form)" "marked"
  check "pass 1 block sha"     "$(string_sha "$(extract_conf_block)")" "$FIXED_CONF_BLOCK_SHA"
  check "pass 1 consolidates 3 [General] -> 2" "$(grep -c '^\[General\]' "$BT_CONF")" "2"
  check "pass 1 leaves ONE eatabit block"      "$(grep -cF -- "$BEGIN_MARK" "$BT_CONF")" "1"
  check "pass 1 legacy marker fully gone"      "$(grep -c '^# Eatabit BLE Configuration' "$BT_CONF" || true)" "0"
  check "pass 1 no ISCAN key"  "$(grep -c '^Discoverable = true' "$BT_CONF" || true)" "0"
  check "pass 1 FastConnectable off" "$(grep -c '^FastConnectable = false' "$BT_CONF")" "1"
  check "pass 1 ControllerMode le"   "$(grep -c '^ControllerMode = le' "$BT_CONF")" "1"
  # The stock portion -- everything before our block -- must survive byte-for-byte.
  # It differs per base image and is not ours to normalise.
  check "pass 1 stock portion preserved byte-for-byte" \
    "$(awk -v b="$BEGIN_MARK" 'index($0,b){exit} {print}' "$BT_CONF" | strip_trailing_blanks | sha256sum | awk '{print $1}')" \
    "$(strip_trailing_blanks < "$root/stock.fixture" | sha256sum | awk '{print $1}')"

  # Pass 2: marked -> marked. THE trap: a naive `cat >>` would land a third
  # [General] here. The count must not move.
  if install_conf_block "$SCRIPT_DIR/main.conf.eatabit" >/dev/null; then ok "pass 2 rewrite"; else bad "pass 2 rewrite"; fi
  check "pass 2 block sha"     "$(string_sha "$(extract_conf_block)")" "$FIXED_CONF_BLOCK_SHA"
  check "pass 2 STILL 2 [General] (A8: not three)" "$(grep -c '^\[General\]' "$BT_CONF")" "2"
  check "pass 2 exactly one eatabit block"  "$(grep -cF -- "$BEGIN_MARK" "$BT_CONF")" "1"

  # Pass 3: idempotent over a third run.
  install_conf_block "$SCRIPT_DIR/main.conf.eatabit" >/dev/null || true
  check "pass 3 STILL 2 [General]" "$(grep -c '^\[General\]' "$BT_CONF")" "2"
  check "pass 3 exactly one eatabit block" "$(grep -cF -- "$BEGIN_MARK" "$BT_CONF")" "1"

  # Content appended AFTER our end marker must be refused: BlueZ takes the last
  # assignment, so it would silently override the patch.
  install_conf_block "$SCRIPT_DIR/main.conf.eatabit" >/dev/null || true
  check "clean block has no trailing content" "$(conf_trailing_after_block)" ""
  printf '\n[General]\nFastConnectable = true\n' >> "$BT_CONF"
  check "trailing override IS detected" "$(conf_trailing_after_block | tr -d ' \n')" "[General]FastConnectable=true"

  # A file with no eatabit block at all must be detected, not guessed at.
  printf '[General]\nName = BlueZ\n' > "$root/etc/bluetooth/main.conf"
  check "absent form detected" "$(conf_block_form)" "none"
  check "absent block extracts empty" "$(extract_conf_block)" ""

  # A hand-edited block must NOT be recognized as a prior.
  cat > "$root/etc/bluetooth/main.conf" <<'HAND'
[General]
Name = BlueZ

# Eatabit BLE Configuration
[General]
FastConnectable = true
# someone edited this by hand
HAND
  local hand_sha; hand_sha="$(string_sha "$(extract_conf_block)")"
  local recognized=0 pr
  for pr in "${ACCEPTED_PRIOR_CONF_BLOCK_SHAS[@]}" "$FIXED_CONF_BLOCK_SHA"; do
    [[ $hand_sha == "$pr" ]] && recognized=1
  done
  check "hand-edited block is NOT accepted" "$recognized" "0"

  # The bundled payloads must match the constants compiled into this script.
  check "bundled main.conf.eatabit sha"       "$(sha256sum "$SCRIPT_DIR/main.conf.eatabit" | awk '{print $1}')" "$FIXED_CONF_BLOCK_SHA"
  check "bundled bluetooth-poweron.service sha" "$(sha256sum "$SCRIPT_DIR/bluetooth-poweron.service" | awk '{print $1}')" "$FIXED_POWERON_SHA"
  check "bundled unit drops 'discoverable on'" "$(grep -c 'ExecStart=.*discoverable on' "$SCRIPT_DIR/bluetooth-poweron.service" || true)" "0"
  check "bundled unit keeps 'power on'"        "$(grep -c 'ExecStart=.*bluetoothctl power on' "$SCRIPT_DIR/bluetooth-poweron.service")" "1"

  printf '\n%d passed, %d failed\n' "$pass" "$failn"
  [[ $failn -eq 0 ]]
}

# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inline) FORCE_INLINE=1; shift ;;
    --detach) FORCE_DETACH=1; shift ;;
    *) break ;;
  esac
done

case "${1:-apply}" in
  apply)               do_apply ;;
  --check|check)       do_check ;;
  --selftest)          do_selftest ;;
  --rollback)          do_rollback ;;
  __finalize_apply)    __finalize_apply "${2:?missing version}" ;;
  __finalize_rollback) __finalize_rollback ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--inline|--detach] [apply|--check|--rollback]
  apply       (default) apply the patch
  --check     DRY RUN -- report what apply would do and change nothing. Needs no
              root. Exit 0 = already patched, 1 = would refuse, 2 = would apply.
  --rollback  restore the pre-patch main.conf and bluetooth-poweron.service
  --selftest  exercise the main.conf block rewrite against fixtures in a temp
              dir. No device, no root, changes nothing outside that temp dir.
              This is what makes the idempotency guarantee checkable before the
              patch reaches hardware.
  --inline    force restart+verify inline (local console / testing)
  --detach    force restart+verify detached

Stops BR/EDR page scan and inquiry scan. Does NOT gate, stop or delay the BLE
provisioning path -- LE advertising and the GATT server are untouched, so the
device is never less discoverable after this patch than before it.

Does not modify or restart mqtt-client, so it does not drop the ngrok tunnel.

Before it exits SUCCESS it runs a recovery self-check (adapter up, no
PSCAN/ISCAN, LE advertising and GATT re-registered since the bounce) and
AUTO-ROLLS-BACK if that fails.
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
