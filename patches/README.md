# Field Patches

Manual patches to apply to already-deployed devices over SSH, without re-flashing the image.

Each subdirectory is a self-contained patch with its own `README.md` (bug summary + affected versions) and `apply.sh` (idempotent batch script). To apply: `scp -r` the patch directory to the device, then run `sudo ./apply.sh` over SSH.

Most patches restart `mqtt-client.service`, which **closes the SSH session you are running them over** — ngrok runs inside that process. So over SSH the restart-and-verify step re-execs itself **detached** and logs to `/usr/local/lib/eatabit/patches/<PATCH_ID>/apply.log`; `sudo ./apply.sh` returns almost immediately and the work continues without you. Reconnect and read that log to find out how it went. `--check` is a no-root dry run that changes nothing, and `--inline` / `--detach` override the detection if you need to force either.

New patches start from [`_template/`](./_template/) — **not** by copying whichever existing patch looks closest. See *Adding a patch* below.

A patch lands here when:
- A bug is severe enough that fleet devices need it before the next image build / OTA window.
- The fix can be applied in-place by replacing files under `/usr/local/lib/eatabit/` and/or `/etc/systemd/system/` without re-imaging.

The same fix is **also** committed to the image source on the appropriate `hw/*` branch and shipped in a normal versioned release. The patch is a stopgap; the image is the source of truth.

## Lineages — what must follow what

**A patch's date does not tell you its order, and two patches sharing a date does not
mean one follows the other.** What creates an ordering is a **shared target file**: each
`apply.sh` gates on the sha256 of the files it replaces, so patches touching the same file
form a chain, and patches touching disjoint files are independent. Read this table before
planning a campaign; the directory listing on its own will mislead you.

| Lineage | Target files | Patches, in order |
|---|---|---|
| **`mqtt-client`** | `/usr/local/lib/eatabit/bin/mqtt-client.js`, `/etc/systemd/system/mqtt-client.service` | 1. [`2026-05-12-watchdog-exit-hang`](./2026-05-12-watchdog-exit-hang/)<br>2. [`2026-06-30-offline-reboot-and-expired-job`](./2026-06-30-offline-reboot-and-expired-job/)<br>3. [`2026-08-20-ngrok-session-reclaim`](./2026-08-20-ngrok-session-reclaim/) — **self-contained**<br>4. [`2026-08-19-mqtt-keepalive-tolerance`](./2026-08-19-mqtt-keepalive-tolerance/) — **requires 3**<br>5. [`2026-08-23-app-permissions-and-shadow-churn`](./2026-08-23-app-permissions-and-shadow-churn/) — **requires 4** |
| **`bluetooth`** | `/etc/bluetooth/main.conf`, `/etc/systemd/system/bluetooth-poweron.service` | 1. [`2026-08-20-ble-classic-scan-off`](./2026-08-20-ble-classic-scan-off/) — **independent** |
| **`timezone`** | `/etc/timezone`, `/etc/localtime` (symlink) | 1. [`2026-08-19-gateway-timezone-utc`](./2026-08-19-gateway-timezone-utc/) — **independent** |
| **`log2ram`** | `/etc/systemd/system/log2ram-daily.timer.d/hourly.conf`, `/etc/log2ram.conf` | 1. [`2026-08-19-log2ram-timer-hourly-sync`](./2026-08-19-log2ram-timer-hourly-sync/) — **independent** |
| **`log-permissions`** | `/usr/local/lib/eatabit/{log,config,reset}` (directory modes), `/etc/logrotate.d/eatabit-mqtt-client`, `/etc/logrotate.d/eatabit-ble-config` | 1. [`2026-08-23-log-permissions-and-rotation`](./2026-08-23-log-permissions-and-rotation/) — **independent** |
| **`ble-config`** | `/usr/local/lib/eatabit/bin/ble-config.js` | 1. [`2026-08-24-ble-config-permissions`](./2026-08-24-ble-config-permissions/) — **independent** |

