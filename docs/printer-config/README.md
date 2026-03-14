# Printer Config Service

Sends ESC/POS configuration commands to the thermal printer on first boot. Uses per-command marker files so each command is applied independently and can be retried individually.

## How It Works

1. The `printer-config.service` systemd unit runs after `boot-print.service` and before operational services (`mqtt-client`, `ble-config`, `device-reset`)
2. For each `.bin` file in the config directory (alphabetical order):
   - Checks for a `<name>.bin.configured` marker file — skips if present
   - Waits up to 30 seconds for the printer at `/dev/usb/lp0`
   - Sends the command to the printer
   - Detects if the printer reboots (some commands like `buzzer.bin` end with `reset_printer`)
   - If the printer reboots, waits up to 30 seconds for it to recover + 2 seconds for firmware init
   - Creates the `<name>.bin.configured` marker file
3. If the printer disappears and doesn't recover, the script exits — unconfigured commands will be retried on next boot

## File Locations

| File | Purpose |
|------|---------|
| `/usr/local/lib/eatabit/bin/printer-config.sh` | Main script |
| `/usr/local/lib/eatabit/escpos/printer-config/` | Config directory containing `.bin` files |
| `/usr/local/lib/eatabit/escpos/printer-config/*.bin.configured` | Per-command marker files |
| `/etc/systemd/system/printer-config.service` | Systemd unit |

## Current Configurations

- **buzzer.bin** — Disables human voice alerts, enables buzzer. Ends with `reset_printer` (causes printer reboot).
- **wifi-disable.bin** — Disables the printer wifi radio. Ends with `save_param_zone` (no reboot).

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

Add new `.bin` files to the config directory in the build script (`stage3/13-install-printer-config/00-run.sh`). The script sends all `.bin` files alphabetically. If a command causes a printer reboot, the script will automatically detect and recover before sending the next command.

## Logs

```bash
journalctl -u printer-config
```
