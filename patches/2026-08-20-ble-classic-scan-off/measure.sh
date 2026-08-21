#!/bin/bash
# measure.sh -- BUG-040 radio measurement harness
#
# The claim under test is about the RADIO, so the measurement has to be about the
# radio. A log line saying "scanning disabled" is evidence that a code path ran,
# nothing more. This script measures first-hop latency and jitter to the default
# gateway under several Bluetooth radio states and prints a comparison table.
#
# It answers three questions BUG-040 left open, none of which can be settled by
# reading code:
#
#   1. How much of the measured penalty is BR/EDR classic scanning, and how much
#      is the LE advertising that provisioning actually needs? If it is mostly
#      LE, this patch attacks the wrong layer and the answer has to change --
#      STOP AND RAISE IT rather than shipping.
#   2. Is FastConnectable = true worth reverting on its own?
#   3. Does the fix actually reach the radio, or does BlueZ's config parse take
#      an earlier duplicate key and leave PSCAN/ISCAN exactly where they were?
#
# THE REFERENCE NUMBERS, from ISSUE-064 finding 10 (2026-08-19, WiFi untouched
# between arms). First hop to the gateway:
#
#            avg RTT        worst case      jitter (mdev)
#   BT ON    16.910 ms      102.122 ms      22.363 ms
#   BT OFF    3.223 ms       15.019 ms       2.668 ms
#
# mdev 2.668 ms is the target for the patched arm. Jitter is the metric that
# must be reported: it is what maps onto the observed failure, because every
# ISSUE-064 disconnect was AWS_ERROR_MQTT_TIMEOUT against a ~3 s ping window.
#
# ---------------------------------------------------------------------------
# SAFETY. This script NEVER touches WiFi -- not the interface, not NetworkManager,
# not a connection profile. It changes only Bluetooth radio state, and it restores
# that state unconditionally on EVERY exit path, including Ctrl-C, SIGTERM and an
# unexpected error, via a trap installed before the first change. The same
# discipline as the finding-10 experiment, which ran live on a customer device
# and restored it cleanly.
#
# Restarting ble-config + bluetooth was measured NOT to drop the ngrok tunnel,
# which is what makes this safe to run over remote SSH. It does not touch
# mqtt-client, so the tunnel is not at risk from this script.
#
# Usage:
#   sudo ./measure.sh                 # all arms, 60 packets each
#   sudo ./measure.sh -c 120          # 120 packets per arm
#   sudo ./measure.sh -a asis,classic # only the named arms
#   sudo ./measure.sh --list          # describe the arms and exit

set -uo pipefail

COUNT=60
ROUNDS=1
ARMS="asis,classic,fastconn,alloff"
GW=""

usage() {
  cat <<EOF
Usage: sudo $0 [-c COUNT] [-r ROUNDS] [-a ARMS] [-g GATEWAY] [--list]

  -c COUNT    packets per arm per round (default 60; finding 10 used 60)
  -r ROUNDS   repeat the whole arm sequence N times, INTERLEAVED (default 1)

              Use -r 3 or more for any result you intend to act on. Arms run
              sequentially, so a single round attributes ambient 2.4 GHz drift
              to whichever arm happened to be running -- which on the first
              real run made "all Bluetooth off" look WORSE than "as-is", a
              physically impossible ordering. Interleaving rounds gives every
              arm the same exposure to that drift, and the summary reports
              spread so you can see whether the effect exceeds it.
  -a ARMS     comma-separated subset of: asis,classic,fastconn,alloff
  -g GATEWAY  target IP (default: the default route's gateway -- the single
              wireless hop, which is the leg we control)
  --list      describe the arms and exit

Arms:
  asis      Nothing changed. The device exactly as it is now. If the patch is
            already applied this IS the patched arm.
  classic   BR/EDR page + inquiry scan disabled (hciconfig noscan), LE
            advertising left running. This is what the patch produces, and the
            gap between it and 'alloff' is the residual LE cost -- the number
            that decides whether this fix is sufficient.
  fastconn  FastConnectable forced off at the controller via a standard page
            scan interval, everything else as-is. Isolates question 2.
  alloff    ble-config and bluetooth stopped -- the finding-10 BT-OFF arm, the
            floor. Restored afterwards.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) COUNT="$2"; shift 2 ;;
    -r) ROUNDS="$2"; shift 2 ;;
    -a) ARMS="$2"; shift 2 ;;
    -g) GW="$2"; shift 2 ;;
    --list) usage; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "must be run as root (use: sudo $0)" >&2; exit 1; }

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

if [[ -z $GW ]]; then
  GW="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
fi
[[ -n $GW ]] || { echo "could not determine the default gateway; pass -g" >&2; exit 1; }

# ---------------------------------------------------------------------------
# State capture and unconditional restore.
# ---------------------------------------------------------------------------
ORIG_SCAN=""      # piscan | pscan | iscan | noscan
ORIG_BLUETOOTH="" # active | inactive
ORIG_BLECONFIG=""
RESTORED=0