**`2026-08-19-gateway-timezone-utc` targets files no other patch touches** — it replaces
no file at all, gating instead on the deployed timezone state — so it is independent of
everything else here and may be applied at any point in a campaign. It is also the only
patch that **restarts no service**.

**`2026-08-19-log2ram-timer-hourly-sync` opens a new lineage of its own.** It targets the
log2ram timer drop-in and `/etc/log2ram.conf`, which no other patch here touches, so it
shares no checksum with any of them and may be applied at any point in a campaign. Like the
timezone patch it **replaces no file** — it enables a unit and adds a drop-in — so it gates
on observed state rather than a replaced-file sha, and it **restarts nothing**.

**ISSUE-068 ships THREE patches, and they share no file with one another**, so they may be
applied in any order — but **all three are needed** to close it on a device:

| Patch | Fixes | Restarts | Reach |
|---|---|---|---|
| `2026-08-23-log-permissions-and-rotation` | directory modes + both logrotate stanzas | **nothing** | every released version |
| `2026-08-24-ble-config-permissions` | `ble-config.js`'s six mode literals | `ble-config.service` only | every released variant |
| `2026-08-23-app-permissions-and-shadow-churn` | `mqtt-client.js` modes + shadow snapshots to tmpfs | `mqtt-client.service` | **only devices that can enter the `mqtt-client` lineage** |

The first narrows the directories that exist *now*; the other two stop the applications
re-creating them `0o777`. Without the application patches, one service start against an
absent directory silently undoes the first.

**That last row is the one to plan around.** The `mqtt-client` lineage entry point accepts
only stock v1.0.8–v1.0.10 / v1.1.2–v1.1.4, so a device on v1.0.1–v1.0.7, v1.1.0 or v1.1.1
cannot enter the lineage and cannot take that patch. The other two have no such limit.
`ble-config.js` was split out of it for exactly this reason — welded together, that dead
end governed a fix that needs no lineage at all.

**`2026-08-23-log-permissions-and-rotation` opens a new lineage of its own.** It targets
three directory *modes* and the two `/etc/logrotate.d/eatabit-*` files. **No other patch
here writes `/etc/logrotate.d` at all, and none alters a directory mode**, so it shares no
checksum with any of them and may be applied at any point in a campaign. Like the timezone
and log2ram-timer patches it **restarts nothing** — it writes no unit file, so it does not
even need `daemon-reload`. Note its known limitation: `mqtt-client.js` / `ble-config.js`
re-create those directories `0o777` if they ever find them missing, so a service start
against an absent directory can undo it. Re-running the patch fixes that; the permanent
fix is the image.

**The two `2026-08-20` patches share no file and therefore no checksum.** They may be
applied in either order, or one without the other. The shared date is a coincidence of
authorship, not a sequence.

**Within `mqtt-client`, the current head is self-contained.** `2026-08-20-ngrok-session-reclaim`
accepts stock v1.0.8–v1.0.10 / v1.1.2–v1.1.4 *and* the output of every earlier patch in the
lineage, so it can be applied directly to any of them. The numbering above is provenance —
how the code got here — not a sequence you must replay.

**The one real prerequisite in this lineage is the newest patch.**
`2026-08-19-mqtt-keepalive-tolerance` accepts **only** the output of
`2026-08-20-ngrok-session-reclaim` (`1d49a43a…`), because its `mqtt-client.js` expects
`/run/eatabit`, which exists only under that patch's unit. Its directory name is dated
**earlier** than the patch it depends on — the date records when the bug was filed, not
the order. **Read the lineage column, never the dates.**

### A device flashed to v1.0.11 or later is AHEAD of most of this lineage

**v1.0.11 / v1.1.5 ship `mqtt-client.js` at `7ecbf0ea…`, which is the END STATE of
`2026-08-23-app-permissions-and-shadow-churn`** — the last entry in the `mqtt-client`
lineage. So a freshly flashed device does not enter that lineage at the bottom; it starts at
the top.

