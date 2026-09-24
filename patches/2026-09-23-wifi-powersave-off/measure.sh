#!/bin/bash
# measure.sh -- BUG-093 Wi-Fi power-save efficacy harness
#
# The patch turns 802.11 power-save OFF. The claim under test is about the RADIO,
# so the measurement is about the radio: first-hop latency and jitter, taken the
# same way before and after the patch, by this same committed file.
#
# Why two vantage points. With power-save on, the AP buffers frames addressed to a
# dozing station until the next beacon (100 TU here, DTIM 3), so the cost shows up
# on traffic flowing INTO the Pi. A ping the Pi originates wakes its own radio
# first, and the reply usually lands inside the post-transmit awake period -- so
# outbound pings can understate the effect. `inbound` mode runs on the WORKSTATION
# and pings the Pi, which is the leg power-save actually delays. Run both.
#
# Modes
#   window   (Pi, root)  One measurement window: ping samples to the default
#                        gateway on a schedule, iw/station/proc counters, and at
#                        the end a report including reconnects and mqtt-client
#                        interruptions over the window. READ-ONLY.
#   ab       (Pi, root)  Interleaved A/B: toggles runtime power-save with
#                        `iw dev wlan0 set power_save on|off` in alternating
#                        rounds and pings under each. Does not reassociate. The
#                        ONLY mode that changes anything, and it restores the prior
#                        state on every exit path (EXIT/INT/TERM/HUP) via a trap.
#   inbound  (workstation) Pings the Pi on the same sample schedule. Portable to
#                        macOS /bin/bash 3.2 and BSD awk.
#   report DIR           Recompute a window/inbound report from a saved run dir.
#   abreport ABDIR INDIR Join an `ab` run's arm intervals with an `inbound` run
#                        taken over the same period: inbound RTT per arm.
#   snapshot (Pi, root)  One-shot state read: power_save, link, counters.
#
# Usage
#   # before-window, 24 h, detached so an SSH drop cannot kill it:
#   sudo systemd-run --unit=bug093-before --collect \
#       /home/eatabit/measure.sh window -l before -d 24
#   # the workstation leg, same schedule, same length:
#   ./measure.sh inbound -t 192.168.1.80 -l before -d 24 -o ~/bug093
#   # afterwards, on the Pi:
#   sudo ./measure.sh report /var/tmp/bug093-measure/before-<stamp>
#
#   # interleaved A/B, 4 rounds, each arm 60 packets (own window, not overlapping
#   # before/after); start `inbound -s 0` on the workstation first:
#   ./measure.sh inbound -t 192.168.1.80 -l ab -s 0 -d 1 -o ~/bug093
#   sudo ./measure.sh ab -r 4
#   ./measure.sh abreport <ab-dir-copied-from-pi> ~/bug093/ab-<stamp>
#
# Options
#   -l LABEL   run label, used in the output dir name (default: window)
#   -d HOURS   window length (default 24; decimals allowed)
#   -n COUNT   packets per sample (default 60)
#   -s SECS    seconds between sample STARTS (default 900 = 15 min; 0 = back to
#              back). Ping interval is always the default 1 s: a faster stream
#              keeps the radio awake and hides exactly what is being measured.
#   -r ROUNDS  ab: rounds (default 4, minimum 3 -- a single round attributes
#              ambient 2.4 GHz drift to whichever arm was running; see
#              2026-08-20-ble-classic-scan-off/measure.sh)
#   -g IP      ping target on the Pi (default: the default route's gateway)
#   -t IP      inbound: the Pi to ping (required)
#   -o DIR     output parent dir (Pi default /var/tmp/bug093-measure)
#
# Reading the numbers
#   mdev (headline) is the population standard deviation of every per-packet RTT
#   in the window -- the same formula ping uses for its own mdev, pooled across
#   samples. Jitter is what maps onto the failure mode: mqtt-client disconnects
#   are AWS_ERROR_MQTT_TIMEOUT against a ping window. p95 is reported beside it.
#   Counters: brcmfmac reports only some station fields. A field it does not
#   report prints "not reported", never 0.

