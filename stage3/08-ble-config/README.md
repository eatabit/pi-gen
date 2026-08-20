# 08-ble-config — BLE WiFi Configuration Service

## Overview

`ble-config.js` is a Node.js BLE (Bluetooth Low Energy) GATT server that runs on the Raspberry Pi as a systemd service. It allows the Eatabit mobile app (iot-expo) to configure WiFi credentials, adjust printer settings, run diagnostics, and factory-reset the device — all over Bluetooth, without requiring an existing network connection.

Built on the [`@abandonware/bleno`](https://github.com/nicedoc/bleno) library.

## How It Starts

1. `00-run.sh` installs the script to `/usr/local/lib/eatabit/bin/ble-config.js` during the pi-gen image build.
2. Three systemd services are created:
   - **`bluetooth.service`** — system Bluetooth daemon
   - **`bluetooth-poweron.service`** — oneshot that unblocks rfkill and powers on Bluetooth at boot
   - **`ble-config.service`** — the main GATT server, runs as root, restarts on failure every 10s
3. A fourth surface, easy to miss: `00-run.sh` also writes a managed block into
   **`/etc/bluetooth/main.conf`**, delimited by `# >>> eatabit BLE configuration …`
   markers. Bluetooth is configured for always-advertising, non-pairable **LE-only**
   operation with fast connection intervals (7–9 × 1.25 ms).

### The radio is shared with WiFi (BUG-040)

The CYW43438 puts WiFi and Bluetooth on **one 2.4 GHz front-end and one antenna**,
time-division multiplexed. Bluetooth radio-on time is WiFi airtime taken away, and it
was measured to matter a great deal: with Bluetooth on, first-hop jitter to the gateway
was **22.363 ms**; with it off, **2.668 ms** — an 8.4× difference, with WiFi untouched
between the two arms (ISSUE-064 finding 10). That jitter is enough to blow the MQTT
client's ~3 s ping-response window and tear down a healthy connection.

**Everything in the pairing flow is Bluetooth Low Energy.** `ble-config.js` advertises
through bleno (LE advertising, LE GATT) and the mobile app discovers it with
`react-native-ble-plx`'s `startDeviceScan`, which is LE-only and matches on the LE
advertisement's local name. Nothing issues a classic BR/EDR inquiry. So the stage
configures the controller **LE-only** (`ControllerMode = le`) and no longer runs
`bluetoothctl discoverable on`, which is what used to leave a provisioned device page-
and inquiry-scanning (`hciconfig -a` → `UP RUNNING PSCAN ISCAN`) around the clock.

**LE advertising itself is never gated.** It does not depend on WiFi state, on
NetworkManager, on a dispatcher hook or on a timer. This is deliberate and it is the
most important property of the design: BLE is the last-resort way into a Pi Zero 2 W —
there is no Ethernet, SSH rides the WiFi, and the only other recovery is pulling the SD
card — so making BLE conditional would create a way for a device to become permanently
unreachable that does not exist today. The device is never less discoverable than
before. See `iot-doc/tracking/bugs/BUG-040-ble-config-permanent-scan-degrades-wifi/`.

**Four keys removed from the block** — `InitiallyPowered`, `Discoverable`, `Pairable`
and `[LE] Autoconnect` are **not BlueZ options** (checked against bluez 5.79
`src/main.conf`; trixie ships 5.79+). They never did anything. `Discoverable = true` in
particular looked like the reason the device was permanently discoverable; it was not.

> **Editing the block: no backticks, no `$`.** `00-run.sh` feeds these heredocs through
> `on_chroot << EOF`, which is **unquoted**, so the *build host* expands the body before
> the chroot sees it — a backtick in a comment runs that command on the build machine
> and substitutes an empty string into the shipped file. It fails silently. The tests in
> `tests/` assert against this, and against byte-identity with the field patch payload.

## Device Identity

The BLE advertisement name is **`Eatabit-XXXX`** where `XXXX` is the last 4 characters of the device serial number. Serial number resolution order:

1. `/usr/local/lib/eatabit/deviceid` (set by cloud-init user-data)
2. `/proc/device-tree/serial-number`
3. `/proc/cpuinfo` Serial field
4. Fallback: `Eatabit-XXXX`

## GATT Service & Characteristics

Single primary service UUID: `8f4c9b0e-5e57-4f9f-9a2a-4b6f8de9a3c1`

| Characteristic | UUID | Properties | Description |
|---|---|---|---|
| **SSID** | `0e2f3e4b-d9e2-4d0c-8a6c-2bbd2f40c3a7` | Read, Write | Get/set target WiFi SSID |
| **Password** | `9c0fb5a7-6be4-4a38-b5d2-1c8af8d2a0bd` | Write | Set WiFi password (write-only for security) |
| **Apply** | `3b1f7d6e-2cda-43c7-8c92-d0f7b8c0b6d2` | Write | Write any value to trigger WiFi connection |
| **Status** | `a2e6d8f3-71ac-4c17-8d79-7d7f4f5c2e43` | Read, Notify | Connection status notifications (subscribe for live updates) |
| **Config Status** | `c4d5e6f7-8a9b-0c1d-2e3f-4a5b6c7d8e9f` | Read | Returns `"0"` (no WiFi configured) or `"1"` (has saved networks) |
| **Scan** | `b3d4f5e6-7a8b-9c0d-1e2f-3a4b5c6d7e8f` | Read, Write, Notify | Write `"SCAN"` to trigger WiFi scan; results sent as chunked notifications |
| **Cutter Type** | `e1f2a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b` | Read, Write | Printer cut mode: `"partial"`, `"full"`, or `"none"` |
| **Volume** | `f2a3b4c5-6d7e-8f9a-0b1c-2d3e4f5a6b7c` | Read, Write | Printer volume: `0`–`8` (0 = off) |
| **Diagnostics** | `d1a2b3c4-5e6f-7a8b-9c0d-1e2f3a4b5c6d` | Write | Write any value to print a diagnostics page |
| **Reset** | `a1b2c3d4-e5f6-7a8b-9c0d-2e3f4a5b6c7d` | Write | Write any value to delete all WiFi profiles and reboot |

## WiFi Configuration Flow

The mobile app performs these steps in order:

1. **Write SSID** to the SSID characteristic
2. **Write password** to the Password characteristic
3. **Subscribe** to the Status characteristic for notifications
4. **Write** any value to the Apply characteristic

### Apply Logic (`applyWiFiConfig`)

1. Validates SSID and password are set
2. Checks if already connected to the target SSID via `nmcli` — if so, returns early with status `0|0|0`
3. Deletes any existing connection profile with the same name
4. Creates a new NetworkManager profile:
   - **With password**: `wifi-sec.key-mgmt wpa-psk` (WPA/WPA2/WPA3)
   - **Without password**: open network (no security)
   - **Fallback**: if WPA-PSK profile creation fails, attempts WEP
5. Brings the connection up with `nmcli con up`
6. Verifies connection by checking `wlan0` device state

## Status Notification Protocol

Status codes are compact strings: **`{method}|{result}|{detail}`**

### Method Codes
| Code | Method |
|------|--------|
| 0 | WiFi config (applyWiFiConfig) |
| 1 | WiFi scan |
| 2 | System/general |

### Result Codes
| Code | Meaning |
|------|---------|
| 0 | Failure |
| 1 | Success |
| 2 | In-progress |

### Detail Codes (Method 0 — WiFi)
| Code | Meaning |
|------|---------|
| 0 | Already connected (early-out) |
| 1 | SSID or password not set |
| 2 | Connection verification failed |
| 3 | General error |
| 4 | Successfully connected |
| 5 | Connecting (in-progress) |

Example: `0|2|5` = WiFi config, in-progress, connecting.

## WiFi Scan

Writing `"SCAN"` to the Scan characteristic triggers `nmcli dev wifi list`. Results are:

- Filtered to signal strength >= 30
- Sorted by signal strength (descending)
- Serialized as JSON with compact keys: `ss` (SSID), `sg` (signal %), `en` (encrypted boolean), `cx` (currently active)

### Chunked BLE Transfer

Scan results are split into MTU-sized chunks and sent as sequential notifications:

```
{chunkIndex}|{totalParts}|{jsonPayload}
```

Each chunk is sent with a 100ms delay between notifications to avoid BLE congestion. The client reconstructs the full JSON by concatenating payloads from chunk 0 through totalParts-1.

## Persistent Settings

Two printer settings are persisted to JSON config files in `/usr/local/lib/eatabit/config/`:

| Setting | File | Default | Values |
|---------|------|---------|--------|
| Cutter type | `cutter-type.json` | `"partial"` | `"partial"`, `"full"`, `"none"` |
| Volume | `volume.json` | `4` | `0`–`8` (0 = off) |

Both are loaded at startup and saved on every write. Config directories are created with mode `0o777` and files with `0o666` to ensure accessibility across services.

## Diagnostics Page

The Diagnostics characteristic triggers a thermal print job that outputs:

1. **Header** — "DIAGNOSTICS" title (double-size, bold, centered)
2. **System** — uptime, load average, memory usage, disk usage, CPU count (from `health.json`)
3. **Network** — WiFi connection status, SSID, IP, gateway, signal strength, link quality
4. **Services** — running/stopped status for all monitored services
5. **Device** — hostname, platform, architecture
6. **Device ID QR Code** — ESC/POS QR code of the device ID (model 2, module size 6, error correction L)
7. **Printer Serial** — serial number from `udevadm` info on `/dev/usb/lp0`, plus QR code
8. **Footer** — paper feed + partial cut

The output is raw ESC/POS binary written directly to `/dev/usb/lp0`.

## Factory Reset

The Reset characteristic:

1. Lists all WiFi (`802-11-wireless`) profiles via `nmcli`
2. Deletes each one
3. Writes `lastResetAt` timestamp to `health.json`
4. Reboots the device after a 3-second delay (to allow the BLE response to reach the client)

## Logging

All operations log to both stdout/stderr (captured by journald) and `/usr/local/lib/eatabit/log/ble-config.log`. Log format:

```
[2026-03-09 14:30:00.123] [INFO] Message here
```

## Connection Lifecycle

- **`accept`** — logs client address
- **`disconnect`** — clears all notification subscriber lists (`statusClients`, `scanClients`)
- **`mtuChange`** — logged; MTU size is used for scan result chunking

## File Paths

| Path | Purpose |
|------|---------|
| `/usr/local/lib/eatabit/bin/ble-config.js` | Installed script location |
| `/usr/local/lib/eatabit/deviceid` | Device serial number |
| `/usr/local/lib/eatabit/health.json` | Health data (read for diagnostics, written on reset) |
| `/usr/local/lib/eatabit/config/cutter-type.json` | Persisted cutter type setting |
| `/usr/local/lib/eatabit/config/volume.json` | Persisted volume setting |
| `/usr/local/lib/eatabit/log/ble-config.log` | Application log file |
| `/dev/usb/lp0` | Thermal printer device |
| `/etc/bluetooth/main.conf` | BlueZ config; carries the eatabit managed block (BUG-040) |
| `/etc/systemd/system/bluetooth-poweron.service` | rfkill unblock + power on at boot |
| `/etc/systemd/system/ble-config.service` | The GATT server unit |

## Mobile App Integration

The matching client implementation lives in `iot-expo/hooks/useDevice.ts` (and `useBLEv4.ts` / `useBLEv20.ts`), which uses the same service and characteristic UUIDs to discover and interact with this GATT server.
