# MQTT Client High Availability

A multi-layered strategy to ensure the MQTT client stays connected and recovers automatically when it can't.

## Problem Statement

### Incident Timeline

| Time | Event |
|------|-------|
| 14:44:43 | `Connection interrupted: AWS_ERROR_MQTT_TIMEOUT` — SDK fires `interrupt` event |
| 14:44:43 – 15:07:25 | Process alive, SDK auto-reconnect silently failing, device offline |
| 15:07:25 | Manual reboot restores connectivity |

**Duration offline: 23+ minutes with no automatic recovery.**

### What Failed

1. The AWS IoT Device SDK v2 `interrupt` event fired once at 14:44:43, then the SDK attempted auto-reconnect internally using exponential backoff.
2. Auto-reconnect never succeeded — likely due to a transient network issue that resolved but left the SDK's internal state stuck.
3. The process never crashed — it sat idle in the Node.js event loop waiting for a resume event that never came.
4. `Restart=on-failure` in the systemd unit only triggers on non-zero exit codes. The process didn't exit at all.
5. No mechanism existed to detect that the connection had been down for too long.

### Impact

The device was unreachable for 23+ minutes during business hours. Print jobs queued in the cloud were not delivered. The device required a manual reboot to recover — unacceptable for an unattended device.

## Current Architecture Gaps

### `mqtt-client.js`

- **No connection state tracking** — The process doesn't maintain an `isConnected` flag or track how long it's been disconnected. The `interrupt` and `resume` events only toggle the status LED.
- **No watchdog timer** — Nothing checks "have I been disconnected for too long?" and takes corrective action.
- **No self-healing** — The process relies entirely on the SDK's internal reconnect, with no fallback if it gets stuck.

### `mqtt-client.service`

- **`Restart=on-failure`** — Only restarts the service if the process exits with a non-zero code. Does not help when the process is alive but non-functional.
- **`Type=simple`** — systemd considers the service "started" as soon as the process spawns. No liveness verification.
- **No `WatchdogSec`** — systemd has no mechanism to detect a hung process.
- **No restart limits or escalation** — If the service enters a restart loop, there's no circuit breaker or escalation to a full reboot.

### `health-monitor.js`

- **No connection state in health data** — The health shadow reports system metrics (CPU, memory, disk) and `mqtt-client` service status via `systemctl`, but has no visibility into the MQTT connection state itself. A process can be `active (running)` in systemd while its MQTT connection is dead.

## Strategy Overview

Three layers of defense, each catching failures the previous layer missed:

```
Layer 1: Application Watchdog (mqtt-client.js)
  "Am I still connected? If not for > 2.5 min, exit."
  ↓ process.exit(1) triggers...

Layer 2: Systemd Watchdog (WatchdogSec + sd_notify)
  "Is the process still alive AND responsive? If not, kill it."
  ↓ SIGABRT triggers...

Layer 3: Restart Escalation (systemd limits)
  "Has this service restarted too many times? Reboot the device."
  ↓ reboot-force triggers...
```

**Layer 1** handles the common case (network blip → stuck reconnect) with a fast, lightweight recovery. **Layer 2** catches event-loop hangs, memory leaks, and other process-level failures — it does NOT monitor connection state. **Layer 3** is the last resort for persistent infrastructure problems that survive service restarts.

**Design principle:** Each layer catches a distinct failure mode. Layer 1 owns disconnect detection. Layer 2 owns process liveness. Watchdog pings (`WATCHDOG=1`) are sent unconditionally — even when disconnected — so that Layer 2 only fires when the event loop is truly hung, not when the network is down.

## Layer 1: Application Connection Watchdog

**File:** `iot-pi/stage3/03-install-mqtt-client/files/mqtt-client.js`

### Connection State Tracking

Add two module-level variables alongside the existing `mqttConnection` global:

```
let isConnected = false;
let lastConnectedAt = null;        // Date.now() timestamp
let lastDisconnectedAt = null;     // Date.now() timestamp
```

Update these in the existing connection event handlers:

| Event | Action |
|-------|--------|
| `connect` | `isConnected = true`, `lastConnectedAt = Date.now()` |
| `resume` | `isConnected = true`, `lastConnectedAt = Date.now()` |
| `interrupt` | `isConnected = false`, `lastDisconnectedAt = Date.now()` |
| `disconnect` | `isConnected = false`, `lastDisconnectedAt = Date.now()` |

The existing status LED calls (`setStatusLedConnected` / `setStatusLedDisconnected`) already run in these handlers, so the state tracking piggybacks on the same code paths.

### Watchdog Timer

After `connection.connect()` succeeds and subscriptions are established, start a `setInterval` watchdog:

```
const WATCHDOG_INTERVAL_MS = 60_000;      // Check every 60 seconds
const MAX_DISCONNECT_DURATION_MS = 150_000; // 2.5 minutes
```

