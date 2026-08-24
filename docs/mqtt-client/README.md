# MQTT Client (`mqtt-client.js`)

Technical reference for the Eatabit MQTT client service that runs on each Raspberry Pi device.

## Overview

The MQTT client is the core service on each Raspberry Pi gateway. It maintains a persistent MQTT connection to AWS IoT Core over mutual TLS, enabling bidirectional communication between the cloud platform and the physical thermal printer attached to the device.

**Responsibilities:**

- Connect to AWS IoT Core using device certificates (mTLS)
- Process print jobs through a multi-stage state machine (queue, download, print)
- Manage three named device shadows (public, private, health)
- Watch local config files for changes from the BLE pairing service
- Execute remote commands (ngrok tunnels, reset, reboot)
- Monitor printer hardware status via DLE/EOT protocol
- Control the status LED to indicate connection state
- Report device health metrics every 15 minutes
- Print a "device ready" receipt on first connection per power cycle

**Runtime:** Node.js, using `aws-iot-device-sdk-v2` for MQTT and `@ngrok/ngrok` for remote access tunnels.

**Platform data flow:** Mobile App / Web Dashboard → Cloud API → EventBridge → IoT Core → **MQTT Client** → Thermal Printer

---

## Installation & Service Configuration

### Install Script (`00-run.sh`)

The `iot-pi/stage3/03-install-mqtt-client/00-run.sh` script runs during the pi-gen image build:

1. Installs `mqtt-client.js` to `/usr/local/lib/eatabit/bin/mqtt-client.js` (mode `0755`)
2. Creates `/usr/local/lib/eatabit/config/` directory (mode `0777`)
3. Installs default config files (`cutter-type.json`, `volume.json`, `light.json`) with mode `0666`
4. Creates the systemd unit file
5. Enables the service via `systemctl enable mqtt-client.service`
6. Configures log rotation

### Systemd Unit

```ini
[Unit]
Description=Eatabit AWS IoT Client Service
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/lib/eatabit/cert/device.pem
ConditionPathExists=/usr/local/lib/eatabit/cert/device.key

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib/eatabit
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/mqtt-client.js
Restart=on-failure
RestartSec=10
TimeoutStopSec=15
KillMode=mixed
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/lib/eatabit/log /tmp /usr/local/lib/eatabit/reset /usr/local/lib/eatabit/config
ReadOnlyPaths=/usr/local/lib/eatabit/cert /usr/local/lib/eatabit/escpos
CPUAccounting=true
MemoryAccounting=true
TasksAccounting=true

[Install]
WantedBy=multi-user.target
```

**Key behaviors:**

- Will not start unless both `device.pem` and `device.key` exist (certificates provisioned by BLE pairing)
- Restarts on failure after 10 seconds
- `KillMode=mixed` sends SIGTERM to the main process, SIGKILL to remaining after `TimeoutStopSec` (15s)
- `ProtectSystem=strict` makes the filesystem read-only except for explicitly listed `ReadWritePaths`

### Log Rotation

```
/usr/local/lib/eatabit/log/mqtt-client.log {
  daily
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
  create 0666 root root
}
```

Logs are rotated daily, keeping 7 days of compressed history.

---

## File System Layout

```
/usr/local/lib/eatabit/
├── bin/
│   ├── mqtt-client.js          # This service
│   └── status-led.sh           # GPIO LED control script
├── cert/                        # Read-only (provisioned by BLE pairing)
│   ├── device.pem              # Device X.509 certificate
│   ├── device.key              # Device private key
│   └── AmazonRootCA1.pem       # AWS root CA certificate
├── config/                      # Read-write (shared with BLE service)
│   ├── cutter-type.json        # Printer cutter setting
│   ├── volume.json             # Speaker volume setting
│   └── light.json              # Light on/off setting
├── escpos/
│   └── deviceReady.escpos      # Pre-compiled ESC/POS receipt for "device ready"
├── log/
│   └── mqtt-client.log         # Application log file
├── reset/
│   └── .reset-flag             # Created by reset command, consumed on next boot
├── deviceid                     # Device identity (serial number)
├── version                      # OS image version string
└── health.json                  # Health metrics (written by external health script)
```