capture_state() {
  local flags
  flags="$(hciconfig hci0 2>/dev/null || true)"
  local p=0 i=0
  grep -q 'PSCAN' <<<"$flags" && p=1
  grep -q 'ISCAN' <<<"$flags" && i=1
  if   (( p && i )); then ORIG_SCAN=piscan
  elif (( p ));      then ORIG_SCAN=pscan
  elif (( i ));      then ORIG_SCAN=iscan
  else                    ORIG_SCAN=noscan; fi
  ORIG_BLUETOOTH="$(systemctl is-active bluetooth.service 2>/dev/null || echo unknown)"
  ORIG_BLECONFIG="$(systemctl is-active ble-config.service 2>/dev/null || echo unknown)"
  log "Captured original state: scan=$ORIG_SCAN bluetooth=$ORIG_BLUETOOTH ble-config=$ORIG_BLECONFIG"
}

restore_state() {
  (( RESTORED )) && return 0
  RESTORED=1
  log "Restoring original Bluetooth state (WiFi was never touched)..."
  [[ $ORIG_BLUETOOTH == active ]] && systemctl start bluetooth.service  >/dev/null 2>&1
  [[ $ORIG_BLECONFIG == active ]] && systemctl start ble-config.service >/dev/null 2>&1
  sleep 3
  hciconfig hci0 up >/dev/null 2>&1
  [[ -n $ORIG_SCAN ]] && hciconfig hci0 "$ORIG_SCAN" >/dev/null 2>&1
  sleep 2
  log "Restored. Now: $(hciconfig hci0 2>/dev/null | awk '/UP|DOWN/{$1=$1;print;exit}')"
  log "  bluetooth=$(systemctl is-active bluetooth.service 2>/dev/null || true)" \
      "ble-config=$(systemctl is-active ble-config.service 2>/dev/null || true)"
  if [[ $ORIG_BLECONFIG == active ]] && ! systemctl is-active --quiet ble-config.service; then
    log "WARNING: ble-config.service did NOT come back. This is the provisioning path."
    log "         Run: sudo systemctl start ble-config.service"
  fi
}
cleanup() { rm -f "${RESULTS:-}"; restore_state; }
# Installed BEFORE any change, so every exit path restores.
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
ping_arm() {
  local label=$1 out
  log "Arm '$label': pinging $GW, $COUNT packets (~${COUNT}s)..."
  out="$(ping -n -q -i 1 -c "$COUNT" "$GW" 2>&1 || true)"
  local loss rtt
  loss="$(grep -oE '[0-9.]+% packet loss' <<<"$out" | head -1)"
  rtt="$(grep -oE '= [0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+ ms' <<<"$out" | head -1 | sed 's/^= //; s/ ms$//')"
  if [[ -z $rtt ]]; then
    printf '%s|%s|||\n' "$label" "${round:-1}" >> "$RESULTS"
    log "  no rtt line -- raw output follows"; printf '%s\n' "$out"
    return
  fi
  local avg max mdev
  IFS=/ read -r _ avg max mdev <<<"$rtt"   # ping prints min/avg/max/mdev; min is not reported
  printf '%s|%s|%s|%s|%s|%s\n' "$label" "${round:-1}" "$avg" "$max" "$mdev" "${loss:-n/a}" >> "$RESULTS"
  log "  avg=${avg}ms max=${max}ms mdev=${mdev}ms ${loss:-}"
}

settle() { sleep 5; }

RESULTS="$(mktemp)"

capture_state

log "Gateway: $GW   packets/arm: $COUNT   arms: $ARMS"
log "Starting state: $(hciconfig hci0 2>/dev/null | awk '/UP|DOWN/{$1=$1;print;exit}')"
echo

