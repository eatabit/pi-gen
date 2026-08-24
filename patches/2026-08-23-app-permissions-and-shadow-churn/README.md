# `2026-08-23-app-permissions-and-shadow-churn` — ISSUE-068, Phase 2 (application half)

Companion to [`2026-08-23-log-permissions-and-rotation`](../2026-08-23-log-permissions-and-rotation/),
which fixes the same problem from the filesystem side. **Applying both is what closes
ISSUE-068 on a deployed device.** They share no file, so either may go first.

> **This patch restarts services.** It replaces running code. Restarting
> `mqtt-client.service` **drops in-flight print jobs** (BUG-049) and closes an ngrok SSH
> session. Its companion restarts nothing — if you only want rotation working and cannot
> take a restart right now, apply that one alone.

## What it fixes

### 1 · The applications re-create the directories world-writable

`mqtt-client.js` and `ble-config.js` create `/usr/local/lib/eatabit/{log,config,reset}`
at `0o777` and their log files at `0o666` **whenever they find them missing**. logrotate
refuses to rotate a file whose parent directory is world-writable without an `su`
directive — which is why `mqtt-client.log` had never once been rotated.

The companion patch narrows the directories that exist **now**; this one stops the
applications **re-creating** them wide open. **Neither is sufficient alone** — without
this patch, one service start against an absent directory silently undoes the companion
and rotation breaks again.

**8 sites** in `mqtt-client.js`. The six in `ble-config.js` are handled by its own patch.

### 2 · Shadow snapshot churn — fixed by moving the files to tmpfs

`persistShadowToFile()` rewrote the whole file on every call into
`/usr/local/lib/eatabit/config`, which is **not** RAM-buffered (log2ram only ever managed
`/var/log`). The health shadow fires every 15 minutes: **96 whole-file rewrites a day,
~159 KiB/day** straight to the SD card — roughly **7× the write volume of the entire log
directory**.

**The fix is the location.** The snapshots now live in **`/run/eatabit`** — tmpfs. systemd
already creates that directory for this unit (`RuntimeDirectory=eatabit`,
`RuntimeDirectoryPreserve=restart`), so it survives a service restart and is discarded on
stop. That is the right lifetime, because these files are **write-only**: nothing in the
image or on a device reads them back, the authoritative shadow lives in AWS IoT Core, and
service packs already list `config/shadow-*.json` as never-managed. Losing them on reboot
costs nothing — each is rewritten within one heartbeat. **Card writes for this state: zero.**

The patch also **retires the stale on-card copies** after the restart (backing them up
first, so `--rollback` restores them). Left in place they would be frozen at the moment of
patching while still looking like live state — a trap for whoever next reads one to debug.

> **A skip-if-unchanged guard is also present, and it is NOT the fix.** Measured on bench
> device `.126` (2026-08-24): it does **not** reduce the health shadow's write rate,
> because that shadow's `state` legitimately changes every cycle — it embeds its own
> timestamp, `uptime.seconds`, `freeMemory` and disk usage. The guard was written
> expecting it to help; it does not. It is kept because it is correct and does skip
> genuinely redundant writes (the private shadow at start-up, for one). **Do not cite it
> as the card-wear fix — the tmpfs move is.**
>
> The comparison covers `state` only, because the wrapper's own `timestamp` changes on
> every serialisation and a whole-content check would never skip. So `timestamp` means
> **last change**, not last check — safe, since the 15-minute MQTT publish to AWS IoT Core
> is untouched and the heartbeat stays visible in `mqtt-client.log`.

## Payloads — the image source, byte for byte

| Payload | Equals |
|---|---|
| `mqtt-client.js` | `stage3/03-install-mqtt-client/files/mqtt-client.js` |
| `ble-config.js` | `stage3/08-ble-config/files/ble-config.js` |

as of ISSUE-068 Phase 2, so a patched device and a device reflashed to the next release
converge on **exactly the same bytes**.

### A note on the prior state, because an earlier draft of this work got it backwards

The deployed `mqtt-client.js` (`b009b68c…`) is **identical to the pre-ISSUE-068 image
source**. The `2026-08-20-ngrok-session-reclaim` and `2026-08-19-mqtt-keepalive-tolerance`
fixes were already merged into the image, exactly as [`../README.md`](../README.md)
requires — *"the same fix is **also** committed to the image source … the image is the
source of truth"*. Installing this payload therefore **reverts nothing**: it is that same
file plus the ISSUE-068 changes. Verified by comparing the deployed sha against
`git show <ref>:stage3/03-install-mqtt-client/files/mqtt-client.js`.

### `ble-config.js` is NOT in this patch

It has its own — [`2026-08-24-ble-config-permissions`](../2026-08-24-ble-config-permissions/) —
and the split is deliberate.

This patch requires the `mqtt-client` lineage head, and that lineage's entry point
(`2026-08-20-ngrok-session-reclaim`) accepts only stock v1.0.8-v1.0.10 / v1.1.2-v1.1.4. So
a device on **v1.0.1-v1.0.7, v1.1.0 or v1.1.1 cannot enter the lineage at all** and can
never take this patch. While the two fixes were welded together, that dead end governed
the `ble-config.js` fix as well - even though that change needs no lineage and applies to
every released variant. Split, each reaches as far as it actually can.

**Apply both** (plus `2026-08-23-log-permissions-and-rotation`) to close ISSUE-068 on a
device. All three share no files and may go in any order.

## Prerequisite — `2026-08-19-mqtt-keepalive-tolerance`

**This patch requires that patch to have been applied.** Its output sha is this patch's
only accepted prior.

> **Most field devices are NOT at the lineage head**, so this patch will refuse on them
> until the lineage is brought up. Apply in this order:
>
> 1. [`2026-08-20-ngrok-session-reclaim`](../2026-08-20-ngrok-session-reclaim/) —
>    self-contained; accepts stock v1.0.8–v1.0.10 / v1.1.2–v1.1.4 and the output of every
>    earlier patch in the lineage
> 2. [`2026-08-19-mqtt-keepalive-tolerance`](../2026-08-19-mqtt-keepalive-tolerance/) —
>    requires 1
> 3. this patch
>
> A refusal prints exactly that sequence, plus the observed sha, rather than a bare
> mismatch.

The prerequisite's **marker file is reported but is never the gate.** A device reflashed
to an image that already contains the keepalive code has the correct sha and no marker,
and must still be accepted — gating on the marker would refuse precisely the devices that
need no prerequisite at all.

## Gates

Checksums are the authority; the version string is informational.

- `mqtt-client.js` must be `b009b68c…` (lineage head, == pre-ISSUE-068 image source) or
  the fixed `7ecbf0ea…`.
- `ble-config.js` must match one of the **five** released variants in the table above —
  either its prior sha (upgrade) or that same variant's fixed sha (already done).
  A device is "already fixed" only against **its own** variant's end state, never
  another release's.
- Anything else → **refuse**, printing the observed sha.

**Byte-level verification runs before any restart.** The restart is the expensive,
disruptive step, so both files are checked against their expected shas first — a mismatch
fails with nothing restarted rather than being discovered afterwards.

## Verifying the churn fix afterwards

```bash
ls /run/eatabit/shadow-*.json                    # expect 3
ls /usr/local/lib/eatabit/config/shadow-*.json   # expect none
findmnt -no FSTYPE /run                          # expect tmpfs
```

**Do not expect the mtime to stop advancing.** The files still rewrite every 15 minutes —
the health shadow's state genuinely changes each cycle — but they now do so on tmpfs, so
they cost **zero SD-card writes**. The location is the fix, not the write frequency.