| Patch | On a v1.0.11 / v1.1.5 device |
|---|---|
| 1. `2026-05-12-watchdog-exit-hang` | superseded |
| 2. `2026-06-30-offline-reboot-and-expired-job` | **`NO-OP — device is AHEAD of this patch`** |
| 3. `2026-08-20-ngrok-session-reclaim` | **`NO-OP — device is AHEAD of this patch`** |
| 4. `2026-08-19-mqtt-keepalive-tolerance` | **`NO-OP — device is AHEAD of this patch`** |
| 5. `2026-08-23-app-permissions-and-shadow-churn` | no-op — already at its fixed sha |

**Entries 2–4 report that through a third gate state, `SUPERSEDED_SHAS`, checked BEFORE the
accepted-prior list and exiting 0.** Without it they would refuse — telling an operator the
file is *unrecognised* when in fact it is *newer*.

**Do NOT "fix" that by adding the release sha to `ACCEPTED_PRIOR_SHAS`.** That list means
*"install my payload over this"*, and each of those patches bundles a payload whose sha **is
its own older `FIXED_SHA`** — `2f8848db…`, `1d49a43a…`, `b009b68c…`. Accepting a downstream
sha as a prior makes the patch **overwrite newer code with older**, silently reverting
whatever landed after it. Retargeting `FIXED_SHA` instead is equally wrong: the bundled
payload is unchanged, so the post-install verification then fails.

**This is not hypothetical.** `iot-doc/ops/Pi-Rollout-Log.md` records device `db996da7`,
where `2026-06-30-offline-reboot-and-expired-job` was declined **by hand** — *"Applying it
would have been a downgrade."* An operator caught it. `SUPERSEDED_SHAS` is that judgement
moved into the gate, so it does not depend on someone making it again.

**When you add a patch to a lineage, add its end-state sha to the `SUPERSEDED_SHAS` of every
patch below it in that lineage.** Otherwise each older patch starts refusing devices that
took your new one, and the refusal reads as corruption rather than as "already ahead".

### How to tell for yourself, without trusting this table

The checksums are the authority, and every patch has a dry run that needs no root and
changes nothing:

```bash
./apply.sh --check     # 0 = already patched   1 = would refuse   2 = would apply
```

Run it for each patch on a sample device. **A device's version string does not determine
the outcome — its file checksums do**, and a device can carry a version whose files an
earlier field patch already altered. If two patches both report `would apply`, they are
independent by construction: each is gating on files the other does not touch.

### Adding a patch

**Start from [`_template/`](./_template/)**, not from an existing patch:

```bash
cp -r patches/_template patches/YYYY-MM-DD-short-slug
```

Copying the nearest-looking patch is how this directory acquired the same SSH-detection
defect four times over (`BUG-047`). The template is the one place that machinery is
maintained; a patch is the place your fix goes. `_template/` is a skeleton, not a patch —
it is not listed in the table above and must never be `scp`-ed to a device.

**Any `apply.sh` that restarts a service MUST use parent-chain SSH detection matching
`sshd*` — never `$SSH_CONNECTION` alone, and never a bare `sshd`.** `sudo` strips the
environment variables, and OpenSSH 9.8+ names the per-connection processes `sshd-session`,
so both shortcuts silently report "local console" over SSH and run the restart inline,
killing the very session it was issued over. The re-exec must also go through
`bash "$SELF"`, so a directory delivered without the executable bit fails loudly instead of
silently. `_template/apply.sh` gets all of this right; the filled-in reference is
[`2026-08-20-ngrok-session-reclaim/apply.sh`](./2026-08-20-ngrok-session-reclaim/apply.sh).
Fix a defect in the template first, then sweep the copies.

