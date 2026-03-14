# Stage 13 — Install Printer Config

## Overview

Installs a systemd oneshot service that sends ESC/POS configuration commands to the thermal printer on first boot. Each `.bin` file is tracked independently with its own `.configured` marker, so commands that trigger a printer reboot (e.g., `buzzer.bin` ends with `reset_printer`) don't cause subsequent commands to fail silently.

## Build Script (`00-run.sh`)

The pi-gen build script:

1. Creates the config directory at `/usr/local/lib/eatabit/escpos/printer-config/`
2. Generates `.bin` files from documented ESC/POS hex sequences (source: `iot-pi/docs/ESCPOS/Custom Setup Commands.md`)
3. Installs `printer-config.sh` to `/usr/local/lib/eatabit/bin/`
4. Creates and enables the `printer-config.service` systemd unit

### Generated Binary Files

| File | Purpose | Ends With |
|------|---------|-----------|
| `buzzer.bin` | Disables human voice alerts, enables buzzer | `reset_printer` (causes reboot) |
| `wifi-disable.bin` | Disables the printer's built-in wifi radio | `save_param_zone` (no reboot) |

#### `buzzer.bin` Command Sequence

1. `unlock_para` — unlock parameter editing
2. `setkey 0x0093 = [0x01, 0x01, 0x01]` — disable human voice, enable buzzer
3. `setkey 0x00DB = [0x00, 0x04, 0x01, 0x01, 0x01, 0x01]` — buzzer configuration
4. `save_param_zone` — persist to flash
5. `reset_printer` — reboot printer to apply

#### `wifi-disable.bin` Command Sequence

1. `setkey 0x0184 = [0x00, 0x01, 0x00]` — disable wifi radio
2. `save_param_zone` — persist to flash

## Runtime Script (`printer-config.sh`)

### Configuration

| Constant | Value | Description |
|----------|-------|-------------|
| `PRINTER` | `/dev/usb/lp0` | USB printer device path |
| `CONFIG_DIR` | `/usr/local/lib/eatabit/escpos/printer-config` | Directory containing `.bin` files |
| `MAX_WAIT` | `30` | Seconds to wait for printer to appear |

### Execution Flow

```
For each *.bin file (alphabetical order):
  ├── Already has .configured marker? → skip
  ├── Wait for printer (up to 30s)
  │   └── Timeout? → exit 0 (retry remaining on next boot)
  ├── Send .bin file to /dev/usb/lp0
  ├── Check if printer reboots (disappears within 5s)
  │   ├── Yes → wait for recovery (up to 30s) + 2s firmware init
  │   │   └── Timeout? → exit 0 (don't mark, retry on next boot)
  │   └── No → 2s delay
  └── touch <file>.bin.configured
```

### Reboot Detection

Some ESC/POS commands (like `reset_printer` in `buzzer.bin`) cause the printer to power cycle. When this happens, `/dev/usb/lp0` disappears temporarily. The script:

1. Polls for up to 5 seconds after sending each command to detect if the device disappears
2. If it disappears, waits up to 30 seconds for it to reappear
3. Adds a 2-second delay after reappearance for firmware initialization
4. If the printer never comes back, exits without marking — the command will be retried on next boot

### Idempotency

Each `.bin` file gets its own `<name>.bin.configured` marker file in the config directory. On subsequent boots, already-configured commands are skipped. If the script is interrupted (e.g., printer never recovers), only the successfully applied commands are marked — the rest will retry on next boot.

## Systemd Configuration

### Service (`printer-config.service`)

- **Type:** `oneshot` — runs once per boot, not a long-running daemon
- **After:** `boot-print.service` — ensures boot print completes first
- **Before:** `mqtt-client.service`, `ble-config.service`, `device-reset.service` — printer is configured before operational services start
- **Logs:** stdout/stderr routed to journald under the `printer-config` syslog identifier

## File Paths

| Path | Purpose |
|------|---------|
| `/usr/local/lib/eatabit/bin/printer-config.sh` | Runtime script |
| `/usr/local/lib/eatabit/escpos/printer-config/` | Config directory |
| `/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin` | Buzzer config binary |
| `/usr/local/lib/eatabit/escpos/printer-config/wifi-disable.bin` | Wifi disable binary |
| `/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin.configured` | Marker: buzzer applied |
| `/usr/local/lib/eatabit/escpos/printer-config/wifi-disable.bin.configured` | Marker: wifi-disable applied |
| `/etc/systemd/system/printer-config.service` | Systemd unit file |

## Re-running Configuration

Re-run a specific command:

```bash
rm /usr/local/lib/eatabit/escpos/printer-config/buzzer.bin.configured && reboot
```

Re-run all commands:

```bash
rm /usr/local/lib/eatabit/escpos/printer-config/*.bin.configured && reboot
```

## Adding New Configurations

1. Add new `printf` commands to `00-run.sh` to generate the `.bin` file
2. The runtime script automatically picks up all `.bin` files alphabetically
3. If the new command causes a printer reboot, no special handling is needed — the script detects reboots automatically

## Logs

```bash
journalctl -u printer-config
```

Example output:

```
Sending printer config: buzzer.bin
Printer rebooted after buzzer.bin, waiting for recovery...
Configured: buzzer.bin
Sending printer config: wifi-disable.bin
Configured: wifi-disable.bin
Printer configuration complete (sent=2, skipped=0)
```
