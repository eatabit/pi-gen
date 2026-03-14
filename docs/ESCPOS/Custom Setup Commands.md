# Custom Setup Commands

Commands that must be run on a new device before shipping.

## Buzzer Setup (Disable Human Voice, Enable Buzzer)

Disables the human voice from the device speaker and enables the device buzzer. Uses the Custom VPL `setkey` mechanism to write configuration keys `0x93` and `0xDB`.

### Command sequence

```
1b 1c 26 20 56 31 20 64 6f 20 22 75 6e 6c 6f 63 6b 5f 70 61 72 61 22 0d 0a       ← unlock_para
1b 1c 26 20 56 31 20 73 65 74 6b 65 79 0d 0a 00 93 01 01 01                         ← setkey 0x93
1b 1c 26 20 56 31 20 73 65 74 6b 65 79 0d 0a 00 db 00 04 01 01 01 01               ← setkey 0xDB
1b 1c 26 20 56 31 20 64 6f 20 22 73 61 76 65 5f 70 61 72 61 6d 5f 7a 6f 6e 65 22 0d 0a  ← save_param_zone
1b 1c 26 20 56 31 20 64 6f 20 22 72 65 73 65 74 5f 70 72 69 6e 74 65 72 22 0d 0a   ← reset_printer
```

### Related

- [Custom Speaker Commands](Custom%20Speaker%20Commands.md) — speaker on/off and volume configuration

## Wifi Disable (Turn Off Printer Wifi Radio)

Disables the printer's built-in wifi radio. Uses the Custom VPL `setkey` mechanism to write configuration key `0x0184`. Does not require `unlock_para` or `reset_printer` — the change takes effect after `save_param_zone`.

### Command sequence

```
1b 1c 26 20 56 31 20 73 65 74 6b 65 79 0d 0a 01 84 00 01 00                         ← setkey 0x0184
1b 1c 26 20 56 31 20 64 6f 20 22 73 61 76 65 5f 70 61 72 61 6d 5f 7a 6f 6e 65 22 0d 0a  ← save_param_zone
```

### Key details

| Key | Bytes | Description |
|-----|-------|-------------|
| `0x0184` | `00 01 00` | Wifi radio disable (zone `0x01`, key `0x84`, value `0x00 0x01 0x00`) |

### Notes

- Unlike the buzzer setup, this command does **not** require `unlock_para` first
- No `reset_printer` is needed — the wifi radio state changes after `save_param_zone` without a power cycle
