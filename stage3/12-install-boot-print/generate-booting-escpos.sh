#!/bin/bash -e
# Generate booting.escpos binary file
# ESC/POS commands for "BOOTING\nplease wait" centered on thermal printer

OUT="files/booting.escpos"

{
  # ESC @ — Initialize printer
  printf '\x1b\x40'

  # ESC a 1 — Center alignment
  printf '\x1b\x61\x01'

  # Feed 3 lines
  printf '\x1b\x64\x03'

  # GS ! 0x11 — Double width + double height
  printf '\x1d\x21\x11'

  # ESC E 1 — Bold on
  printf '\x1b\x45\x01'

  # Print "BOOTING"
  printf 'BOOTING'

  # Line feed
  printf '\x0a'

  # GS ! 0x00 — Normal size
  printf '\x1d\x21\x00'

  # ESC E 0 — Bold off
  printf '\x1b\x45\x00'

  # Feed 1 line
  printf '\x1b\x64\x01'

  # Print "please wait"
  printf 'please wait'

  # Feed 4 lines
  printf '\x1b\x64\x04'

  # GS V 1 — Partial cut
  printf '\x1d\x56\x01'
} > "$OUT"

echo "Generated $OUT ($(wc -c < "$OUT") bytes)"