for round in $(seq 1 "$ROUNDS"); do
log "########## ROUND $round of $ROUNDS ##########"
for arm in ${ARMS//,/ }; do
  case "$arm" in
    asis)
      log "=== ARM asis: nothing changed ==="
      settle; ping_arm "asis (unchanged)"
      ;;
    classic)
      log "=== ARM classic: BR/EDR page+inquiry scan OFF, LE advertising left running ==="
      hciconfig hci0 noscan >/dev/null 2>&1
      sleep 2
      log "  hci0 now: $(hciconfig hci0 2>/dev/null | awk '/UP|DOWN/{$1=$1;print;exit}')"
      settle; ping_arm "classic off, LE on"
      hciconfig hci0 "$ORIG_SCAN" >/dev/null 2>&1; sleep 2
      ;;
    fastconn)
      log "=== ARM fastconn: standard (non-interlaced, 1.28 s) page scan interval ==="
      # Write Page Scan Activity: interval 0x0800 (1.28 s), window 0x0012 (11.25 ms)
      # -- the kernel's own def_page_scan_int / def_page_scan_window -- and
      # Write Page Scan Type 0x00 (standard, not interlaced). This is exactly
      # what FastConnectable = false yields, applied at the controller so the
      # arm can be measured without editing config or restarting BlueZ.
      if ! command -v hcitool >/dev/null 2>&1; then
        log "  SKIPPED: hcitool is not installed (it is deprecated on trixie)."
        log "  Measure this arm instead by setting FastConnectable = false in"
        log "  /etc/bluetooth/main.conf and restarting bluetooth.service, or just"
        log "  apply the patch -- it sets that key. Do NOT report this arm as"
        log "  measured when it was not."
        echo; continue
      fi
      hciconfig hci0 "$ORIG_SCAN" >/dev/null 2>&1
      hcitool -i hci0 cmd 0x03 0x001C 0x00 0x08 0x12 0x00 >/dev/null 2>&1
      hcitool -i hci0 cmd 0x03 0x0047 0x00                >/dev/null 2>&1
      sleep 2
      settle; ping_arm "FastConnectable off"
      ;;
    alloff)
      log "=== ARM alloff: ble-config + bluetooth stopped (the finding-10 BT-OFF floor) ==="
      log "  This is the only arm that stops the provisioning path. It is restored"
      log "  afterwards, and the trap restores it even on Ctrl-C."
      systemctl stop ble-config.service >/dev/null 2>&1
      systemctl stop bluetooth.service  >/dev/null 2>&1
      hciconfig hci0 down >/dev/null 2>&1
      sleep 3
      settle; ping_arm "all Bluetooth off"
      restore_state; RESTORED=0   # bring it back before the next arm
      capture_state
      ;;
    *) log "unknown arm '$arm', skipping" ;;
  esac
  echo
done
done

# ---------------------------------------------------------------------------
echo
if [[ $ROUNDS -gt 1 ]]; then
  printf 'PER-ROUND DETAIL\n'
  printf '%-26s %6s %10s %10s %10s  %s\n' "ARM" "round" "avg (ms)" "max (ms)" "mdev (ms)" "loss"
  printf '%-26s %6s %10s %10s %10s  %s\n' "--------------------------" "------" "----------" "----------" "----------" "-----"
  while IFS='|' read -r label rnd avg max mdev loss; do
    printf '%-26s %6s %10s %10s %10s  %s\n' "$label" "$rnd" "${avg:-?}" "${max:-?}" "${mdev:-?}" "${loss:-?}"
  done < "$RESULTS"
  echo
fi

printf 'SUMMARY -- mean across %d round(s), with observed spread\n' "$ROUNDS"
printf '%-26s %10s %10s %10s %18s\n' "ARM" "avg (ms)" "max (ms)" "mdev (ms)" "mdev min..max"
printf '%-26s %10s %10s %10s %18s\n' "--------------------------" "----------" "----------" "----------" "------------------"
awk -F'|' '
  $3!="" {
    n[$1]++; a[$1]+=$3; m[$1]+=$4; d[$1]+=$5
    if (!(($1) in lo) || $5+0 < lo[$1]) lo[$1]=$5+0
    if (!(($1) in hi) || $5+0 > hi[$1]) hi[$1]=$5+0
    if (!($1 in seen)) { seen[$1]=1; order[++k]=$1 }
  }
  END {
    for (i=1;i<=k;i++) { s=order[i]
      printf "%-26s %10.3f %10.3f %10.3f %8.3f..%-8.3f\n", s, a[s]/n[s], m[s]/n[s], d[s]/n[s], lo[s], hi[s]
    }
  }' "$RESULTS"
printf '%-26s %10s %10s %10s\n' "ISSUE-064 BT ON  (ref)"  "16.910" "102.122" "22.363"
printf '%-26s %10s %10s %10s\n' "ISSUE-064 BT OFF (ref)" "3.223"  "15.019"  "2.668"
printf '\n  The reference arms were measured on a DIFFERENT network (gateway .1).\n'
printf '  Use them for the SHAPE of the BT-on/BT-off gap, not as an absolute\n'
printf '  target this bench must hit.\n'

cat <<'NOTE'

HOW TO READ THIS

  mdev is the number that matters. Compare 'classic off, LE on' against
  'all Bluetooth off':

    close to each other   -> classic scanning was the cost, the patch is the
                             right shape, and it recovers nearly all of it.
    a large gap remains   -> LE advertising is a material share of the penalty.
                             The patch is still a strict improvement, but it is
                             NOT sufficient on its own. STOP AND RAISE IT:
                             gating LE advertising has a completely different
                             risk profile, because LE advertising IS the
                             provisioning path and the only way back into a
                             device that has lost WiFi. That is a decision for
                             a human, not a follow-up commit.

  If LE does turn out to be material, the cheap next lever is bleno's
  advertising interval -- BLENO_ADVERTISING_INTERVAL, default 100 ms -- set via
  Environment= in ble-config.service. Raising it reduces LE duty cycle roughly
  proportionally and costs only discovery latency in the app. It does NOT make
  the device undiscoverable, so it keeps the no-stranding property this whole
  approach is built on.

  Record the raw output in the record's artifacts/ directory and the summary
  table in completion.md.
NOTE
