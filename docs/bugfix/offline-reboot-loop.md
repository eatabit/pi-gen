# Bugfix: Don't reboot-loop a device that has no usable network

## Context

**Problem.** A device that can't reach AWS IoT — because it was factory-reset and has no WiFi
config, or because it temporarily lost network — reboots itself every ~2–4 minutes in an endless
loop. The loop wears the SD card, takes the device offline for BLE provisioning during each
reboot (fighting the one action that would fix an unprovisioned unit), and reprints the boot
"BOOTING / please wait" ticket every cycle (a client wasted a whole roll overnight on an
unconfigured printer).

**Root cause.** On a cold boot with no network, `mqtt-client`'s `await connection.connect()` can
never succeed, so the process never sends systemd `READY=1`. For a `Type=notify` unit that is a
failed start; `Restart=always` retries every `RestartSec=10`, ~5 failed starts land inside the
600s window, and `StartLimitAction=reboot-force` reboots the device. After the reboot the network
is still absent, so it repeats. (The Layer 1 *application* watchdog is irrelevant here — it is
created only *after* a successful connect, so on a never-connected boot it never arms. The loop is
driven entirely by systemd start-failure escalation.)

**Principle.** A reboot can only fix what a reboot can fix. An unprovisioned or offline device
isn't in a broken state a reboot would clear — it just needs the network (or BLE provisioning) to
come back. Both layers already retry that continuously: NetworkManager retries the configured SSID
forever (`connection.autoconnect-retries=0`, commit `3d29c1b`), and the MQTT layer retries via the
SDK's reconnect backoff (after a first connect) or the new initial-connect retry loop below. So the
device should **wait and keep retrying, not reboot**. The only reboot worth keeping is for a
process that repeatedly crashes *before* it can even signal readiness (a genuinely broken image).

This replaces an earlier, abandoned approach that only rate-limited the boot print to stop the
wasted paper. That treated the symptom; this fixes the reboot loop at its source, so the repeated
print never happens in the first place.

## The change — `mqtt-client.js`

**File:** `stage3/03-install-mqtt-client/files/mqtt-client.js`, in `main()` (the startup block
around lines 1649–1764).

1. **Signal readiness early.** Move `SdNotify.ready()` to run right after the connection event
   handlers are registered and *before* `connection.connect()` — not after connect + subscribe.
   The service is "started" as soon as the process is up and listening, regardless of network.
   This removes the start-failure → `StartLimit` → `reboot-force` path entirely.
   - Keep the existing fail-fast `process.exit(1)` paths that run *before* readiness for genuine
     config errors (device-id read ~line 131, version read ~line 137). Those *should* still
     escalate to `reboot-force` via `StartLimit` if they fail on every boot — a broken image is
     exactly what that last resort is for.

2. **Make the initial connect non-fatal + retried in the background.** Replace the
   `await connection.connect()` + `process.exit(1)`-on-failure block with a background retry loop
   that does not exit on failure:

   ```js
   async function attemptInitialConnect() {
     while (!isConnected) {
       try {
         log(`Connecting to ${ENDPOINT}...`);
         await connection.connect();          // resolves -> 'connect' handler sets isConnected
         for (const topic of SUBSCRIBE_TOPICS) {
           await connection.subscribe(topic, mqtt.QoS.AtLeastOnce);
         }
         log("Successfully subscribed to all topics");
         await updateShadowReportedState("public");
         await updateShadowReportedState("private");
         await publishHealthData();
         return;
       } catch (err) {
         log(`Initial connect failed: ${err.message}; retrying in 30s`, "WARN");
         await new Promise((r) => setTimeout(r, 30_000));
       }
     }
   }
   attemptInitialConnect(); // fire-and-forget; do NOT await before starting the intervals below
   ```
   - The `while (!isConnected)` guard stops the loop once the `connect` event fires, preventing a
     double-connect. Each attempt is awaited (serialized).
   - Once connected even once, the SDK's own `interrupt`/`resume` backoff handles later drops, so
     this loop exits and stays exited.

3. **Start the watchdog, health interval, and SIGINT/SIGTERM handling unconditionally** — outside
   the connect path — so the process always stays alive feeding the systemd watchdog
   (`SdNotify.watchdog()` every 60s) and remains cleanly stoppable, connected or not.