**Any `apply.sh` that replaces `/etc/systemd/system/mqtt-client.service` MUST accept
`84aa9272b43699c7d337f8b6e63f2b90d38306335d51bb3475e2e2f4201fc25f` as a prior.** That is the
unit **the fleet is actually running** — installed by `2026-08-20-ngrok-session-reclaim`,
which reached most devices. A patch gating only on the two *stock* unit shas
(`7999b8b6…`, `e92b2a15…`) would refuse the majority of the fleet while looking correct in
review, because both stock values are real and the omission is invisible unless you know what
is deployed. The same single-prior trap the `mqtt-client.js` lineage already documents, on
the unit instead.

**These scripts carry a CROSS-LINE BYTE-IDENTITY invariant. Change them only in PAIRED PRs,
merged together or not at all.** `hw/1.0` and `hw/1.1` must hold byte-identical copies of
every `apply.sh` here, and that identity is what proves the two hardware lines have not
drifted. A change landing on one line alone breaks the proof itself — and it is **comment
edits** that do this, because they look too trivial to pair: three one-line comment changes
broke it during the v1.0.11 / v1.1.5 cycle alone. Open both PRs before either is reviewed,
say in each that it must merge with its twin, and verify identity after both land:

```bash
for p in patches/*/apply.sh; do
  a=$(git show "origin/hw/1.1:$p" | shasum -a 256 | cut -c1-12)
  b=$(git show "origin/hw/1.0:$p" | shasum -a 256 | cut -c1-12)
  [ "$a" = "$b" ] || echo "DRIFT: $p"
done
```

State its lineage in its `README.md` header block — the table at the top of every patch
here — and add it to the table above. If it targets a file no existing lineage covers, it
starts a new lineage and is independent of all of them. **Do not encode ordering in the
directory name**: the directory name becomes `PATCH_ID`, which is the on-device state path
`/usr/local/lib/eatabit/patches/<PATCH_ID>/` holding that device's `backup/` and `applied`
marker. Renaming a patch that has ever been applied in the field orphans those, and
`--rollback` then cannot find the backup it needs.

## Patches