Every 60 seconds the watchdog checks:

1. Send `sd_notify("WATCHDOG=1")` unconditionally (see Layer 2).
2. If `isConnected === true` → log nothing, no further action.
3. If `isConnected === false`:
   - Log: `"Watchdog check: disconnected for ${duration}ms"` — creates a trail in `mqtt-client.log` leading up to any Layer 2 kill.
   - If `Date.now() - lastDisconnectedAt > MAX_DISCONNECT_DURATION_MS`:
     - Log: `"Connection watchdog triggered: disconnected for ${duration}ms, exiting to trigger systemd restart"`
     - Publish a `connectionWatchdogTriggered` event (best-effort, may fail since disconnected).
     - Call `process.exit(1)` to trigger a systemd restart.

### Why `process.exit(1)` Instead of Reconnect Logic

- The SDK already implements reconnect with exponential backoff (1s → 2s → 4s → ... → 128s max). By 2.5 minutes the SDK has attempted ~8 reconnects. If that hasn't succeeded, the SDK's connection state may be corrupt.
- A clean process restart gives a fresh SDK instance, fresh TLS handshake, and fresh MQTT session.
- systemd's `RestartSec=10` provides a brief cooldown before the new process starts.
- This is the simplest, most reliable recovery mechanism — no need to implement custom reconnect logic on top of the SDK's.

### Watchdog Timer Lifecycle

- **Start:** After `connection.connect()` and topic subscriptions complete.
- **Clear:** In both `SIGINT` and `SIGTERM` handlers, alongside the existing `clearInterval(healthInterval)`.
- The watchdog uses `setInterval` (not `setTimeout`) so it runs indefinitely alongside the health publishing interval.

## Layer 2: Systemd Watchdog

**Files:** `mqtt-client.service` (unit changes) + `mqtt-client.js` (sd_notify integration)

### Purpose

Layer 1 relies on the Node.js event loop being functional — if the watchdog `setInterval` callback can run, it can detect a stuck connection. But if the event loop itself is blocked (infinite loop, memory pressure, deadlock in native code), the timer never fires.

The systemd watchdog detects this: if the process doesn't send a `WATCHDOG=1` notification within the configured interval, systemd kills and restarts it.

### Service Unit Changes

```ini
[Service]
Type=notify                        # Was: simple. Now systemd waits for READY=1
WatchdogSec=180                    # Expect WATCHDOG=1 every 180 seconds
NotifyAccess=all                   # Allow child processes to send notifications
```

- `Type=notify` means systemd won't consider the service "started" until the process sends `READY=1`. This is more accurate than `Type=simple`, where systemd considers the service running as soon as the process spawns — even if it hasn't connected to MQTT yet.
- `WatchdogSec=180` gives the process 180 seconds between watchdog pings. Since the Layer 1 watchdog runs every 60 seconds, it has three opportunities to send a ping before systemd intervenes. This is deliberately longer than the Layer 1 disconnect threshold (2.5 minutes) so the layers fire in order: Layer 1 at ~2.5 min, Layer 2 at ~3 min.
- `NotifyAccess=all` is required because `systemd-notify` runs as a child process with a different PID than the main `node` process. With `NotifyAccess=main`, systemd would ignore the notifications.

### sd_notify Integration in mqtt-client.js

Notifications are sent by shelling out to the `systemd-notify` CLI (pre-installed on all systemd-based systems). This avoids the `sd-notify` npm package, which is a native C++ addon requiring `libsystemd-dev` to compile — a build dependency not present on the Pi image.

```js
const SdNotify = {
  ready() {
    try { execSync("systemd-notify --ready", { stdio: "ignore" }); } catch {}
  },
  watchdog() {
    try { execSync("systemd-notify WATCHDOG=1", { stdio: "ignore" }); } catch {}
  },
};
```

Because `systemd-notify` runs as a child process (different PID than the main `node` process), the systemd unit must use `NotifyAccess=all` instead of `NotifyAccess=main`. With `NotifyAccess=main`, systemd ignores notifications from any PID other than `MainPID`, which causes it to never receive `READY=1` and kill the service after `TimeoutStartSec`.

**On startup, after connection + subscriptions succeed:**
```
SdNotify.ready()    // Tell systemd the service is ready
```

**In the Layer 1 watchdog timer (every 60s), unconditionally:**
```
SdNotify.watchdog() // Tell systemd the process is alive
```

**Key behavior:** Watchdog pings are sent unconditionally — regardless of MQTT connection state. This cleanly separates the two layers:

- **Layer 1** owns disconnect detection → `process.exit(1)` at 2.5 minutes
- **Layer 2** owns process liveness → `SIGABRT` at ~3 minutes if the event loop is hung