set -uo pipefail

PATCH_ID="2026-09-23-wifi-powersave-off"
IW=/usr/sbin/iw
IFACE=wlan0
MQTT_LOG=/usr/local/lib/eatabit/log/mqtt-client.log

LABEL=window
HOURS=24
COUNT=60
SPACING=900
ROUNDS=4
GW=""
TARGET=""
OUTPARENT=""

MODE="${1:-}"
[[ -n $MODE ]] || { sed -n '2,60p' "$0"; exit 1; }
shift

REPORT_DIR=""; AB_DIR=""; IN_DIR=""
case "$MODE" in
  report)   REPORT_DIR="${1:-}"; [[ -n $REPORT_DIR ]] && shift ;;
  abreport) AB_DIR="${1:-}"; IN_DIR="${2:-}"; [[ -n $IN_DIR ]] && shift 2 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l) LABEL="$2"; shift 2 ;;
    -d) HOURS="$2"; shift 2 ;;
    -n) COUNT="$2"; shift 2 ;;
    -s) SPACING="$2"; shift 2 ;;
    -r) ROUNDS="$2"; shift 2 ;;
    -g) GW="$2"; shift 2 ;;
    -t) TARGET="$2"; shift 2 ;;
    -o) OUTPARENT="$2"; shift 2 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
now() { date +%s; }
utc() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$1" '+%Y-%m-%d %H:%M:%S'; }

need_root() { [[ $EUID -eq 0 ]] || { echo "must be run as root (sudo $0 $MODE ...)" >&2; exit 1; }; }
need_iw()   { [[ -x $IW ]] || { echo "$IW not found -- this mode runs on the Pi" >&2; exit 1; }; }

default_gw() {
  [[ -n $GW ]] && { echo "$GW"; return; }
  ip route show default 2>/dev/null | awk '/default/{print $3; exit}'
}

new_outdir() {
  local parent=$1 d
  d="$parent/$LABEL-$(date -u '+%Y%m%dT%H%M%SZ')"
  mkdir -p "$d" || { echo "cannot create $d" >&2; exit 1; }
  echo "$d"
}

# ---------------------------------------------------------------------------
# One ping sample. Appends per-packet RTTs to rtt.tsv and a tx/rx line to
# samples.tsv. Portable: GNU iputils and macOS ping both print
# "icmp_seq=N ttl=T time=X ms" per reply and "N packets transmitted, M ...".
# Packet time is approximated as sample start + seq offset (1 s interval).
# ---------------------------------------------------------------------------
ping_sample() {
  local dir=$1 target=$2 sid=$3 arm=${4:--} t0 out tx rx
  t0=$(now)
  # Hard deadline so an unreachable target cannot stall the schedule: Linux -w, macOS -t.
  local dl=$(( COUNT + 15 )) dflag=-w
  [[ "$(uname -s)" == Darwin ]] && dflag=-t
  out="$(ping -n -c "$COUNT" "$dflag" "$dl" "$target" 2>&1 || true)"
  printf '%s\n' "$out" | awk -v t0="$t0" -v sid="$sid" -v arm="$arm" '
    /icmp_seq=/ && /time=/ {
      seq=$0; sub(/.*icmp_seq=/,"",seq); sub(/[^0-9].*/,"",seq)
      t=$0;   sub(/.*time=/,"",t);       sub(/[^0-9.].*/,"",t)
      if (first=="") first=seq
      printf "%d\t%s\t%s\t%s\n", t0+(seq-first), sid, arm, t
    }' >> "$dir/rtt.tsv"
  tx="$(printf '%s\n' "$out" | awk '/packets transmitted/{print $1; exit}')"
  rx="$(printf '%s\n' "$out" | awk '/packets transmitted/{for(i=1;i<=NF;i++) if ($(i+1) ~ /^(received|packets)/ && $i ~ /^[0-9]+$/ && i>1) {print $i; exit}}')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$t0" "$arm" "${tx:-0}" "${rx:-0}" >> "$dir/samples.tsv"
}