| Date | Patch | Affected versions | Severity |
| --- | --- | --- | --- |
| 2026-05-12 | [`2026-05-12-watchdog-exit-hang`](./2026-05-12-watchdog-exit-hang/) | v1.0.2–v1.0.7, v1.1.0–v1.1.1 | Critical — devices can be offline indefinitely |
| 2026-06-30 | [`2026-06-30-offline-reboot-and-expired-job`](./2026-06-30-offline-reboot-and-expired-job/) | stock/offline-reboot-patched mqtt-client.js (checksum-gated) | High — offline reboot loop + expired job blocks queue (combined rollup) |
| 2026-08-19 | [`2026-08-19-gateway-timezone-utc`](./2026-08-19-gateway-timezone-utc/) | v1.0.1–v1.0.10, v1.1.1–v1.1.4 — **all 14 released tags** (gated on the deployed timezone, not a checksum: this patch replaces no file) | Low (P3) — no device misbehaves, but every on-device timestamp is wrong for its site (11 h in Hawaii) and `Europe/London` shifts it again twice a year. It already misled the `ISSUE-064` investigation. **Restarts nothing** — safe on a live, printing device |
| 2026-08-19 | [`2026-08-19-log2ram-timer-hourly-sync`](./2026-08-19-log2ram-timer-hourly-sync/) | v1.0.1–v1.0.10, v1.1.0–v1.1.4 — **all 15 released tags** (gated on deployed state, not a replaced-file checksum: this patch adds a drop-in and enables a unit, replacing nothing; `/etc/log2ram.conf` is asserted against one accepted sha, byte-identical across all 15 tags) | Medium (P2) — `log2ram-daily.timer` is installed but never enabled, so `/var/log` (a 64M tmpfs) reaches the card **only on a clean shutdown**; `StartLimitAction=reboot-force` (`BUG-044`) skips that, so a device destroys its own logs with the very reboot they would explain. Also overrides the stock **23:55 fixed-wall-clock** schedule to hourly, cutting the worst-case loss window from ~23h55m to ~1h at a derived ceiling of ~1 MB/day extra writes (log2ram syncs `--inplace --no-whole-file`, so only changed blocks are written). **Restarts nothing** — safe on a live, printing device. **Phase A only**: the persistent breadcrumb file rides the `mqtt-client` rollup with `BUG-044`/`BUG-045` |
| 2026-08-20 | [`2026-08-20-ngrok-session-reclaim`](./2026-08-20-ngrok-session-reclaim/) | **supersedes the 2026-08-19 patch** — self-contained rollup, no prerequisite; accepts stock v1.0.8–v1.0.10 / v1.1.2–v1.1.4, the 2026-06 intermediates, and the 2026-08-19 output (checksum-gated, js **and** unit) | High — one connect/disconnect cycle wedges remote SSH until `mqtt-client` restarts; this is the delivery path every other patch ships over |
| 2026-08-20 | [`2026-08-20-ble-classic-scan-off`](./2026-08-20-ble-classic-scan-off/) | v1.0.1–v1.0.10, v1.1.0–v1.1.4 (checksum-gated; `00-run.sh` is byte-identical across all 15 tags, so one prior sha per file) | Medium — fleet-wide WiFi latency/jitter tax from permanent BR/EDR scanning on a shared antenna. **Validated on hardware** 2026-08-21 on v1.1.4 / v1.0.10 / v1.1.0 (both lines): jitter 1.84x better, A2 passed — a stranded device is still discoverable and connectable from Android and iOS. **Fleet rollout gated on `BUG-051`**, which is pre-existing and unrelated: a device that has lost WiFi cannot be re-provisioned through the app's network list, patched or not. |
| 2026-08-19 | [`2026-08-19-mqtt-keepalive-tolerance`](./2026-08-19-mqtt-keepalive-tolerance/) | devices at the `2026-08-20-ngrok-session-reclaim` end state (sha `1d49a43a…`), which is also repo source on both lines — checksum-gated, **js only**, exactly one accepted prior | Medium — one late `PINGRESP` tears down a healthy connection; every disconnect on `00000000d9b7e5d1` was `AWS_ERROR_MQTT_TIMEOUT` at `n × 30 s + ~3.2 s` while WiFi never dropped. Widens the ping window 3 s → 10 s; genuine-offline detection 33 s → 40 s. **Validated on hardware** 2026-08-23 on **both lines** — v1.1.4 / v1.1.0 (`hw/1.1`) and v1.0.10 (`hw/1.0`): applied, one restart each, reconnected to AWS IoT, zero errors; `--check` exit codes 0/1/2 confirmed. Also applied to one authorized field device on v1.1.1. At that date the >=24 h soak and the `--rollback` exercise had not yet been run; see `BUG-045` for their outcome. (`BUG-045`) |

> **Restarts nothing at all:** `2026-08-19-gateway-timezone-utc` goes further than the
> note below — it restarts no service whatsoever, so it cannot drop the ngrok tunnel, the
> SSH session applying it, or an in-flight print job. It is the only patch here with no
> detached mode, because it has nothing to detach from. It records `mqtt-client`'s
> `MainPID` before and after as evidence.

> **Does not touch `mqtt-client`:** `2026-08-20-ble-classic-scan-off` is the first patch
> here that changes neither `mqtt-client.js` nor `mqtt-client.service`. It therefore does
> not restart that service and does not drop the ngrok SSH tunnel, and it shares no
> checksum with the other patches — it can be applied, rolled back and reasoned about
> independently of them.

> **Removed:** `2026-08-19-device-ready-flag-privatetmp` (BUG-039) was folded into the
> 2026-08-20 rollup above and deleted — it installed the same unit byte-for-byte and a
> strictly older `mqtt-client.js`, so running it first only cost a second `mqtt-client`
> restart, and every restart drops in-flight print jobs. It remains in git history, and
> its output sha `d4647dab…` is still an accepted pre-state of the rollup.
