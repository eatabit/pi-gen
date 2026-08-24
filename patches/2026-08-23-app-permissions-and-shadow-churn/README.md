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

**14 sites:** 8 in `mqtt-client.js`, 6 in `ble-config.js` (`0o777`→`0o755`,
`0o666`→`0o644`).

### 2 · `shadow-health.json` rewrite churn

`persistShadowToFile()` rewrote the whole file on every call, and the health shadow fires
every 15 minutes — **96 whole-file rewrites a day, ~159 KiB/day** straight to the SD card
(that directory is **not** RAM-buffered; log2ram only ever managed `/var/log`), roughly
**7× the write volume of the entire log directory**.

The state is almost always identical between cycles. It was the embedded `timestamp` that
made every serialisation differ — so a naive content-equality check **would never have
skipped anything**. The fix compares the **`state` object only**, via a canonical
sorted-key encoding so key ordering cannot produce a false match, and consults the on-disk
file once after start-up so a restart does not force a redundant write either.

> **Semantic change, not just an optimisation:** `timestamp` now means **last change**,
> not last check. Safe for liveness — the file is **write-only** (nothing in the image or
> on a device reads it back) and the 15-minute MQTT publish to AWS IoT Core is untouched,
> so cloud-side freshness is unaffected. The per-cycle heartbeat also stays visible in
> `mqtt-client.log`.

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

### `ble-config.js` has two accepted priors, and they are not interchangeable

`v1.0.10` and `v1.1.4` ship `2cda3a88…`. **`v1.1.0` ships a different file**,
`d70edf02…`, differing in 53 lines unrelated to this fix. Upgrading a v1.1.0 device to
the v1.1.4 payload would smuggle in those unrelated changes, so this patch ships a second
payload — **`ble-config-v1.1.0.js`**, that device's own file with only the six mode sites
narrowed — and selects by observed sha.

The v1.1.4 payload converges on the current image; the v1.1.0 payload converges on
"v1.1.0 plus this fix", which is correct for that device and deliberately **not** the
same bytes.

## Ordering

- **Lineage `mqtt-client`** — shares `/usr/local/lib/eatabit/bin/mqtt-client.js` with
  `2026-08-19-mqtt-keepalive-tolerance`, whose output is this patch's accepted prior.
- **Lineage `ble-config`** — new; no other patch ships `ble-config.js`.
- **Independent of its companion** `2026-08-23-log-permissions-and-rotation`: that one
  touches directory modes and `/etc/logrotate.d`, this one touches
  `/usr/local/lib/eatabit/bin`. No shared file, no shared checksum, either order.

## Usage

```bash
scp -r patches/2026-08-23-app-permissions-and-shadow-churn eatabit@<device>:~/
ssh eatabit@<device>
./2026-08-23-app-permissions-and-shadow-churn/apply.sh --check   # no root, changes nothing
sudo ./2026-08-23-app-permissions-and-shadow-churn/apply.sh
```

`--check` exit codes: **0** already patched · **1** would refuse · **2** would apply.

Over SSH the restart+verify runs **detached**, so `sudo ./apply.sh` returns almost
immediately and the work continues without you. Reconnect and read
`/usr/local/lib/eatabit/patches/2026-08-23-app-permissions-and-shadow-churn/apply.log`.

```bash
sudo ./2026-08-23-app-permissions-and-shadow-churn/apply.sh --rollback
```

## Gates

Checksums are the authority; the version string is informational.

- `mqtt-client.js` must be `b009b68c…` (lineage head, == pre-ISSUE-068 image source) or
  the fixed `4cafe4db…`.
- `ble-config.js` must be `2cda3a88…` (v1.0.10/v1.1.4) or `d70edf02…` (v1.1.0), or
  already fixed.
- Anything else → **refuse**, printing the observed sha.

**Byte-level verification runs before any restart.** The restart is the expensive,
disruptive step, so both files are checked against their expected shas first — a mismatch
fails with nothing restarted rather than being discovered afterwards.

## Verifying the churn fix afterwards

```bash
stat -c '%y' /usr/local/lib/eatabit/config/shadow-health.json
```

Its mtime should **stop advancing every 15 minutes** while device state is steady — and
must **still update when state actually changes**. Both halves matter: a change that
stopped writing altogether would be a regression, not a fix.