# ---------------------------------------------------------------------------
# Radio state read (Pi only). One TSV row:
# epoch power_save connected_s tx_packets tx_failed rx_packets signal bssid freq missed_beacon tx_retries beacon_loss
# ---------------------------------------------------------------------------
station_row() {
  local ps dump link mb
  ps="$($IW dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}')"
  dump="$($IW dev "$IFACE" station dump 2>/dev/null)"
  link="$($IW dev "$IFACE" link 2>/dev/null)"
  mb="$(awk -v i="$IFACE:" '$1==i{print $NF}' /proc/net/wireless 2>/dev/null)"
  printf '%s\t%s\t' "$(now)" "${ps:-?}"
  printf '%s\n' "$dump" | awk -v link="$link" -v mb="${mb:-?}" '
    function val(k) { return (k in v) ? v[k] : "NR" }
    /^Station/ { if (!bssid) bssid=$2 }
    { line=$0; sub(/^[ \t]+/,"",line); n=index(line,":")
      if (n) { k=substr(line,1,n-1); r=substr(line,n+1); sub(/^[ \t]+/,"",r); split(r,a," "); v[k]=a[1] } }
    END {
      freq="?"; m=split(link,L,"\n"); for (i=1;i<=m;i++) if (L[i] ~ /freq:/) { f=L[i]; sub(/.*freq:[ \t]*/,"",f); freq=f }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", val("connected time"), val("tx packets"),
        val("tx failed"), val("rx packets"), val("signal"), (bssid?bssid:"none"), freq, mb,
        val("tx retries"), val("beacon loss")
    }'
}

# ---------------------------------------------------------------------------
# Reporting (portable: runs on the Pi or the workstation).
# ---------------------------------------------------------------------------
rtt_stats() {  # stdin: RTT values, one per line. Prints n avg p50 p95 p99 max mdev
  sort -n | awk '
    { x[++n]=$1; s+=$1; ss+=$1*$1 }
    function pct(q,  i) { i=int(q*n); if (i<q*n) i++; if (i<1) i=1; return x[i] }
    END {
      if (!n) { print "0 - - - - - -"; exit }
      m=s/n; var=ss/n-m*m; if (var<0) var=0
      printf "%d %.3f %.3f %.3f %.3f %.3f %.3f\n", n, m, pct(.50), pct(.95), pct(.99), x[n], sqrt(var)
    }'
}

print_rtt_block() {  # $1 dir, $2 title
  local dir=$1 title=$2 st tx rx
  [[ -s $dir/rtt.tsv ]] || { printf '%s: no RTT data\n' "$title"; return; }
  st="$(cut -f4 "$dir/rtt.tsv" | rtt_stats)"
  tx="$(awk -F'\t' '{t+=$4} END{print t+0}' "$dir/samples.tsv")"
  rx="$(awk -F'\t' '{r+=$5} END{print r+0}' "$dir/samples.tsv")"
  printf '%s\n' "$title"
  printf '  samples %s   packets tx %s rx %s   loss %s%%\n' \
    "$(wc -l < "$dir/samples.tsv" | tr -d ' ')" "$tx" "$rx" \
    "$(awk -v t="$tx" -v r="$rx" 'BEGIN{ if (t>0) printf "%.2f", 100*(t-r)/t; else print "-" }')"
  set -- $st
  printf '  n=%s  avg %s  p50 %s  p95 %s  p99 %s  max %s   mdev(pooled) %s ms  <-- headline\n' "$@"
  # Per-sample mdev distribution: shows whether jitter is steady or bursty.
  awk -F'\t' '{ n[$2]++; s[$2]+=$4; ss[$2]+=$4*$4 }
    END { for (k in n) { m=s[k]/n[k]; v=ss[k]/n[k]-m*m; if (v<0) v=0; print sqrt(v) } }' "$dir/rtt.tsv" \
    | sort -n | awk '{x[++n]=$1} END{ if(n) printf "  per-sample mdev: min %.3f  median %.3f  max %.3f ms (%d samples)\n", x[1], x[int((n+1)/2)], x[n], n }'
}