If Layer 1 fires successfully, the process exits cleanly and systemd restarts via `Restart=always`. If the event loop is blocked and Layer 1 can't fire, the watchdog ping also can't be sent, so systemd kills the process at ~3 minutes as a backstop.

### Why `systemd-notify` CLI Instead of the `sd-notify` npm Package

The `sd-notify` npm package is a native C++ addon that requires `libsystemd-dev` headers to compile via `node-gyp`. The Pi image does not include `libsystemd-dev`, and adding it would pull in unnecessary build dependencies on every device. The `systemd-notify` CLI is part of the `systemd` package itself — pre-installed on all systemd-based systems with zero additional dependencies.

The `try/catch` with `stdio: "ignore"` ensures the calls are silent no-ops when running outside systemd (e.g., during development where `systemd-notify` may not be available or `$NOTIFY_SOCKET` is unset).

### Why Unconditional Pings

Sending `WATCHDOG=1` even when disconnected ensures clean separation of concerns:

- **Layer 1** detects: "MQTT connection has been down too long" → clean `process.exit(1)`
- **Layer 2** detects: "Event loop is hung / process is unresponsive" → `SIGABRT` kill

If pings were conditional on `isConnected`, a network outage would trigger Layer 2 (process kill) instead of Layer 1 (clean exit), bypassing the graceful shutdown, `connectionWatchdogTriggered` event, and duration logging. Unconditional pings guarantee Layer 1 always fires first for disconnect scenarios.

## Layer 3: Restart Escalation

**File:** `iot-pi/stage3/03-install-mqtt-client/00-run.sh` (systemd unit section)

### Service Unit Changes

```ini
[Service]
Restart=always                      # Was: on-failure. Now covers ALL exit scenarios
RestartSec=10                       # Already set, keep it
StartLimitIntervalSec=600           # 10-minute sliding window
StartLimitBurst=5                   # Allow 5 restarts in that window
```

```ini
[Unit]
StartLimitAction=reboot-force       # If start limit exceeded, force reboot
```

### Behavior

| Scenario | What Happens |
|----------|-------------|
| Single disconnect > 2.5 min | Layer 1 exits → systemd restarts in 10s → fresh connection |
| Event loop hang | Layer 2 kills process after ~180s → systemd restarts in 10s |
| Network down, 5 restarts in 10 min | Start limit exceeded → `reboot-force` → full device reboot |
| Clean shutdown (SIGTERM) | `Restart=always` restarts even on exit code 0 — handle with `systemctl stop` which sets a "stop" state that suppresses restart |

### Why `Restart=always` Instead of `on-failure`

- `on-failure` only restarts on non-zero exit codes and abnormal signals.
- `Restart=always` also restarts on clean exits (`exit(0)`), which catches edge cases like the SIGINT/SIGTERM handlers calling `process.exit(0)` during unexpected shutdowns.
- `systemctl stop` still works correctly — systemd distinguishes between "process exited" and "administrator stopped the service."

### Why `reboot-force`

- This is the nuclear option. If the MQTT client can't stay running for more than 2 minutes at a time (5 restarts in 10 minutes), something is fundamentally broken — corrupted state, hardware issue, kernel module failure, etc.
- `reboot-force` is equivalent to `reboot -f` — it bypasses `init` and immediately reboots. This ensures recovery even if systemd or the init system is partially hung.
- An alternative is `FailureAction=reboot` (graceful reboot) if a cleaner shutdown is preferred. Use `reboot-force` for maximum reliability on unattended devices.

## Observability Improvements

### Connection State Logging

Enhance the existing event handlers and watchdog timer to log durations. All messages go through the existing `log()` function, which writes to both `stdout` and `mqtt-client.log`.

**On `interrupt`:**
```
Connection interrupted: ${error} (was connected for ${duration}ms)
```

**On `resume`:**
```
Connection resumed (was disconnected for ${duration}ms)
```

**On each watchdog cycle when disconnected (every 60s):**
```
Watchdog check: disconnected for ${duration}ms
```

This is critical for Layer 2 visibility. If the event loop hangs and systemd kills the process via `SIGABRT`, there are no application-level log entries for the kill itself. These periodic log lines create a trail in `mqtt-client.log` showing the disconnect duration was increasing before the process died — making it diagnosable after the fact via `journalctl` or the log file.

**On watchdog trigger (Layer 1):**
```
Connection watchdog triggered: disconnected for ${duration}ms, exiting to trigger systemd restart
```

All durations are computed from `lastConnectedAt` and `lastDisconnectedAt`.

### Log Visibility by Layer

| Layer | Logged to mqtt-client.log | Logged to journalctl |
|-------|--------------------------|---------------------|
| Layer 1 (app watchdog) | Yes — trigger message before `process.exit(1)` | Yes — via stdout/stderr |
| Layer 2 (systemd watchdog) | No — `SIGABRT` kills the process immediately | Yes — systemd logs `watchdog timeout` |
| Layer 3 (reboot-force) | No — reboot bypasses init | Yes — if journal survives reboot |

