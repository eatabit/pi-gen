# Watchdog exit hang — patch (2026-05-12)

> **v1.0.11 / v1.1.5 ALREADY CARRY THIS FIX.** This patch gates on deployed state
> rather than a replaced-file checksum, and both built images were confirmed to be in
> that state on 2026-08-25 (`ISSUE-065`), so it has nothing to do on a freshly flashed
> device. Apply only to devices on **earlier** firmware.

> | | |
> |---|---|
> | **Lineage** | `mqtt-client` — **writes** `mqtt-client.service`; gates on `mqtt-client.js` too, which is what ties it to this lineage |
> | **Position** | 1 of 3 |
> | **Prerequisite** | none |
> | **Superseded by** | [`2026-08-20-ngrok-session-reclaim`](../2026-08-20-ngrok-session-reclaim/), a self-contained rollup that accepts this patch's output as a prior |
> | **Independent of** | the `bluetooth` lineage — shares no file with it, so order between them does not matter |
>
> Lineages and why they exist: [`../README.md`](../README.md) → *Lineages*.

> **Revised 2026-08-22 — BUG-047.** **SSH detection added.** This patch previously restarted `mqtt-client.service` **inline on
> both the apply and rollback paths**, with no remote-session detection at all, so applying or
> rolling it back over an SSH/ngrok session was killed by the restart it had just caused. It now
> re-execs the restart+verify detached over SSH, and accepts `--inline` / `--detach`.
> 
> **Installed files and checksums are unchanged.** This edit touches only the
> foreground/background decision — every payload, `FIXED_*` / `ACCEPTED_PRIOR_*` checksum,
> version gate, marker and backup path is byte-identical to the version originally shipped,
> so an on-device copy predating this note installs exactly the same bytes.

> **Also revised 2026-08-22 — BUG-047.** The detached step is now re-exec'd via
> `bash "$SELF"` rather than executing `$SELF` directly, so a copy delivered without
> its executable bit fails loudly instead of logging "running DETACHED", exiting 0 and
> doing nothing. Installed files and checksums are unchanged by this too.

## Affected versions

Every image from **v1.0.2 onward**, both hardware lines:

- hw/1.0: `v1.0.2`, `v1.0.3`, `v1.0.4`, `v1.0.5`, `v1.0.6`, `v1.0.7`
- hw/1.1: `v1.1.0`, `v1.1.1`

The buggy code is byte-identical across all of them, so one patch script handles every version. Devices on v1.0.8+ or v1.1.2+ already have the fix baked into the image — do not apply this patch to those.

## The bug

In `mqtt-client.js`, the Layer 1 connection watchdog (`setInterval`) was supposed to call `process.exit(1)` after the MQTT connection had been down for more than 2.5 minutes, letting systemd restart the service with a fresh SDK instance:

```js
if (disconnectedMs > MAX_DISCONNECT_DURATION_MS) {
  log("Connection watchdog triggered: ... exiting to trigger systemd restart");
  watchdogTriggerCount++;

  try {
    await publishEvent("connectionWatchdogTriggered", { ... });   // ← HANGS FOREVER
  } catch (_) {}

  process.exit(1);   // ← NEVER REACHED
}
```

`publishEvent` calls `await mqttConnection.publish(...)`. When the AWS IoT SDK v2 is in a wedged state, that publish promise **never resolves and never rejects** — `try/catch` cannot intercept it. The watchdog ticks every 60 seconds, logs `Connection watchdog triggered: ...`, hits the `await`, and silently hangs there. The synchronous prefix of each new tick still runs (so logs keep accumulating and `SdNotify.watchdog()` keeps firing), which is why systemd's `WatchdogSec=180` backstop doesn't catch this either.

Observed in the field: a device on v1.0.6 produced ~1000 consecutive `Connection watchdog triggered` log lines over ~18 hours before being manually rebooted.

The unit file also has `StartLimitIntervalSec=` and `StartLimitBurst=` in the wrong section (`[Service]` instead of `[Unit]`), so the Layer 3 restart-escalation never armed. journalctl shows `Unknown key 'StartLimitIntervalSec' in section [Service], ignoring`.

## What the patch does

1. Replaces the watchdog block in `/usr/local/lib/eatabit/bin/mqtt-client.js` so the publish is fire-and-forget and `process.exit(1)` is unconditional. Adds `setTimeout(() => process.exit(1), 3000).unref()` as a belt-and-suspenders backstop.
2. Rewrites `/etc/systemd/system/mqtt-client.service` so `StartLimitIntervalSec` and `StartLimitBurst` are in `[Unit]` (where systemd actually reads them).
3. `systemctl daemon-reload`, restarts `mqtt-client.service`, and verifies it comes back active.

Originals are backed up to `/usr/local/lib/eatabit/patches/2026-05-12-watchdog-exit-hang/backup/` before any change. The script is idempotent — re-running it on an already-patched device is a no-op (it detects the fixed code and exits).

## How to apply

Both `apply.sh` and the embedded systemd unit file live in this directory. From your workstation:

```bash
# 1. Get the patch onto the device. Easiest is via the ngrok SSH tunnel:
scp -P <ngrok-port> -r 2026-05-12-watchdog-exit-hang eatabit@<ngrok-host>:/tmp/

# 2. SSH in and run it as root:
ssh -p <ngrok-port> eatabit@<ngrok-host>
sudo /tmp/2026-05-12-watchdog-exit-hang/apply.sh
```

The script prints what it's doing, what it skipped (if already applied), and the final `systemctl is-active mqtt-client.service` state. Expected exit code is 0 on success.

## How to roll back

```bash
sudo /tmp/2026-05-12-watchdog-exit-hang/apply.sh --rollback
```

Restores both files from the backup directory and restarts the service.

## Permanent fix

Shipped in the image as:

- **v1.0.8** on `hw/1.0`
- **v1.1.2** on `hw/1.1`

Once a device is reimaged or OTA'd to one of those versions, this patch is no longer needed (and the apply script will refuse to run).