Some state is deliberately **not** on the SD card. `/run/eatabit` is a tmpfs directory
systemd creates for this unit (`RuntimeDirectory=eatabit`,
`RuntimeDirectoryPreserve=restart`), so its contents survive a service restart and are
discarded on stop:

```
/run/eatabit/
├── device-ready-printed        # Guard flag: the "device ready" receipt prints once per boot
├── shadow-public.json          # Snapshot of last reported public shadow state
├── shadow-private.json         # Snapshot of last reported private shadow state
└── shadow-health.json          # Snapshot of last reported health shadow state
```

The shadow snapshots are **write-only debugging artefacts** — nothing reads them back.
The authoritative shadow lives in AWS IoT Core. They were moved here from `config/` by
ISSUE-068: that directory is not RAM-buffered, so rewriting `shadow-health.json` every
15 minutes cost ~159 KiB/day of SD-card writes for state nothing consumed. Losing them
on reboot is harmless — each is rewritten within one heartbeat.

---

## Configuration

### AWS IoT Endpoint

| Setting | Value |
|---|---|
| Endpoint | `a3fw1u2gvi2uac-ats.iot.us-east-2.amazonaws.com` |
| Protocol | MQTT over mutual TLS (X.509 certificates) |
| Client ID | `{DEVICE_ID}` (same as the IoT Thing name) |
| Clean Session | `false` (persistent sessions — queued messages delivered on reconnect) |
| Keep Alive | `30` seconds |
| QoS | `AtLeastOnce` (QoS 1) for all publishes and subscribes |

### Certificate Paths

| File | Path |
|---|---|
| Device certificate | `/usr/local/lib/eatabit/cert/device.pem` |
| Device private key | `/usr/local/lib/eatabit/cert/device.key` |
| Root CA | `/usr/local/lib/eatabit/cert/AmazonRootCA1.pem` |

The MQTT connection is built using `iot.AwsIotMqttConnectionConfigBuilder.new_mtls_builder_from_path()` from `aws-iot-device-sdk-v2`.

---

## Device Identity

The device ID is read at startup from `/usr/local/lib/eatabit/deviceid`. This file is written during the BLE provisioning process and contains the device serial number derived from `/proc/cpuinfo` on the Raspberry Pi.

```javascript
DEVICE_ID = fs.readFileSync(`${EATABIT_DIR}/deviceid`, "utf8").trim();
```

If the file is missing or empty, the process exits with code 1. The device ID is used as:

- The MQTT client ID
- The IoT Thing name in all topic paths
- The identifier in all published event payloads

The image version is also read from `/usr/local/lib/eatabit/version` and reported in the private shadow. If unreadable, it defaults to `"unknown"`.

---

## MQTT Topics

### Subscribed Topics

| Topic | Direction | Description |
|---|---|---|
| `$aws/things/{deviceId}/jobs/notify-next` | Inbound | AWS IoT Jobs notification of the next pending job |
| `$aws/things/{deviceId}/jobs/start-next/accepted` | Inbound | Confirmation that `start-next` was accepted |
| `$aws/things/{deviceId}/jobs/start-next/rejected` | Inbound | Rejection of `start-next` request |
| `$aws/things/{deviceId}/jobs/+/update` | Inbound | Job update messages (wildcard for any job ID) |
| `$aws/things/{deviceId}/jobs/+/update/accepted` | Inbound | Confirmation that a job update was accepted |
| `$aws/things/{deviceId}/jobs/+/update/rejected` | Inbound | Rejection of a job update |
| `$aws/commands/things/{deviceId}/executions/+/request/json` | Inbound | AWS IoT Commands execution requests |
| `$aws/things/{deviceId}/shadow/name/public/update/delta` | Inbound | Public shadow delta (desired != reported) |
| `$aws/things/{deviceId}/shadow/name/private/update/delta` | Inbound | Private shadow delta |
| `$aws/things/{deviceId}/shadow/name/health/update/delta` | Inbound | Health shadow delta |

### Published Topics