print_station_block() {  # $1 dir -- counter deltas with reassociation (reset) detection
  local dir=$1
  [[ -s $dir/station.tsv ]] || return
  awk -F'\t' '
    function num(v) { return (v ~ /^-?[0-9]+$/) }
    NR==1 { t0=$1; ps0=$2; sig0=$7; b0=$8; f0=$9; smin=$7; smax=$7 }
    {
      # connected time going backwards == reassociation: counters restarted from 0.
      if (NR>1 && num($3) && num(pc) && $3+0 < pc+0) { resets++; for (c=4;c<=6;c++) if (num($c) && num(pv[c])) acc[c]+= pv[c] - sv[c]; for (c=4;c<=6;c++) sv[c]=0 }
      else if (NR==1) { for (c=4;c<=6;c++) sv[c]=$c }
      for (c=4;c<=6;c++) pv[c]=$c
      if (num($10)) { if (NR==1) mb0=$10; mbl=$10 }
      pc=$3; t1=$1; ps1=$2; sig1=$7; b1=$8; f1=$9
      if (num($7)) { if ($7+0<smin+0) smin=$7; if ($7+0>smax+0) smax=$7 }
      tr=$11; bl=$12; if (bssid_seen[$8]++==0) nb++
    }
    END {
      h=(t1-t0)/3600; if (h<=0) h=1
      split("x x x tx_packets tx_failed rx_packets",nm," ")
      printf "Radio counters over %.2f h (reassociations detected: %d)\n", (t1-t0)/3600, resets+0
      for (c=4;c<=6;c++) { d=acc[c] + (num(pv[c]) && num(sv[c]) ? pv[c]-sv[c] : 0)
        printf "  %-11s +%d  (%.1f/h)\n", nm[c], d, d/h }
      if (mb0!="") printf "  missed_beacon (/proc/net/wireless) +%d\n", mbl-mb0; else print "  missed_beacon  not reported"
      printf "  tx_retries   %s\n", (tr=="NR" ? "not reported by driver" : tr " (cumulative)")
      printf "  beacon_loss  %s\n", (bl=="NR" ? "not reported by driver" : bl " (cumulative)")
      printf "Power-save: start %s  end %s\n", ps0, ps1
      printf "Control (must not have moved): signal start %s end %s (min %s max %s) dBm; BSSID start %s end %s (%d distinct); freq start %s end %s\n", sig0, sig1, smin, smax, b0, b1, nb, f0, f1
    }' "$dir/station.tsv"
}

