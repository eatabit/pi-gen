#!/bin/bash
PRINTER="/dev/usb/lp0"
ESCPOS="/usr/local/lib/eatabit/escpos/booting.escpos"
MAX_WAIT=30

# BUG-094 guard 4: print NOTHING after a netwatch-initiated reboot. netwatch writes
#   {"writtenBootId":"<boot that rebooted>","boundBootId":null}
# to the card before it reboots. This script runs first on the boot that follows, so
# it BINDS the marker to this boot and skips. It never deletes it: mqtt-client.js reads
# the same marker later to skip the ready receipt, and netwatch removes it once that
# decision is recorded. A marker bound to an EARLIER boot is stale -- e.g. a human
# power-cycled a device still offline after a watchdog reboot -- and a human
# power-cycle must always print. Unreadable or malformed: remove it and print (fail
# open to the old behaviour, never fail silent). boot_id-bound, not time-based: the Pi
# has no RTC.
MARKER="/usr/local/lib/eatabit/state/netwatch-reboot"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

marker_field() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([0-9a-f-]*\)\".*/\1/p" <<<"$2"
}

if [ -f "$MARKER" ] && [ -n "$BOOT_ID" ]; then
  CONTENT="$(cat "$MARKER" 2>/dev/null)"
  WRITTEN="$(marker_field writtenBootId "$CONTENT")"
  BOUND="$(marker_field boundBootId "$CONTENT")"
  if [ -z "$WRITTEN" ]; then
    echo "boot-print: malformed netwatch marker removed; printing normally"
    rm -f "$MARKER"
  elif [ -z "$BOUND" ] && grep -q '"boundBootId"[[:space:]]*:[[:space:]]*null' <<<"$CONTENT" \
       && [ "$WRITTEN" != "$BOOT_ID" ]; then
    printf '{"writtenBootId":"%s","boundBootId":"%s"}' "$WRITTEN" "$BOOT_ID" > "$MARKER.tmp" \
      && sync "$MARKER.tmp" && mv -f "$MARKER.tmp" "$MARKER" && sync
    echo "boot-print: netwatch-initiated reboot -- skipping the booting receipt"
    exit 0
  elif [ "$BOUND" = "$BOOT_ID" ]; then
    echo "boot-print: netwatch-initiated reboot (marker already bound) -- skipping the booting receipt"
    exit 0
  else
    echo "boot-print: stale netwatch marker removed; printing normally"
    rm -f "$MARKER"
  fi
fi

# Wait for printer to appear
WAITED=0
while [ ! -e "$PRINTER" ] && [ $WAITED -lt $MAX_WAIT ]; do
  sleep 1
  WAITED=$((WAITED + 1))
done

if [ -e "$PRINTER" ] && [ -f "$ESCPOS" ]; then
  # Wait for printer firmware to initialize after USB enumeration
  sleep 2
  cat "$ESCPOS" > "$PRINTER" 2>/dev/null || true
  # Wait for printer to finish processing raster data before other services access it
  sleep 3
fi