| Topic | Direction | Description |
|---|---|---|
| `$aws/things/{deviceId}/jobs/start-next` | Outbound | Request the next queued job |
| `$aws/things/{deviceId}/jobs/{jobId}/update` | Outbound | Update job execution status |
| `$aws/things/{deviceId}/shadow/name/{shadowName}/update` | Outbound | Update shadow reported state |
| `$aws/things/{deviceId}/shadow/name/private/get` | Outbound | Request current private shadow state |
| `$aws/commands/things/{deviceId}/executions/{executionId}/response/json` | Outbound | Command execution response |
| `eatabit/things/{deviceId}/events` | Outbound | Custom events topic (health errors, disconnect) |
| `eatabit/things/{deviceId}/jobs/{jobId}/downloaded` | Outbound | Job downloaded event (for IoT Rules) |
| `eatabit/things/{deviceId}/jobs/{jobId}/printed` | Outbound | Job printed event (for IoT Rules) |

> **Why custom topics?** Reserved `$aws/` topics cannot trigger IoT Rules. Job lifecycle events are republished to `eatabit/` topics so IoT Rules can forward them to EventBridge/Lambda.

---

## AWS IoT Device Shadows

The client manages three named shadows. Each shadow has a distinct source of truth and set of properties.

### Public Shadow

| Property | Type | Default | Description |
|---|---|---|---|
| `light` | `boolean` | `false` | Printer status light on/off |
| `volume` | `number` (0-8) | `4` | Speaker volume (0 = off, 1-8 = level) |
| `cutterType` | `string` | `"partial"` | Paper cut mode: `"partial"`, `"full"`, or `"none"` |

**Source of truth:** Device (local config files).

On connect, the client loads values from local config files (`cutter-type.json`, `volume.json`, `light.json`) and pushes them to the shadow as reported state. This makes the device the authority — the cloud reflects what the device has.

When a delta is received (cloud sets a desired state), the client updates local state, executes hardware commands (e.g., ESC/POS volume change), and reports the new state back.

### Private Shadow

| Property | Type | Default | Description |
|---|---|---|---|
| `apiId` | `string` | `""` | API identifier for the device |
| `imageVersion` | `string` | *(from version file)* | OS image version |

**Source of truth:** Cloud.

On connect, the client publishes a `get` request to fetch the current private shadow state from AWS. Delta messages update the local state.

### Health Shadow

| Property | Type | Default | Description |
|---|---|---|---|
| *(dynamic)* | `object` | `{}` | Contents of `health.json` |

**Source of truth:** Device (health monitoring script).

The health shadow has no defined `properties` array and no desired state. It is read-only from the cloud side. The client reads `/usr/local/lib/eatabit/health.json` and publishes its contents as reported state.

### Shadow Persistence

All shadow states are persisted to disk as JSON files in `/usr/local/lib/eatabit/config/`:

```
shadow-{shadowName}.json
```

Format:

```json
{
  "shadowName": "public",
  "timestamp": "2026-01-15T10:30:00.000Z",
  "state": {
    "light": true,
    "volume": 4,
    "cutterType": "partial"
  }
}
```

Persistence happens on every reported state update and every delta handling.

### Shadow Delta Handling

When a delta message arrives on `$aws/things/{deviceId}/shadow/name/{shadowName}/update/delta`:

1. Extract `shadowName` from the topic via regex
2. Iterate over the shadow's `properties` array
3. For each property present in the desired state, update the local `SHADOW_CONFIG` state
4. Execute property-specific side effects:
   - `volume` → send ESC/POS volume commands to printer
   - `light` → log state change (GPIO control TODO)
   - `cutterType` → log state change
   - `apiId` → log state change
5. Publish updated reported state back to the shadow
6. Persist shadow state to file

---

## Config File Watching

The BLE configuration service writes settings to shared config files. The MQTT client watches these files and syncs changes to AWS IoT shadows.

### Watched Files

| File | Property | Shadow |
|---|---|---|
| `/usr/local/lib/eatabit/config/cutter-type.json` | `cutterType` | public |
| `/usr/local/lib/eatabit/config/volume.json` | `volume` | public |

### Watch Mechanism