4. **Leave the Layer 1 watchdog logic as-is.** It only arms after a successful connect
   (`lastDisconnectedAt` is set only in the `interrupt`/`disconnect` handlers), so it still does
   its job for the post-connect case: a connection that drops and the SDK can't recover →
   `process.exit(1)` → systemd restart → the restarted process re-connects on a working network
   (fresh SDK). With early-READY, that restart no longer counts as a failed start, so it recovers
   via a lightweight restart instead of a reboot — and won't loop if the network is actually down.

**No systemd unit changes.** `Type=notify`, `Restart=always`, `RestartSec=10`, `WatchdogSec=180`,
and `[Unit] StartLimit*` / `reboot-force` all stay. `reboot-force` now fires only for genuine
repeated pre-readiness crashes, which is its correct purpose.

## Resulting behavior

| Situation | Before | After |
|---|---|---|
| Factory reset, no WiFi config | reboot-loops every ~2–4 min, reprints ticket each time | stays up, flashing-blue LED, BLE-provisionable, retries; boot ticket prints once |
| Configured but network/internet down | reboot-loops | stays up, NM + SDK keep retrying; reconnects when network returns |
| Connected, then SDK wedges on a working network | Layer 1 exit → restart → (eventually) reboot | Layer 1 exit → single restart → fresh connect succeeds; no reboot needed |
| Crashes before readiness on every boot (bad cert/image) | reboot-force | reboot-force (unchanged — correct) |

## Out of scope / explicitly unchanged
- `stage3/12-install-boot-print/` — left as-is. With the loop gone, the unconditional boot print
  fires once per genuine boot, which is the intended behavior. No rate-limit needed.
- Status LED, BLE config service, `device-reset` / `reset.escpos`, health-monitor — unchanged.
- WiFi-layer `autoconnect-retries=0` — already in place (commit `3d29c1b`).

## Risks / edge cases
- **Early READY masking a real post-readiness crash:** if the process crashes *after* READY on
  every boot, `Restart=always` + `StartLimit` still reboot — correct; only the *network* failure
  is decoupled from readiness. Keep config-error exits before the READY call.
- **Repeated `connect()` on one connection object:** verify the aws-crt connection supports
  re-calling `connect()` after a rejected attempt; if it doesn't, rebuild the connection object
  inside the retry loop. Serialize attempts and stop on `isConnected` to avoid double-connect.
- **SIGTERM/SIGINT during the retry loop:** register the signal handlers regardless of connect
  success; `process.exit(0)` in the handler overrides the pending 30s retry timer.
- **`publishHealthData()` while never connected:** it publishes over MQTT, so it will fail until
  connected; ensure it logs-and-returns (guard on `isConnected`) rather than throwing.
- **Narrow gap:** a device whose *local* network stack is wedged such that even a fresh process
  can't connect on an otherwise-good network would now retry instead of reboot. Accepted per the
  design decision (rely on NM's infinite retries; reboot only for the post-connect SDK wedge). If
  field evidence later shows wedged-radio cases that only a reboot fixes, revisit with a
  network-aware escalation (TCP probe to the IoT endpoint) or a WiFi-layer rescan watchdog.

## Verification
1. **Static:** `node --check` the edited `mqtt-client.js`; confirm `SdNotify.ready()` is called
   before `connection.connect()` and there is no `process.exit(1)` on the connect path.
2. **On-device test matrix:**
   - **Factory reset, no config:** boot and leave for ≥20 min → confirm **no reboot** (`uptime`,
     `last reboot`), `systemctl is-active mqtt-client` = active, READY logged, LED flashing-blue,
     BLE provisioning succeeds and brings it online without a reboot, and the boot ticket printed
     exactly once.
   - **Lost network:** provision, confirm online, then block the AP / endpoint (`iptables` or power
     the router off) → confirm at most one Layer-1 restart, then quiet retrying, **no reboot loop**;
     restore network → reconnects on its own.
   - **Wedged SDK on good network:** simulate per `HIGH_AVAILABILITY.md` → confirm a single restart
     recovers it.
   - **Genuine startup crash:** corrupt the device cert → confirm `reboot-force` still escalates.

## Rollout
- Image-baked change; ships in the next `iot-pi` release on both lines (per `RELEASES.md`):
  next patch on `hw/1.0` (from 1.0.9) and `hw/1.1` (from 1.1.3/1.1.4). Bug fix → PATCH bump,
  `Fixed` changelog entry; shared fix → develop on one `hw/*` branch, cherry-pick to the other.
- **Field note:** a device actively stuck in the loop is offline and cannot be SSH-patched; this
  fix reaches it only via reimage. There is no in-field patch for this change (it restructures
  `mqtt-client.js` startup), which is another reason it ships in the image rather than as a stopgap.
