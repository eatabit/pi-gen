# Offline reboot loop + expired-job stuck IN_PROGRESS — combined patch (2026-06-30)

> | | |
> |---|---|
> | **Lineage** | `mqtt-client` — touches `mqtt-client.js` |
> | **Position** | 2 of 3 |
> | **Prerequisite** | none — checksum-gated, accepts stock or the 2026-06-25 patch's output |
> | **Superseded by** | [`2026-08-20-ngrok-session-reclaim`](../2026-08-20-ngrok-session-reclaim/), which accepts this patch's output (`607f3d28…`) as a prior |
> | **Independent of** | the `bluetooth` lineage — shares no file with it, so order between them does not matter |
>
> Lineages and why they exist: [`../README.md`](../README.md) → *Lineages*.

> **Revised 2026-08-22 — BUG-047.** **SSH detection corrected.** The detach guard tested `$SSH_CONNECTION` only, which `sudo`'s
> `env_reset` strips — so under the documented `sudo ./apply.sh` it concluded "local console"
> and ran the restart inline, the exact failure the detach exists to prevent. It now uses
> `is_remote_session()` (parent-chain walk) and accepts `--inline` / `--detach`.
> 
> **Installed files and checksums are unchanged.** This edit touches only the
> foreground/background decision — every payload, `FIXED_*` / `ACCEPTED_PRIOR_*` checksum,
> version gate, marker and backup path is byte-identical to the version originally shipped,
> so an on-device copy predating this note installs exactly the same bytes.

> **Also revised 2026-08-22 — BUG-047.** The detached step is now re-exec'd via
> `bash "$SELF"` rather than executing `$SELF` directly, so a copy delivered without
> its executable bit fails loudly instead of logging "running DETACHED", exiting 0 and
> doing nothing. Installed files and checksums are unchanged by this too.

Combined `mqtt-client.js` rollup of two fixes. **Supersedes the earlier
`2026-06-25-offline-reboot-loop` patch** (now removed) — this is the offline-reboot fix plus the
expired-job/stuck-`IN_PROGRESS` fix, and it accepts that patch's file (`51a012ae…`) as an
upgrade-from, so a device that got it is repaired in place.

The bundled `mqtt-client.js` is **byte-identical to what the next image release ships** (v1.0.10 on
`hw/1.0`, v1.1.4 on `hw/1.1`). So a device flashed to those versions already has this exact file and
the patch cleanly **no-ops** on it.

## Affected versions

Gating is by **checksum, not version string** — a field-patched device keeps its old `VERSION`, so
the deployed file is the only reliable signal. The patch replaces any of these recognized prior
`mqtt-client.js` files and refuses anything else:

| Prior file (sha256) | What it is |
|---|---|
| `e80b7a17…` | stock v1.0.8+ / v1.1.2+ (incl. watchdog-patched older units, e.g. v1.1.0) |
| `51a012ae…` | the superseded `2026-06-25-offline-reboot-loop` patch |
| `b30bc9c2…` | the broken first cut of that patch |
| `607f3d28…` | the previous combined rollup (before the connection-rebuild fix) |

→ all become `2f8848db…` (the current combined fix). Devices already at `2f8848db…` (this patch, or
the v1.0.10/v1.1.4 image) → no-op.

## The two fixes

1. **Offline reboot loop.** `mqtt-client` sends systemd `READY=1` **before** connecting and treats
   the initial connect as non-fatal (background 30s retry). A networkless device (factory reset / no
   WiFi, or lost network) stays `active` and waits instead of failing its start and tripping
   `StartLimitAction=reboot-force` every ~2–4 min. Layer 1 watchdog + reboot-force for genuine
   pre-readiness crashes are preserved. (`docs/bugfix/offline-reboot-loop.md`)
2. **Expired job stuck `IN_PROGRESS` blocking the queue.** An expired job is now terminated with a
   status legal for its current execution state — **`FAILED`** when already `IN_PROGRESS` (it arrived
   via `start-next/accepted`, which the device's own `start-next` call advanced from `QUEUED`),
   **`REJECTED`** when still `QUEUED` (via `notify-next`). A job that expires **mid-download** now
   `FAIL`s instead of being silently dropped. Either way the execution terminates, so a stuck job can
   no longer suppress `notify-next` for every later job.
   (`iot-doc/issues/expired-job-stuck-in-progress-blocks-queue/`)

## How to apply

```bash
# 1. Copy the patch onto the device (e.g. via the ngrok SSH tunnel):
scp -P <ngrok-port> -r 2026-06-30-offline-reboot-and-expired-job eatabit@<ngrok-host>:/tmp/

# 2. SSH in and run it as root:
ssh -p <ngrok-port> eatabit@<ngrok-host>
sudo /tmp/2026-06-30-offline-reboot-and-expired-job/apply.sh
```

It verifies the deployed file's checksum, backs up the original, installs the combined fix,
syntax-checks it (`node --check`), restarts `mqtt-client.service`, and confirms it returns to
`active` (auto-restoring the backup on failure). Idempotent — re-running is a no-op.

> **⚠️ Your SSH session will drop during apply — expected.** The ngrok tunnel runs *inside* the
> `mqtt-client` process, so restarting the service closes the session. Over SSH the script runs the
> restart + verify **detached** and logs to
> `/usr/local/lib/eatabit/patches/2026-06-30-offline-reboot-and-expired-job/apply.log`.
>
> If you run it under `sudo bash` / plain `sudo`, `SSH_CONNECTION` is stripped so it runs inline —
> fine on **LAN** (the session survives an `mqtt-client` restart), but over **ngrok** prefer keeping
> `SSH_CONNECTION` set (e.g. `sudo -E`) so the detach engages.

## Reconnect & verify

The restarted `mqtt-client` does **not** reopen the tunnel — re-issue the `startNgrokTunnel` cloud
command, SSH back in, then:

```bash
cat /usr/local/lib/eatabit/patches/2026-06-30-offline-reboot-and-expired-job/apply.log   # SUCCESS/FAILED
cat /usr/local/lib/eatabit/patches/2026-06-30-offline-reboot-and-expired-job/applied     # result=success
sha256sum /usr/local/lib/eatabit/bin/mqtt-client.js   # expect 2f8848db…
systemctl is-active mqtt-client.service                # expect active
```

Functional checks: confirm a **command** (startNgrokTunnel) and a **fresh print job** both work, and
(offline fix) that pulling the network leaves the device `active` with **no reboot loop**.

## How to roll back

```bash
sudo /tmp/2026-06-30-offline-reboot-and-expired-job/apply.sh --rollback
```
Restores the pre-patch `mqtt-client.js` from backup and restarts the service (also detached over SSH).

## Permanent fix

Baked into the image as **v1.0.10** (`hw/1.0`) and **v1.1.4** (`hw/1.1`) — the same `2f8848db…`
file. After a device is reimaged/OTA'd to those, this patch is no longer needed (and `apply.sh`
no-ops, since the deployed file already equals `FIXED_SHA`).