Each config file is watched using `fs.watch()` on the parent directory (watching the directory rather than the file handles atomic file replacements):

1. `fs.watch(configDir)` fires on any change in the directory
2. Filter events to only the target filename
3. **Debounce** with a 100ms `setTimeout` to coalesce rapid filesystem events
4. Read and parse the JSON file
5. Validate the value (e.g., `cutterType` must be one of `["partial", "full", "none"]`, `volume` must be 0-8)
6. Compare against current in-memory state
7. If changed: update `SHADOW_CONFIG`, execute hardware commands (volume only), and publish reported state

### Default Config Files

Installed during image build with epoch timestamps:

**`cutter-type.json`**
```json
{
  "cutterType": "partial",
  "timestamp": "1970-01-01T00:00:00.000Z"
}
```

**`volume.json`**
```json
{
  "volume": 4,
  "timestamp": "1970-01-01T00:00:00.000Z"
}
```

**`light.json`**
```json
{
  "light": true,
  "timestamp": "1970-01-01T00:00:00.000Z"
}
```

---

## Job Execution Lifecycle

Print jobs flow through a multi-stage state machine using AWS IoT Jobs.

### State Machine

```
                  ┌──────────────┐
    notify-next   │   QUEUED     │  (job received, written to /tmp/{jobId}.json)
    ───────────►  │  IN_PROGRESS │  publish: status=IN_PROGRESS, event=QUEUED
                  └──────┬───────┘
                         │
               update/accepted (event=QUEUED)
                         │
                         ▼
                  ┌──────────────┐
                  │  DOWNLOADED  │  (ESC/POS file downloaded from S3 URI)
                  │  IN_PROGRESS │  publish: status=IN_PROGRESS, event=DOWNLOADED
                  └──────┬───────┘
                         │
               update/accepted (event=DOWNLOADED)
                         │
                    ┌────┴────┐
                    ▼         ▼
             ┌───────────┐ ┌──────────┐
             │  PRINTED   │ │  FAILED  │  (printer offline, cover open, etc.)
             │ SUCCEEDED  │ │  FAILED  │  status=FAILED, event=PRINTER_OFFLINE
             └─────┬──────┘ └────┬─────┘
                   │              │
                   ▼              ▼
              Clean up        10s delay, then retry
              job files       (FAILED jobs can be retried by AWS IoT Jobs)
```

### Expiration

At every stage (notify-next, download, print), the job's `expiresAt` timestamp is checked against the current time. If expired:

- Status: `REJECTED` (cannot be retried)
- Event: `EXPIRED`

### Topic Flow Detail

**1. Job arrives** — `$aws/things/{deviceId}/jobs/notify-next` or `$aws/things/{deviceId}/jobs/start-next/accepted`

The client:
- Checks for expiration
- Writes job data to `/tmp/{jobId}.json`
- Publishes `IN_PROGRESS` with event `QUEUED` to `$aws/things/{deviceId}/jobs/{jobId}/update`

**2. QUEUED accepted** — `$aws/things/{deviceId}/jobs/{jobId}/update/accepted` (event=QUEUED)

The client:
- Downloads the ESC/POS document from the S3 presigned URI in `execution.jobDocument.uri`
- Saves to `/tmp/{jobId}.escpos` via `curl`
- Publishes `IN_PROGRESS` with event `DOWNLOADED`
- Republishes `DOWNLOADED` event to `eatabit/things/{deviceId}/jobs/{jobId}/downloaded` (for IoT Rules)

**3. DOWNLOADED accepted** — `$aws/things/{deviceId}/jobs/{jobId}/update/accepted` (event=DOWNLOADED)

The client:
- Runs pre-print printer status check
- Sends ESC/POS data to `/dev/usb/lp0` via `cat`
- Waits 2 seconds for printer to process raster data
- Runs post-print printer status check
- On success: publishes `SUCCEEDED` with event `PRINTED`, republishes to `eatabit/things/{deviceId}/jobs/{jobId}/printed`
- On failure: waits 10 seconds (to slow retry cycle), publishes `FAILED` with event `PRINTER_OFFLINE` and the specific reason

