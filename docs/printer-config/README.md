# Printer Config Service

Sends ESC/POS configuration commands to the thermal printer on first boot. Runs once and skips on subsequent boots to avoid overriding user-configured settings.

## How It Works

1. The `printer-config.service` systemd unit runs after `boot-print.service` and before operational services (`mqtt-client`, `ble-config`, `device-reset`)
2. The script checks for a marker file at `/usr/local/lib/eatabit/escpos/printer-config/.configured`
3. If the marker exists, the script logs "Printer already configured, skipping" and exits
4. If not, it waits up to 30 seconds for the printer at `/dev/usb/lp0`
5. Sends all `.bin` files from the config directory to the printer with a 2-second delay between each
6. Creates the `.configured` marker file

## File Locations

| File | Purpose |
|------|---------|
| `/usr/local/lib/eatabit/bin/printer-config.sh` | Main script |
| `/usr/local/lib/eatabit/escpos/printer-config/` | Config directory containing `.bin` files |
| `/usr/local/lib/eatabit/escpos/printer-config/.configured` | Marker file (presence = skip) |
| `/etc/systemd/system/printer-config.service` | Systemd unit |

## Current Configurations

- **buzzer.bin** - Disables human voice alerts, enables buzzer (source: `iot-pi/docs/ESCPOS/Custom Setup Commands.md`)

## Re-running Configuration

Delete the marker file and reboot:

```bash
rm /usr/local/lib/eatabit/escpos/printer-config/.configured && reboot
```

## Adding New Configurations

Add new `.bin` files to the config directory in the build script (`stage3/13-install-printer-config/00-run.sh`). The script sends all `.bin` files alphabetically.

## Logs

```bash
journalctl -u printer-config
```
