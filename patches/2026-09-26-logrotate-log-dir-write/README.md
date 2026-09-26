# 2026-09-26 · `logrotate.service` cannot write the eatabit log directory — let it

| | |
|---|---|
| **Patch ID** | `2026-09-26-logrotate-log-dir-write` |
| **Tracker** | `BUG-097` (P2) |
| **Lineage** | **`logrotate-unit` — new, and independent of every other lineage here.** Targets `/etc/systemd/system/logrotate.service.d/eatabit.conf`, which no other patch touches, so it shares no checksum with any of them and **may be applied at any point in a campaign**. It makes the stanzas from [`2026-08-23-log-permissions-and-rotation`](../2026-08-23-log-permissions-and-rotation/) and [`2026-09-23-netwatch`](../2026-09-23-netwatch/) actually runnable, but requires neither. |
| **Affected versions** | **Every released version, v1.0.1–v1.0.11 and v1.1.0–v1.1.5 — including the current releases.** Gated on deployed state, not a checksum: this patch adds a file and replaces none. |
| **Restarts** | **Nothing.** `systemctl daemon-reload` only. Safe on a live, printing device; no maintenance window, no tunnel drop. |
| **Shipped in** | The next release after v1.0.11 / v1.1.5. Images built after this merges install the same drop-in from `stage3/05-install-log2ram/00-run.sh` and report *already patched*. |

## What is wrong

Debian's stock `/usr/lib/systemd/system/logrotate.service` ships `ProtectSystem=full`,
which mounts **`/usr` read-only inside that unit's own mount namespace**. The eatabit logs
live at `/usr/local/lib/eatabit/log` — under `/usr` — so every rename and create logrotate
attempts there fails:

```
error: error renaming /usr/local/lib/eatabit/log/mqtt-client.log.7.gz to …/mqtt-client.log.8.gz: Read-only file system
```

The disk is fine. A root shell writes there without complaint, which is why the one
"successful" rotation ever recorded — a manual `logrotate -f` from a shell — proved the
config and never the service. Every automatic run on every device checked has failed,
**at least 25 devices across both hardware lines** (`BUG-097` → *Scope*). The CHANGELOG's
v1.0.11 claim that application logs "are now rotated" was true of the configuration and
false in practice.

Three things make it worse than the disk it costs:

- **`logrotate` exits 1, which fails the whole run** — nothing on the device rotates, not
  only eatabit's logs.
- **It still advances its state file**, so the failure is silent: it does not retry until
  the next day.
- **The error names files that never existed.** `rename()` checks for a read-only mount
  before it resolves the source, so a missing `.7.gz` yields `EROFS`, not `ENOENT`, and
  the message reads like a different bug. A device with a pending uncompressed `.1` fails
  at the compress step instead (`error creating output file …log.1.gz`) — same cause.

It was missed because the repo's convention (`CLAUDE.md` → service template) gives every
**eatabit** unit `ReadWritePaths=/usr/local/lib/eatabit/log` — `mqtt-client.service`
writes there under the *stricter* `ProtectSystem=strict` — and then says "add a logrotate
config". Both halves were followed. `logrotate.service` is a stock Debian unit nobody
owned, so nothing gave *it* the grant.

## What this patch does

Installs one drop-in and reloads systemd:

```ini
# /etc/systemd/system/logrotate.service.d/eatabit.conf
[Service]
ReadWritePaths=-/usr/local/lib/eatabit/log
```

- It names the **directory**, so every stanza pointing into it is covered —
  `eatabit-mqtt-client`, `eatabit-ble-config`, `eatabit-netwatch` — without editing any
  of them.
- The leading **`-`** makes a missing directory a no-op instead of a unit failure.
- **`ProtectSystem=full` stays.** Only the log directory is opened; the rest of `/usr`
  remains read-only to logrotate. The apply asserts both.
- The bytes are **identical to the image copy** (`FIXED_SHA` `8ec46a1e…`), so a device
  reflashed to a later image no-ops.

No logrotate stanza changes. `create` rotation is correct as configured: every writer into
the directory opens, appends and closes on each line (all 17 release tags checked, and
confirmed on-device), so after a rotation the next line lands in the new file.

## Apply

```bash
scp -r patches/2026-09-26-logrotate-log-dir-write eatabit@<device>:/tmp/
ssh eatabit@<device>
cd /tmp/2026-09-26-logrotate-log-dir-write
./apply.sh --check        # no root; exit 0 = already patched, 1 = would refuse, 2 = would apply
sudo ./apply.sh           # installs the drop-in, daemon-reload, asserts the grant is loaded
sudo ./apply.sh --rollback
```

The apply **refuses** if `logrotate.service` is not loaded, or if an `eatabit.conf` with
different bytes already exists (it prints the observed sha — report it; do not delete it).
It records `mqtt-client`'s `MainPID` before and after as evidence that nothing restarted.

## Verifying it worked — read this before calling it either way

**The proof is the next scheduled `logrotate.service` run rotating a file.** Three things
look like proof and are not:

1. **A shell `logrotate -f`** runs outside the sandbox, where the bug does not exist. It
   succeeds on a broken device.
2. **A plain `logrotate -d`** reports "does not need rotating", because the failed runs
   advanced the state file.
3. **`logrotate.service` exiting 0** is also what a run with nothing due looks like.

`daily` rotates on a **calendar-day change**, so the check is simply the next nightly run
(`systemctl list-timers logrotate.timer`). Then read `systemctl show logrotate.service -p
Result -p ExecMainStatus`, the journal (no `Read-only file system`), and the directory.
Success has **two shapes**: a device with a pending uncompressed `.1` gains a `.1.gz`; a
device that never rotated gains a fresh `.1` and an empty live log. Both are success.

On devices holding a manually-rotated `.1` that is still wanted as evidence
(`f707fb48`, `133a0d77`, `bd396b5c` in `BUG-097`), the first real run will gzip it — pull
anything needed first.

Measured on bench `ce4c5d90` (hw/1.0, v1.0.11) with this exact drop-in, 2026-09-26
00:52:38 UTC: `Result=success`, `ExecMainStatus=0`, clean journal, `ble-config.log.1`
created, and `mqtt-client.log`'s pending `.1` gzipped to `.2.gz` by the service itself.

## Rollback

`--rollback` removes the drop-in (only if this patch created it) and reloads systemd.
Nothing restarts. logrotate fails with `EROFS` again from its next run.