**4. Terminal states** — `SUCCEEDED`, `FAILED`, `REJECTED`

Job files (`{jobId}.json` and `{jobId}.escpos`) are cleaned up from `/tmp/`.

### Job Execution Status Mapping

| AWS IoT Status | Event | Meaning |
|---|---|---|
| `IN_PROGRESS` | `QUEUED` | Job received and acknowledged |
| `IN_PROGRESS` | `DOWNLOADED` | ESC/POS document downloaded from S3 |
| `SUCCEEDED` | `PRINTED` | Successfully printed |
| `FAILED` | `PRINTER_OFFLINE` | Printer issue (retryable) |
| `REJECTED` | `EXPIRED` | Job expired (not retryable) |

---

## Printer Communication

### Direct USB Writes

The client bypasses CUPS and writes directly to the printer device at `/dev/usb/lp0`:

```javascript
execSync(`cat "${filePathEscPos}" > /dev/usb/lp0`, { shell: "/bin/bash" });
```

### DLE/EOT Status Protocol

Printer status is queried by sending DLE EOT commands and reading back a single status byte. Three status queries are performed:

| Query | DLE EOT Command | Purpose |
|---|---|---|
| Online status | `\x10\x04\x01` | Check if printer is online (bit 3) |
| Offline cause | `\x10\x04\x02` | Determine why printer is offline |
| Paper status | `\x10\x04\x04` | Check paper presence |

Each command is sent via `printf` to `/dev/usb/lp0`, then a 1-byte response is read with `dd` (1 second timeout) and parsed via `xxd -p`.

### Status Byte Parsing

| Byte | Bit Mask | Condition |
|---|---|---|
| Online (n=1) | `& 0x08` | Bit 3 set = printer offline |
| Offline cause (n=2) | `& 0x04` | Bit 2 set = cover open |
| Offline cause (n=2) | `& 0x40` | Bit 6 set = mechanical error |
| Paper status (n=4) | `& 0xC0` | Bits 6-7 set = out of paper |

### Pre/Post Print Checks

Every print job runs a status check **before** and **after** printing:

1. **Pre-print:** Verify `/dev/usb/lp0` exists (printer powered on), then run DLE/EOT queries
2. 1 second delay after pre-print check (let printer flush DLE/EOT responses)
3. Send ESC/POS data to printer
4. 2 second delay (let printer process raster data)
5. **Post-print:** Run DLE/EOT queries again to verify successful print

If either check fails, the specific `PRINTER_EVENTS` reason is returned.

### Printer Events

| Event | Meaning |
|---|---|
| `POWERED_OFF` | `/dev/usb/lp0` does not exist |
| `COVER_OPEN` | Cover is open (offline cause byte, bit 2) |
| `OUT_OF_PAPER` | Paper roll empty (paper status byte, bits 6-7) |
| `MECHANICAL_ERROR` | Hardware fault (offline cause byte, bit 6) |

---

## ESC/POS Volume Commands

The printer speaker volume is controlled through a proprietary ESC/POS command sequence. Each command is written sequentially to `/dev/usb/lp0`.

### Command Sequence

| Step | Command | Description |
|---|---|---|
| 1 | `UNLOCK_PARAMS_CMD` | Unlock printer parameter zone |
| 2 | Speaker ON/OFF | Enable or disable the speaker |
| 3 | Volume level (1-8) | Set volume level (only if speaker ON) |
| 4 | `SPEAKER_CONFIG_CMD` | Apply speaker configuration |
| 5 | `SAVE_PARAMS_CMD` | Save parameter zone to persistent storage |
| 6 | `RESTART_PRINTER_CMD` | Restart printer to apply speaker ON/OFF changes |

### Volume Values

| Value | Behavior |
|---|---|
| `0` | Speaker OFF (sends disable command, skips level) |
| `1-8` | Speaker ON + set volume level |

### When Volume Changes

Volume commands are executed in two scenarios:

1. **Shadow delta:** Cloud sets a new desired `volume` in the public shadow
2. **Config file change:** BLE service writes a new `volume.json`, detected by `fs.watch()`

---

## Remote Commands