print_events_block() {  # $1 dir -- Pi only: reconnects (journal) and mqtt-client interruptions
  local dir=$1 t0 t1 j
  t0="$(awk -F= '$1=="start_epoch"{print $2}' "$dir/meta.txt")"
  t1="$(awk -F= '$1=="end_epoch"{print $2}' "$dir/meta.txt")"
  [[ -n $t0 && -n $t1 ]] || return
  command -v journalctl >/dev/null 2>&1 || return
  j="$(journalctl --no-pager -o short-iso --since "@$t0" --until "@$t1" \
        -u NetworkManager -u wpa_supplicant 2>/dev/null)"
  printf 'Reconnects in window (must not regress; expected ~0)\n'
  printf '  wpa CTRL-EVENT-CONNECTED     %s\n' "$(grep -a -c 'CTRL-EVENT-CONNECTED' <<<"$j")"
  printf '  wpa CTRL-EVENT-DISCONNECTED  %s\n' "$(grep -a -c 'CTRL-EVENT-DISCONNECTED' <<<"$j")"
  grep -a -oE 'CTRL-EVENT-CONNECTED - Connection to [0-9a-f:]{17}' <<<"$j" | awk '{print $NF}' \
    | sort | uniq -c | awk '{printf "    by BSSID %s: %s\n", $2, $1}'
  printf '  NM wlan0 -> activated        %s\n' "$(grep -a -cE 'device \(wlan0\): state change: .* -> activated' <<<"$j")"
  printf '  NM wlan0 -> disconnected     %s\n' "$(grep -a -cE 'device \(wlan0\): state change: .* -> (disconnected|unavailable)' <<<"$j")"
  # mqtt-client.log timestamps are UTC ("[YYYY-MM-DD HH:MM:SS.mmm]"), whatever the TZ.
  # grep -a: the log can contain bytes that flip grep into binary mode and truncate.
  local s e files=""
  s="$(utc "$t0")"; e="$(utc "$t1")"
  for f in "$MQTT_LOG".1 "$MQTT_LOG"; do [[ -r $f ]] && files="$files $f"; done
  # BUG-094's netwatch acts on its own when the device is offline (con down/up, radio
  # cycle, driver reload, reboot). Any action inside the window invalidates it.
  local nw=/usr/local/lib/eatabit/log/netwatch.log
  if [[ -r $nw ]]; then
    printf 'netwatch (BUG-094) actions in window: %s\n' \
      "$(awk -v s="$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%S)" -v e="$(date -u -d "@$t1" +%Y-%m-%dT%H:%M:%S)" \
          'match($0,/"ts":"[^"]*"/){ts=substr($0,RSTART+6,19)} ts>=s && ts<=e && $0 !~ /"event":"healthy"/' "$nw" | wc -l | tr -d ' ')"
  fi
  if [[ -n $files ]]; then
    # shellcheck disable=SC2086
    zcat -f $files 2>/dev/null | awk -v s="[$s" -v e="[$e" 'substr($0,1,20)>=s && substr($0,1,20)<=e' > "$dir/mqtt-window.log"
    printf 'mqtt-client in window (%s .. %s UTC)\n' "$s" "$e"
    printf '  Connection interrupted       %s\n' "$(grep -a -c 'Connection interrupted' "$dir/mqtt-window.log")"
    printf '    of which MQTT_TIMEOUT      %s\n' "$(grep -a -c 'AWS_ERROR_MQTT_TIMEOUT' "$dir/mqtt-window.log")"
    printf '  Connection resumed           %s\n' "$(grep -a -c 'Connection resumed' "$dir/mqtt-window.log")"
  fi
}

do_report() {
  local dir=$1
  [[ -f $dir/meta.txt ]] || { echo "not a run dir: $dir" >&2; exit 1; }
  {
    printf '=== BUG-093 measure.sh report: %s ===\n' "$dir"
    cat "$dir/meta.txt"
    echo
    print_rtt_block "$dir" "First-hop RTT ($(awk -F= '$1=="vantage"{print $2}' "$dir/meta.txt"))"
    echo
    print_station_block "$dir"
    echo
    # Pi only. An `if`, not `&&`: as the last command a false test would make the
    # whole report exit 1 on the workstation, where iw does not exist.
    if [[ -x $IW ]]; then print_events_block "$dir"; fi
  } | tee "$dir/report.txt"
}

write_meta() {  # dir key=value...
  local dir=$1; shift
  for kv in "$@"; do printf '%s\n' "$kv" >> "$dir/meta.txt"; done
}

common_meta() {
  local dir=$1 vantage=$2 target=$3
  write_meta "$dir" "patch=$PATCH_ID" "mode=$MODE" "label=$LABEL" "vantage=$vantage" \
    "target=$target" "host=$(hostname 2>/dev/null)" "count=$COUNT" "spacing_s=$SPACING" \
    "hours=$HOURS" "measure_sha256=$( (sha256sum "$0" 2>/dev/null || shasum -a 256 "$0") | awk '{print $1}')" \
    "start_epoch=$(now)" "start_utc=$(utc "$(now)")"
}

