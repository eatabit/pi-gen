# 2026-08-19 — gateway timezone to UTC (BUG-042)

> **v1.0.11 / v1.1.5 ALREADY CARRY THIS FIX.** This patch gates on deployed state
> rather than a replaced-file checksum, and both built images were confirmed to be in
> that state on 2026-08-25 (`ISSUE-065`), so it has nothing to do on a freshly flashed
> device. Apply only to devices on **earlier** firmware.

> | | |
> |---|---|
> | **Lineage** | `timezone` — touches `/etc/timezone` and the `/etc/localtime` symlink. **New, independent lineage**: no existing patch targets either file |
> | **Position** | 1 of 1 |
> | **Prerequisite** | **none** |
> | **Independent of** | **every other patch here.** Shares no target file, and therefore no checksum, with the `mqtt-client` or `bluetooth` lineages. Apply in any order relative to them, or on its own |
> | **Restarts** | **nothing.** No service is restarted, reloaded or signalled |
>
> Lineages and why they exist: [`../README.md`](../README.md) → *Lineages*.

**Severity: Low (P3) — but it corrupts every investigation.** No device misbehaves
because of this. What it does is make every device *lie about when things happened*,
which is worse than it sounds: it already misled the `ISSUE-064` investigation, where
1:25 AM in the customer's office read as lunchtime in the journal.

## What is wrong

Every image inherits pi-gen's build default `TIMEZONE_DEFAULT="Europe/London"`
untouched, so **every gateway reports a UK clock regardless of where it is installed**.
On device `00000000d9b7e5d1`, physically in Hawaii, that is a permanent **11-hour**
offset on every journal line and every file mtime.

Two things make it worse than a constant offset:

- **The app's own log lines are written in UTC while file mtimes are in local (BST)**, so
  a single device already reads two ways before the customer's third reading is
  considered.
- **`Europe/London` observes DST.** The offset silently changes twice a year, so a device
  patched under BST and read under GMT appears to shift by an hour on its own.

Origin, verified — it is **not** cloud-init:

- `build.sh:220` — `export TIMEZONE_DEFAULT="${TIMEZONE_DEFAULT:-Europe/London}"`
- `stage2/03-set-timezone/02-run.sh:3-7` — writes it to `/etc/timezone`, removes
  `/etc/localtime`, then `dpkg-reconfigure -f noninteractive tzdata`
- `config` overrode it on neither line, so the upstream default survived into every image

## The fix

**`Etc/UTC` fleet-wide.** Device time becomes directly comparable to cloud `Event` rows,
and the DST discontinuity disappears. Site-local time becomes a presentation concern for
whoever reads the logs, not a property of the device.

*Considered and rejected:* setting the site's real zone at provisioning. It reads better
for one customer and worse for everyone comparing devices, and it needs a provisioning
input the platform does not collect.

The image-source half is the one-line `TIMEZONE_DEFAULT="Etc/UTC"` in `config`, shipping
in **v1.0.11 / v1.1.5** (`ISSUE-065`). This patch is what reaches devices already in the
field. A device reflashed to those versions is already correct, and this patch **no-ops**
on it.

## Affected versions

**All 14 released tags.** `build.sh` carries the `Europe/London` default in every one and
`stage2/03-set-timezone` applies it in every one; branch tips `origin/hw/1.0` and
`origin/hw/1.1` matched `v1.0.10` / `v1.1.4` with no drift.

| Version | `TIMEZONE_DEFAULT` default | Applied by `stage2/03-set-timezone` | Affected |
|---|---|---|---|
| v1.0.1 – v1.0.10 | `Europe/London` | yes | **yes** |
| v1.1.1 – v1.1.4 | `Europe/London` | yes | **yes** |

There is **no `v1.1.0` tag**, despite the citation in
[`../2026-05-12-watchdog-exit-hang/README.md`](../2026-05-12-watchdog-exit-hang/README.md);
housekeeping item in `ISSUE-065`.

## The gate — deployed state, not a checksum

This patch replaces no file, so there is no payload sha to compare. The gate is the
**deployed state**: the contents of `/etc/timezone` and the target of the
`/etc/localtime` symlink, cross-checked against `timedatectl`. The principle is the same
as the sha gates elsewhere — refuse an unrecognised state, and **print what was
observed** — only the observable differs.