Commands are received on `$aws/commands/things/{deviceId}/executions/+/request/json` and responses are published to `$aws/commands/things/{deviceId}/executions/{executionId}/response/json`.

### `startNgrokTunnel`

Establishes a TCP tunnel to the device's SSH port (22) via ngrok.

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `authToken` | `string` | Yes | ngrok authentication token |

**Behavior:**
1. Close any existing ngrok listener
2. Start `ngrok.forward({ addr: 22, proto: "tcp", authtoken })`
3. On success: respond with `SUCCEEDED`, `ngrokUrl` in both `statusReason.reasonDescription` and `result.ngrokUrl`
4. On failure: respond with `FAILED`, reason code `500`

> The ngrok URL is placed in `statusReason.reasonDescription` because the `$aws/events/commandExecution/+/+` events topic includes `statusReason` but not `result`. This allows IoT Rules to capture the URL.

### `stopNgrokTunnel`

Closes the active ngrok tunnel.

**Parameters:** None.

**Behavior:**
1. If `ngrokListener` exists, call `ngrokListener.close()`
2. On success: respond with `SUCCEEDED`, status `"stopped"`
3. If no active listener: log warning, no response published
4. On failure: respond with `FAILED`, reason code `500`

### `reset`

Sets a reset flag and optionally reboots or shuts down the device.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `action` | `string` | `"reboot"` | Action after reset: `"reboot"` or `"shutdown"` |

**Behavior:**
1. Create `/usr/local/lib/eatabit/reset/` directory if needed
2. Write `"1"` to `/usr/local/lib/eatabit/reset/.reset-flag`
3. Respond with `SUCCEEDED` (including `resetFlagSet: true`, `action`)
4. After 5 second delay: execute `shutdown -r now` or `shutdown -h now`

### `reboot`

Simple device reboot without setting a reset flag.

**Parameters:** None.

**Behavior:**
1. Respond with `SUCCEEDED` (including `rebooting: true`)
2. After 5 second delay: execute `shutdown -r now`

### Command Response Format

All command responses follow the AWS IoT Commands response structure:

```json
{
  "status": "SUCCEEDED | FAILED",
  "statusReason": {
    "reasonCode": "200 | 500",
    "reasonDescription": "..."
  },
  "result": { ... }
}
```

Result values use typed fields: `{ s: "string" }`, `{ b: true }`.

---

## Status LED

The status LED provides visual indication of the MQTT connection state via the `status-led.sh` script.

| State | LED | How |
|---|---|---|
| Connected | Solid green | `systemctl stop status-led-ok.service` then `status-led.sh green` |
| Disconnected | Flashing blue | `systemctl restart status-led-ok.service` |

LED state is updated on four connection events: `connect`, `interrupt`, `resume`, `disconnect`.

---

## Health Monitoring

### Collection

An external health monitoring script writes device metrics to `/usr/local/lib/eatabit/health.json`. The MQTT client reads this file and publishes it as the health shadow's reported state.

### Publishing Schedule

- **On connect:** Health data is published immediately
- **Periodic:** Every 15 minutes (900,000 ms) via `setInterval`
- **On error:** If `health.json` is missing or unparseable, a `health_data_error` event is published to the events topic

### Flow

```
health script → health.json → mqtt-client reads → health shadow reported state
```

---

## Connection Lifecycle

### Startup Sequence

1. Read device ID from `/usr/local/lib/eatabit/deviceid` (exit on failure)
2. Read image version from `/usr/local/lib/eatabit/version`
3. Load local config files into `SHADOW_CONFIG.public.state`
4. Initialize log file
5. Build MQTT connection config (mTLS, endpoint, client ID, clean session=false, keep alive=30s)
6. Register connection event handlers
7. Connect to AWS IoT Core
8. Subscribe to all topics
9. Initialize shadow reported states (public, private)
10. Publish health data
11. Start config file watchers (cutter type, volume)
12. Start 15-minute health reporting interval
13. Wait for shutdown signal

### Connection Event Handlers