run_schedule() {  # dir target arm  -- sample loop for HOURS at SPACING
  local dir=$1 target=$2 withstation=$3 end sid=0 next
  end=$(( $(now) + $(awk -v h="$HOURS" 'BEGIN{printf "%d", h*3600}') ))
  next=$(now)
  while (( $(now) < end )); do
    sid=$((sid+1))
    [[ $withstation == 1 ]] && station_row >> "$dir/station.tsv"
    ping_sample "$dir" "$target" "$sid"
    next=$(( next + SPACING ))
    # After a stall (host asleep, network down) skip the missed slots rather than
    # firing them back to back: a burst of samples is not the schedule the other
    # window used. Missed slots show up as a gap in samples.tsv.
    if (( SPACING > 0 )); then
      while (( next <= $(now) )); do next=$(( next + SPACING )); done
      sleep $(( next - $(now) ))
    else
      next=$(now)
    fi
  done
  [[ $withstation == 1 ]] && station_row >> "$dir/station.tsv"
}

# ---------------------------------------------------------------------------
case "$MODE" in
  snapshot)
    need_root; need_iw
    printf 'epoch\tpower_save\tconnected_s\ttx_packets\ttx_failed\trx_packets\tsignal\tbssid\tfreq\tmissed_beacon\ttx_retries\tbeacon_loss\n'
    station_row
    ;;

  window)
    need_root; need_iw
    target="$(default_gw)"; [[ -n $target ]] || { echo "no default gateway; pass -g" >&2; exit 1; }
    dir="$(new_outdir "${OUTPARENT:-/var/tmp/bug093-measure}")"
    common_meta "$dir" "pi->gateway (outbound)" "$target"
    write_meta "$dir" "mqtt_mainpid_start=$(systemctl show -p MainPID --value mqtt-client.service 2>/dev/null)"
    log "window '$LABEL' -> $dir  target $target  ${HOURS}h  $COUNT pkts every ${SPACING}s"
    log "power_save now: $($IW dev "$IFACE" get power_save 2>/dev/null)"
    run_schedule "$dir" "$target" 1
    write_meta "$dir" "end_epoch=$(now)" "end_utc=$(utc "$(now)")" \
      "mqtt_mainpid_end=$(systemctl show -p MainPID --value mqtt-client.service 2>/dev/null)"
    do_report "$dir"
    ;;

  inbound)
    [[ -n $TARGET ]] || { echo "inbound needs -t <pi-ip>" >&2; exit 1; }
    dir="$(new_outdir "${OUTPARENT:-.}")"
    common_meta "$dir" "workstation->pi (inbound)" "$TARGET"
    log "inbound '$LABEL' -> $dir  target $TARGET  ${HOURS}h  $COUNT pkts every ${SPACING}s"
    run_schedule "$dir" "$TARGET" 0
    write_meta "$dir" "end_epoch=$(now)" "end_utc=$(utc "$(now)")"
    do_report "$dir"
    ;;

  report)
    [[ -n $REPORT_DIR ]] || { echo "usage: $0 report DIR" >&2; exit 1; }
    do_report "$REPORT_DIR"
    ;;

  ab)
    need_root; need_iw
    (( ROUNDS >= 3 )) || { echo "-r must be >= 3 (single rounds confound drift with arm)" >&2; exit 1; }
    target="$(default_gw)"; [[ -n $target ]] || { echo "no default gateway; pass -g" >&2; exit 1; }
    ORIG_PS="$($IW dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}')"
    [[ $ORIG_PS == on || $ORIG_PS == off ]] || { echo "cannot read current power_save ('$ORIG_PS'); refusing to toggle" >&2; exit 1; }
    [[ $LABEL == window ]] && LABEL=ab
    RESTORED=0
    restore_ps() {
      (( RESTORED )) && return 0
      RESTORED=1
      $IW dev "$IFACE" set power_save "$ORIG_PS" 2>/dev/null
      log "restored power_save -> $($IW dev "$IFACE" get power_save 2>/dev/null) (was $ORIG_PS)"
    }
    # Installed BEFORE the first toggle. HUP covers the SSH session dropping.
    trap restore_ps EXIT
    trap 'restore_ps; exit 130' INT
    trap 'restore_ps; exit 143' TERM
    trap 'restore_ps; exit 129' HUP
    dir="$(new_outdir "${OUTPARENT:-/var/tmp/bug093-measure}")"
    common_meta "$dir" "pi->gateway (outbound), interleaved A/B" "$target"
    write_meta "$dir" "orig_power_save=$ORIG_PS" "rounds=$ROUNDS"
    log "A/B -> $dir  target $target  $ROUNDS rounds x 2 arms x $COUNT pkts; original power_save=$ORIG_PS"
    sid=0
    for r in $(seq 1 "$ROUNDS"); do
      # Alternate arm order each round so neither arm always runs first.
      if (( r % 2 )); then arms="on off"; else arms="off on"; fi
      for a in $arms; do
        $IW dev "$IFACE" set power_save "$a"
        got="$($IW dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}')"
        [[ $got == "$a" ]] || log "WARNING: asked for $a, iw reads '$got'"
        sleep 5
        sid=$((sid+1))
        station_row >> "$dir/station.tsv"
        t0=$(now)
        ping_sample "$dir" "$target" "$sid" "$a"
        printf '%s\t%s\t%s\t%s\n' "$r" "$a" "$t0" "$(now)" >> "$dir/arms.tsv"
        log "round $r arm $a done"
      done
    done
    restore_ps
    write_meta "$dir" "end_epoch=$(now)" "end_utc=$(utc "$(now)")"
    {
      echo "=== A/B (outbound pi->gateway) per arm ==="
      for a in on off; do
        printf 'power_save %-3s ' "$a"
        awk -F'\t' -v a="$a" '$3==a{print $4}' "$dir/rtt.tsv" | rtt_stats \
          | awk '{printf "n=%s avg %s p50 %s p95 %s p99 %s max %s mdev %s ms\n",$1,$2,$3,$4,$5,$6,$7}'
      done
      echo "Per round mdev (on / off):"
      awk -F'\t' '{ k=$2"|"$3; n[k]++; s[k]+=$4; ss[k]+=$4*$4 }
        END { for (k in n) { m=s[k]/n[k]; v=ss[k]/n[k]-m*m; if(v<0)v=0; split(k,p,"|"); print p[1], p[2], sqrt(v) } }' \
        "$dir/rtt.tsv" | sort -n > "$dir/.sid_mdev"
      awk 'NR==FNR{ md[$1]=$3; next } { printf "  round %s %-3s mdev %.3f\n", $1, $2, md[++i] }' \
        "$dir/.sid_mdev" "$dir/arms.tsv"
      rm -f "$dir/.sid_mdev"
      echo "Copy $dir to the workstation and run: ./measure.sh abreport $dir <inbound-dir>"
    } | tee "$dir/report.txt"
    ;;

  abreport)
    [[ -f $AB_DIR/arms.tsv && -f $IN_DIR/rtt.tsv ]] || { echo "usage: $0 abreport AB_DIR INBOUND_DIR" >&2; exit 1; }
    echo "=== A/B inbound (workstation->pi) per arm, joined on arm time intervals ==="
    for a in on off; do
      printf 'power_save %-3s ' "$a"
      awk -F'\t' -v a="$a" 'NR==FNR { if ($2==a) { s[++n]=$3; e[n]=$4 }; next }
        { for (i=1;i<=n;i++) if ($1>=s[i] && $1<=e[i]) { print $4; break } }' \
        "$AB_DIR/arms.tsv" "$IN_DIR/rtt.tsv" | rtt_stats \
        | awk '{printf "n=%s avg %s p50 %s p95 %s p99 %s max %s mdev %s ms\n",$1,$2,$3,$4,$5,$6,$7}'
    done
    ;;

  *)
    echo "unknown mode '$MODE' (window | ab | inbound | report | abreport | snapshot)" >&2; exit 1 ;;
esac
