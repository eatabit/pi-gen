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