The periodic `"Watchdog check: disconnected for..."` log lines bridge the gap for Layer 2: even though the kill itself isn't logged by the application, the preceding entries show the disconnect was in progress.

### Cloud Event on Watchdog Trigger

Before calling `process.exit(1)`, attempt to publish a `connectionWatchdogTriggered` event:

```json
{
  "event": "connectionWatchdogTriggered",
  "disconnectedForMs": 300000,
  "lastConnectedAt": "2025-01-15T14:44:43.000Z",
  "triggeredAt": "2025-01-15T14:49:43.000Z"
}
```

This is best-effort — if the connection is truly down, the publish will fail silently. But in cases where the SDK thinks it's disconnected but the network is actually fine (stale state), this event may succeed and provide cloud-side visibility.

### Health Shadow Integration

Add connection state fields to the health shadow (reported state), published by the existing `publishHealthData()` function:

```json
{
  "state": {
    "reported": {
      "connection": {
        "isConnected": true,
        "lastConnectedAt": "2025-01-15T14:44:43.000Z",
        "lastDisconnectedAt": null,
        "watchdogTriggerCount": 0,
        "uptimeMs": 3600000
      }
    }
  }
}
```

- `watchdogTriggerCount` — incremented each time Layer 1 fires (persisted in memory, resets on process restart). Useful for identifying devices with chronic connectivity issues.
- `uptimeMs` — time since the last successful `connect` or `resume` event. Provides a quick "connection health" signal in the device fleet dashboard.

The `health-monitor.js` service does NOT need changes — it reports systemd-level service status. The MQTT connection state is reported directly by `mqtt-client.js` via the health shadow.

## Implementation Checklist

### 1. `mqtt-client.js` — Connection State Tracking
Add `isConnected`, `lastConnectedAt`, `lastDisconnectedAt` module-level variables. Update them in the `connect`, `resume`, `interrupt`, and `disconnect` event handlers.

### 2. `mqtt-client.js` — Watchdog Timer
Add `setInterval` watchdog after `connection.connect()`. Check disconnection duration every 60s. Log `"Watchdog check: disconnected for ${duration}ms"` each cycle when disconnected to create a trail in `mqtt-client.log`. Call `process.exit(1)` if disconnected for > 2.5 minutes. Clear the interval in SIGINT/SIGTERM handlers.

### 3. `mqtt-client.js` — sd_notify Integration
Send `READY=1` after connection + subscriptions. Send `WATCHDOG=1` unconditionally in the watchdog timer (every 60s, regardless of connection state). Uses `systemd-notify` CLI via `execSync` — no npm package required.

### 4. `mqtt-client.js` — Connection Duration Logging
Add duration calculations to `interrupt` and `resume` log messages.

### 5. `mqtt-client.js` — Watchdog Trigger Event
Publish `connectionWatchdogTriggered` event (best-effort) before `process.exit(1)`.

### 6. `mqtt-client.js` — Health Shadow Connection State
Add `connection` object to the health shadow reported state in `publishHealthData()`.

### 7. `00-run.sh` — Systemd Unit Updates
Change `Type=simple` → `Type=notify`. Add `WatchdogSec=180`, `NotifyAccess=all`. Change `Restart=on-failure` → `Restart=always`. Add `StartLimitIntervalSec=600`, `StartLimitBurst=5`. Add `StartLimitAction=reboot-force` to `[Unit]`.

### 8. `mqtt-client.js` — Device Ready Flag Persistence
The `hasDeviceReadyPrinted` flag (which prevents duplicate ready receipts) was an in-memory variable that reset on every process restart. With `Restart=always`, every service restart printed the receipt again. Fix: persist the flag to `/tmp/eatabit-device-ready-printed`. The flag file survives service restarts but is cleared on reboot (`/tmp` is a tmpfs), preserving the "once per power cycle" behavior. `/tmp` is already in `ReadWritePaths`.

### 9. Test — Simulate Disconnect
Verify Layer 1 by blocking MQTT traffic with `iptables` and confirming the process exits after 2.5 minutes. Verify `mqtt-client.log` contains `"Watchdog check: disconnected for..."` entries leading up to the exit. Verify systemd restarts the service within 10 seconds. Verify the status LED toggles correctly through the restart cycle.

### 10. Test — Simulate Hung Process
Verify Layer 2 by adding a deliberate `while(true){}` block and confirming systemd kills the process after ~180s.

### 11. Test — Restart Escalation
Verify Layer 3 by causing rapid restarts (e.g., invalid certificates) and confirming the device reboots after 5 failures in 10 minutes.