**`connect`**
1. Set status LED to solid green
2. Print device ready receipt (once per power cycle, if printer is ready)
3. Load local config and push public shadow reported state
4. Request private shadow state via `get`
5. Publish health data to health shadow
6. Publish `start-next` to request any pending jobs

**`interrupt`**
1. Log the error
2. Set status LED to flashing blue

**`resume`**
1. Log return code and session present flag
2. Set status LED to solid green
3. Publish `start-next` to request any pending jobs

**`disconnect`**
1. Log disconnection
2. Set status LED to flashing blue

**`error`**
1. Log the connection error

### Device Ready Receipt

On the first successful connection per power cycle, the client prints a "device ready" receipt:

1. Check `hasDeviceReadyPrinted` flag (starts `false`)
2. Check printer status via DLE/EOT
3. If ready and `deviceReady.escpos` exists: send it to `/dev/usb/lp0`
4. Set `hasDeviceReadyPrinted = true` (even if skipped, to prevent retries)

This only happens once — subsequent reconnections (after interrupts) do not reprint.

---

## Graceful Shutdown

### Signal Handling

Both `SIGINT` and `SIGTERM` trigger the same shutdown sequence:

1. Log the signal
2. Clear the 15-minute health interval
3. Set a 10-second force exit timeout (`process.exit(0)`)
4. Publish a `"disconnected"` event with the signal reason to the events topic
5. Disconnect the MQTT connection
6. Clear the force exit timeout
7. Resolve the main promise (normal exit)

### Timeouts

| Timeout | Duration | Purpose |
|---|---|---|
| Force exit | 10 seconds | Prevents hung shutdown if MQTT disconnect hangs |
| systemd `TimeoutStopSec` | 15 seconds | systemd sends SIGKILL after this |

The systemd timeout (15s) is longer than the application timeout (10s) to give the process a chance to self-terminate before being killed.

---

## Logging

### Dual Output

Every log message is written to both:
- **Console** (stdout/stderr) — captured by journald via `StandardOutput=journal`
- **File** — appended to `/usr/local/lib/eatabit/log/mqtt-client.log`

### Format

```
[2026-01-15 10:30:00.123] [INFO] Message text
[2026-01-15 10:30:00.456] [ERROR] Error message
```

Timestamp format: `YYYY-MM-DD HH:mm:ss.SSS` (ISO 8601, space-separated, millisecond precision).

### Levels

| Level | Output | Usage |
|---|---|---|
| `INFO` | stdout | Normal operation |
| `WARN` | stdout | Non-critical issues (missing health file, skipped print) |
| `ERROR` | stderr | Recoverable errors (failed publish, printer issues) |
| `FATAL` | stderr | Unrecoverable errors (triggers `process.exit(1)`) |

### Log File Initialization

On startup, the log directory and file are created if they don't exist:
- Directory: mode `0777` (recursive)
- File: mode `0666`

---

## Error Handling

### Certificate Errors

If device certificates don't exist, the systemd `ConditionPathExists` directives prevent the service from starting entirely. If certificates exist but are invalid, the `aws-iot-device-sdk-v2` connection will fail and the process exits with code 1.

### Printer Errors

Printer errors are non-fatal. They cause job failures but the client remains running:

- `/dev/usb/lp0` missing → `POWERED_OFF`
- DLE/EOT timeout → status check failure logged
- Cover open, no paper, mechanical error → job marked `FAILED` with `PRINTER_OFFLINE`
- 10-second delay before reporting failure to slow retry cycles and give users time to fix issues

### Network Errors

- Connection interrupts are handled by the `interrupt` event → LED flashes blue
- Connection resumes are handled by the `resume` event → LED solid green, re-request pending jobs
- `clean_session=false` ensures the broker queues messages during disconnects
- Failed publishes are logged but do not crash the process

### Job Expiration

Expiration is checked at three points:
1. When `notify-next` / `start-next/accepted` is received
2. Before downloading the document
3. Before printing the document

Expired jobs are `REJECTED` (not retryable by AWS IoT Jobs).

### Unhandled Errors

The `main()` function is wrapped in a `.catch()` that logs at `FATAL` level and exits with code 1. Individual message processing errors are caught within the message handler and logged without crashing.
