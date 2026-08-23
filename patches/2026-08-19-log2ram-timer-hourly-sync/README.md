# 2026-08-19 · `log2ram-daily.timer` never enabled — enable it and sync hourly

| | |
|---|---|
| **Patch ID** | `2026-08-19-log2ram-timer-hourly-sync` |
| **Tracker** | `BUG-041` (P2) — Phase A |
| **Lineage** | **`log2ram` — new, and independent of every other lineage here.** Targets `/etc/systemd/system/log2ram-daily.timer.d/hourly.conf` and `/etc/log2ram.conf`. No other patch in this tree touches either file, so this patch shares no checksum with `mqtt-client`, `bluetooth` or `timezone` and **may be applied at any point in a campaign** — before them, after them, or entirely on its own. |
| **Affected versions** | **All 15 released tags** — v1.0.1–v1.0.10, v1.1.0–v1.1.4 |
| **Restarts** | **Nothing.** Safe on a live, printing device; no maintenance window needed. |
| **Ships in** | v1.0.11 / v1.1.5 (`ISSUE-065`) — a reflashed device lands on `FIXED_SHA` and this patch no-ops |

## What is wrong

`stage3/05-install-log2ram/00-run.sh` installs `log2ram-daily.timer` and then enables
**`log2ram`** — the *service*. **Nothing ever enables the timer.**

`/var/log` is a **64 MB tmpfs**, so with no timer the RAM copy reaches the SD card **only
via `log2ram.service`'s stop action — that is, only on a clean shutdown.** And
`StartLimitAction=reboot-force` (`BUG-044`) reboots *without* a clean stop.

**So everything logged since boot is destroyed by exactly the event you most need to
explain.** That is why the 2026-08-18 reboot on device `00000000d9b7e5d1` left no evidence
behind: the investigation that found this bug was itself blocked by it.

Measured live on that device: `cloud-init.log` was **308,426 bytes** in `/var/log` against
**236,964 bytes** in `/var/hdd.log` — unsynced data, sitting in RAM, one power cut from
gone.

## What this patch does

1. **Enables the timer** — `systemctl enable --now log2ram-daily.timer`.
2. **Installs an hourly override** at `/etc/systemd/system/log2ram-daily.timer.d/hourly.conf`.

### Why the override is not optional

The stock upstream timer is:

```ini
OnCalendar=*-*-* 23:55:00
```

That is a **fixed daily wall-clock instant, not a rolling 24 h**. So enabling the timer
alone leaves a **sawtooth loss window pegged to one moment**: a device that force-reboots at
23:50 loses **~23 h 55 m**, not "up to a day" spread evenly. Hourly turns that into ~1 h.

### Why hourly does not shorten the card's life

log2ram exists for SD-card longevity, and that reason is **respected here, not undone**.
Its sync is:

```
rsync -aAXv --sparse --inplace --no-whole-file --delete-after
```

**`--inplace --no-whole-file` means only *changed blocks* are written** — rsync does not
rewrite whole files and does not do a write-temp-then-rename. For append-only logs the bytes
written per sync are the bytes appended since the last sync.

**So going from daily to hourly does not multiply the log volume reaching the card.** The
same appended bytes are written either way. What it multiplies is only the
**partial-tail-block amplification** — the final, incompletely-filled 4 KiB block of each
actively-appended file is rewritten once per sync instead of once per day.

Bounded: ~10 actively-appended files × 24 syncs/day × one extra 4 KiB block ≈ **1 MB/day
(~0.35 GB/yr) ceiling**. Negligible against a class-10 card — less than a single logrotate
gzip cycle.

> **That figure is a derived bound, not a measurement.** It follows from the rsync flags
> above; it has not been confirmed on hardware.

### The `OnCalendar=` reset line — do not delete it

```ini
[Timer]
OnCalendar=
OnCalendar=hourly
Persistent=true
```

**`OnCalendar=` is a LIST in systemd.** A drop-in that merely adds `OnCalendar=hourly` gives
a timer that fires hourly **and** at 23:55 — additive, not replacing. The empty assignment
is what clears the inherited entry.

**`systemd-analyze verify` cannot catch this**, because an additive list is perfectly legal
systemd. The only proof is:

```bash
systemctl show log2ram-daily.timer -p TimersCalendar   # must show exactly ONE entry
```

`apply.sh` asserts it and auto-restores if it fails.