**A version string proves nothing here**, exactly as elsewhere: a field-patched device
keeps its old `VERSION`.

| Observed state | Result |
|---|---|
| all three read `Etc/UTC` | **no-op**, exit 0 — never refused |
| all three read an accepted prior zone | **apply** |
| some read `Etc/UTC`, others do not | **converge** — see below |
| anything else | **refuse**, printing the observed zone |

**Half-applied devices are converged, not refused.** If an earlier run died between
`timedatectl set-timezone` and the explicit `/etc/timezone` write, or someone set the zone
by hand and left the two disagreeing, the device is in the split-reading state this record
exists to eliminate. Refusing would strand it there, and re-running toward the target can
only move it closer.

### Accepted prior states — **PROVISIONAL**

`ACCEPTED_PRIOR_ZONES` currently holds **`Europe/London`** only.

That is measured for the **image** — it is the pi-gen default proven present in all 14
tags — but **not yet measured for the fleet**. A device may have been set by hand in the
field. The read-only survey (`--check` across reachable devices, `BUG-042` task 3) is what
fixes this list.

**`BUG-049`'s survey is the precedent for why this matters:** it found 23 of 25 devices in
scope and corrected an inherited estimate of *"roughly 7"*. Measure, then decide.

Any zone found in the field that is not listed is **a decision, not a detail** — add it
here with its reason, or refuse it deliberately. **Do not widen the list silently to make
one device pass.**

## Applying

```bash
scp -r 2026-08-19-gateway-timezone-utc pi@<device>:~/
ssh pi@<device>
cd 2026-08-19-gateway-timezone-utc
./apply.sh --check      # dry run, no root, changes nothing
sudo ./apply.sh
```

`--check` exit codes follow the repo convention: **0** = already `Etc/UTC`, **1** = would
refuse, **2** = would apply.

### This patch does not interrupt anything — and proves it

**Applying it interrupts neither the connected MQTT session nor the SSH session you run it
over.** `timedatectl set-timezone` changes only how instants are **rendered locally** — it
moves neither the absolute (UTC) instant nor the monotonic clock, so MQTT
keepalive/`PINGREQ` timers and the TLS session are untouched.

So, unlike most patches here, there is **no detached mode**: `sudo ./apply.sh` runs to
completion in the foreground and returns its exit code to the session that started it.
`--inline` / `--detach` are accepted for consistency with the other patches and change
nothing.

`apply.sh` **records its own evidence**: it captures `mqtt-client`'s `MainPID` before and
after and writes both into the marker file. Identical PIDs prove no restart occurred. If
they ever differ, the patch **warns loudly** — it issues no restart, so something else
did, and that device does not satisfy the acceptance criterion.

> **Why this is stated so firmly:** ngrok runs *inside* the `mqtt-client` process, so any
> patch that restarts that service kills the tunnel and the SSH session issuing it. That
> is `BUG-047`, now fixed and merged. This patch sidesteps it entirely by restarting
> nothing — the template's default `systemctl daemon-reload` / `systemctl restart` was
> **removed**, not merely left unreached.

## Rollback

```bash
sudo ./apply.sh --rollback
```

Restores the timezone recorded in `/usr/local/lib/eatabit/patches/2026-08-19-gateway-timezone-utc/backup/`
and removes the `applied` marker. It refuses rather than guessing if the backup is missing
or empty. No service is restarted on this path either.

## After applying

- **Record the switchover instant** — `apply.sh` prints it and writes it to the marker.
  Every future timestamp on the device moves at that moment, so anything correlating old
  and new logs must account for the discontinuity.
- **Historical logs are not retroactively corrected.** Anything already recorded stays in
  BST, and conversions already written into `ISSUE-064` and elsewhere **stay as written**.
- The closing check is **agreement**: for one instant, the journal line, the `mqtt-client`
  app log line and the cloud `Event` row must all read the same. `timedatectl` alone does
  not prove it.

## On-device state

```
/usr/local/lib/eatabit/patches/2026-08-19-gateway-timezone-utc/
├── applied                       # marker: timestamps, prior zone, both MainPIDs
├── apply.log                     # every apply/rollback run, appended
└── backup/
    ├── etc-timezone              # prior /etc/timezone contents
    └── etc-localtime.target      # prior /etc/localtime target
```
