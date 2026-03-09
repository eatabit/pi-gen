# Stage 07 — Health Monitor

## Overview

The health monitor is a Node.js service that collects system health data from the Raspberry Pi and writes it to `/usr/local/lib/eatabit/health.json`. It runs as a systemd oneshot service triggered by a timer every 15 minutes.

## Files

| File | Description |
|------|-------------|
| `00-run.sh` | pi-gen build script — installs the script, creates systemd unit files, enables the timer |
| `files/health-monitor.js` | Node.js script that collects health data and writes the JSON output |

## Systemd Configuration

### Service (`health-monitor.service`)

- **Type:** `oneshot` — runs once per invocation, not a long-running daemon
- **User:** `root` — required for reading system metrics and service status
- **Logs:** stdout/stderr routed to journald under the `health-monitor` syslog identifier

### Timer (`health-monitor.timer`)

- **OnBootSec:** `1min` — first run 1 minute after boot
- **OnUnitActiveSec:** `15min` — subsequent runs every 15 minutes
- **Persistent:** `true` — if a scheduled run is missed (e.g., device was off), it runs immediately on next boot

## Health Data Schema

The script writes a single JSON file to `/usr/local/lib/eatabit/health.json` with the following structure:

```json
{
  "timestamp": "ISO 8601 string",
  "device": { ... },
  "system": { ... },
  "services": { ... },
  "network": { ... }
}
```

### `device`

Static device identification from Node.js `os` module:

| Field | Source | Example |
|-------|--------|---------|
| `hostname` | `os.hostname()` | `"eatabit-abc123"` |
| `platform` | `os.platform()` | `"linux"` |
| `arch` | `os.arch()` | `"arm"` |
| `type` | `os.type()` | `"Linux"` |

### `system`

| Field | Source | Notes |
|-------|--------|-------|
| `uptime.seconds` | `os.uptime()` | Integer seconds |
| `uptime.formatted` | Computed | Format: `Xd Xh Xm Xs` |
| `loadAverage` | `os.loadavg()` | Array of 3 floats (1, 5, 15 min) |
| `totalMemory` | `os.totalmem()` | Bytes |
| `freeMemory` | `os.freemem()` | Bytes |
| `cpuCount` | `os.cpus().length` | Integer |
| `disk` | Shell commands | See below |

#### `system.disk`

Disk usage is collected via shell commands (`df`, `du`):

| Field | Source | Notes |
|-------|--------|-------|
| `root.total` | `df /` | Bytes (converted from 1K blocks) |
| `root.used` | `df /` | Bytes |
| `root.free` | `df /` | Bytes |
| `root.usagePercent` | `df /` | Integer percentage |
| `eatabit.size` | `du -sb /usr/local/lib/eatabit` | Bytes |
| `eatabit.usagePercent` | Computed | `eatabitSize / rootTotal * 100`, rounded |
| `varLog.size` | `du -sb /var/log` | Bytes |

### `services.mqttClient`

Status of the `mqtt-client` systemd service, collected via `systemctl`:

| Field | Source | Notes |
|-------|--------|-------|
| `active` | `systemctl is-active` | Boolean |
| `enabled` | `systemctl is-enabled` | Boolean |
| `state` | `systemctl is-active` | String (`"active"`, `"inactive"`, etc.) |
| `mainPID` | `systemctl show` | String or null |
| `memoryUsage` | `systemctl show` → `MemoryCurrent`, falls back to `/proc/{pid}/status` VmRSS | String (bytes) or null |
| `cpuUsageNsec` | `systemctl show` → `CPUUsageNSec` | String (nanoseconds) or null |
| `restartCount` | `systemctl show` → `NRestarts` | String, defaults to `"0"` |
| `lastTimestamp` | `systemctl show` → `StateChangeTimestamp` | String or null |

**Memory fallback:** If `MemoryCurrent` is unavailable (requires `MemoryAccounting=true` in cgroup config), the script reads VmRSS from `/proc/{pid}/status` and converts KB to bytes.

### `network.wifi`

WiFi status collected via `iwconfig`, `iwlist`, `ip`, and `/etc/resolv.conf`:

| Field | Source | Notes |
|-------|--------|-------|
| `connected` | Derived | `true` if SSID is non-empty |
| `ssid` | `iwconfig wlan0` → `ESSID` | String or null |
| `ipAddress` | `ip addr show wlan0` → first `inet` entry | CIDR notation or null |
| `gateway` | `ip route show` → default route | String or null |
| `dnsServers` | `/etc/resolv.conf` → `nameserver` lines | Array of strings |
| `signalStrength` | `iwlist wlan0 last` → `Signal level` | Integer (dBm) or null |
| `linkQuality` | `iwconfig wlan0` → `Link Quality` | String (e.g., `"70/100"`) or null |

## Downstream Consumers

The health data file is consumed by two other services (as noted in the script header):

1. **mqtt-client** (`stage3/03-install-mqtt-client`) — reads `health.json` and publishes it to AWS IoT Core over MQTT
2. **ble-config** (`stage3/08-ble-config`) — reads `health.json` to print a diagnostics page on the thermal printer

Any changes to the health data schema require updating both consumers.

## Error Handling

- Each data collection function catches errors independently and returns partial data with an `error` field rather than crashing the entire script
- The script exits with code `0` on success, `1` on failure to write the health file or on unhandled errors
- Shell commands use `2>/dev/null` with fallback values (`|| echo ''`) to handle missing commands or interfaces gracefully

## Installation Path

During the pi-gen build, the script is installed to:

```
/usr/local/lib/eatabit/bin/health-monitor.js
```

The output file is written to:

```
/usr/local/lib/eatabit/health.json
```

The directory is created automatically (with `recursive: true`) if it doesn't exist.