## Rejected — do not re-propose

**Making journald persistent** (`Storage=persistent`, `SystemMaxUse=50M`). It would place a
50 MB journal inside a **64 MB RAM disk** on a device with **~415 MB total RAM**, and —
because `/var/log` **is** the tmpfs — it would **still not survive a forced reboot**. It buys
nothing and risks filling the log tmpfs. See `BUG-041` → *planning.md* → **D4**.

## Not in this patch

**The persistent breadcrumb file** (`BUG-041` Phase B) — boot id, restart count, watchdog
exits, last disconnect reason, written to real disk outside `LOG_DIRS`. It lands in
`mqtt-client.js`, which means an **`mqtt-client.service` restart**, which drops the ngrok SSH
tunnel and any in-flight print job. It therefore rides the **`mqtt-client` rollup alongside
`BUG-044` and `BUG-045`**, which already restart that service — rather than buying a second
restart. Same reasoning that folded `2026-08-19-device-ready-flag-privatetmp` into the
2026-08-20 rollup. See `BUG-041` → *planning.md* → **D3**.

> **The patch directory name was settled before first field use.** `BUG-041`'s record
> originally proposed `2026-08-19-log2ram-timer-and-breadcrumb`; the breadcrumb then moved to
> Phase B, so that name described work this patch does not do. It was renamed **before any
> device saw it** — `PATCH_ID` *is* the on-device state path
> `/usr/local/lib/eatabit/patches/<PATCH_ID>/` holding each device's `backup/` and `applied`
> marker, so renaming after a field application would orphan the backup and break
> `--rollback`.

## Applying

```bash
scp -r 2026-08-19-log2ram-timer-hourly-sync pi@<device>:~/
ssh pi@<device>
./2026-08-19-log2ram-timer-hourly-sync/apply.sh --check    # dry run, no root needed
sudo ./2026-08-19-log2ram-timer-hourly-sync/apply.sh
```

`--check` exit codes follow the repo convention: **`0`** already patched · **`1`** would
refuse · **`2`** would apply.

**This patch restarts nothing, so `sudo ./apply.sh` runs inline and returns its exit code to
the session that issued it** — unlike most patches here, there is no detached mode and
nothing to reconnect for. `systemctl daemon-reload` *is* run (a new drop-in is invisible
otherwise) and it restarts no service and does not signal `mqtt-client`. The apply log
records `mqtt-client`'s `MainPID` before and after as evidence.

`--inline` / `--detach` are accepted for interface parity with the other patches and affect
only how `--check` reports the session context.

### Gating

This patch **replaces no file**, so there is no replaced-file payload sha. The deployed
**state** is the gate:

| Signal | Fixed state | Otherwise |
|---|---|---|
| `systemctl is-enabled log2ram-daily.timer` | `enabled` | part of "would apply" |
| `…/log2ram-daily.timer.d/hourly.conf` | present, sha256 = `2ab148d1…` | absent → apply · present but unrecognised → **refuse, printing the observed sha** |
| `/etc/log2ram.conf` | sha256 = `244f4c5a…` | anything else → **refuse, printing the observed sha** |

`/etc/log2ram.conf` is **asserted, never modified** — `SIZE`, `LOG_DIRS` and `USE_RSYNC` all
stay exactly as they are. One accepted sha suffices: `00-run.sh` is byte-identical across all
15 release tags, verified 2026-08-23 by hashing the file at every tag (a single distinct sha
came back).

A device already in the fixed state **no-ops**; it is not refused.

### Rollback

```bash
sudo ./2026-08-19-log2ram-timer-hourly-sync/apply.sh --rollback
```

Removes the drop-in (or restores a pre-existing one), returns the timer to its recorded prior
enable state, `daemon-reload`s, and clears the marker. Backup and log live at
`/usr/local/lib/eatabit/patches/2026-08-19-log2ram-timer-hourly-sync/`.

## Verifying on a device

```bash
systemctl is-enabled log2ram-daily.timer                  # enabled
systemctl show log2ram-daily.timer -p TimersCalendar      # exactly ONE entry
systemctl list-timers --all log2ram-daily.timer           # next elapse within the hour
```

**The real test is a forced power cut, not a clean `reboot`.** A clean reboot passes even
with the bug present, because `log2ram.service`'s stop action runs. After a power cut,
`/var/hdd.log` should hold log lines written since the last boot.
