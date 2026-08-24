# `2026-08-23-log-permissions-and-rotation` — ISSUE-068, Phase 2

**Makes logrotate able to rotate the eatabit logs at all.** Restarts nothing.

## The bug

`/usr/local/lib/eatabit/log` ships mode **`0777`**. logrotate refuses to act on a file
whose parent directory is world-writable unless the config carries an `su` directive,
and `/etc/logrotate.d/eatabit-mqtt-client` carries none — so it aborts:

```
error: skipping "/usr/local/lib/eatabit/log/mqtt-client.log" because parent
directory has insecure permissions (It's world writable or writable by group
which is not "root") Set "su" directive in config file...
```

**`mqtt-client.log` has therefore never been rotated — not once, on any of the 15
release tags, on either hardware line.** Confirmed by `logrotate --debug` on three
devices spanning both lines, with **zero** rotated siblings present on any of them.

Compounding it, `ble-config.log` had **no rotation config at all** — `eatabit-mqtt-client`
was the only logrotate file the image ever wrote.

## Affected versions

**All of them:** `v1.0.1`–`v1.0.10` and `v1.1.0`–`v1.1.4`. The build script's logrotate
heredoc is byte-identical across every blob `stage3/03-install-mqtt-client/00-run.sh` has
ever had, and the `chmod 777` predates all of them.

Fixed in the image by ISSUE-068 Phase 2, so a device reflashed to a later release does not
need this patch — and if you run it there anyway it detects the fixed state and no-ops.

## What it changes

| Target | From | To |
|---|---|---|
| `/usr/local/lib/eatabit/log` | `0777` | `0755` |
| `/usr/local/lib/eatabit/config` | `0777` | `0755` |
| `/usr/local/lib/eatabit/reset` | `0777` | `0755` |
| `/etc/logrotate.d/eatabit-mqtt-client` | `create 0666` | `create 0644` |
| `/etc/logrotate.d/eatabit-ble-config` | *(absent)* | new stanza, `daily` + `maxsize 5M` |

**The payload files are byte-identical to what the image now writes**, so a patched
device and a freshly-imaged device converge on exactly the same state rather than
drifting into two similar-but-different ones.

### Why `0755` rather than adding `su root root`

The **mode is the cause**, so `0755` fixes the class and covers every future file in the
directory; `su` fixes one stanza and leaves the world-writable directory standing for the
next file to trip over.

Safe because **every writer runs as root** — all eight systemd units that touch
`/usr/local/lib/eatabit` (three declare `User=root`; five leave `User=` empty, which for a
system unit means root), with no cron writer, no user crontabs, and no non-root process
holding a descriptor there. Established on three devices across both lines.

### Why `create 0644`

At `0666` logrotate re-creates every **rotated** file world-writable, perpetuating the
exact condition that blocked rotation in the first place.

### Why `ble-config.log` gets `maxsize 5M` as well as `daily`

Its measured steady-state growth is **0 B/h** — it is event-driven and only grows on BLE
pairing activity. The risk is a **burst**, not a climb, so the size trigger bounds the
burst while the time trigger bounds everything else.

## Lineage — new and independent

**No other patch in this tree touches any of these targets.** No patch writes
`/etc/logrotate.d` at all, and none alters a directory mode. This patch shares no checksum
with the `mqtt-client`, `bluetooth`, `timezone` or `log2ram` lineages, so it may be applied
at **any** point in a campaign — before or after any of them, or entirely on its own.

## Restarts nothing

Safe to apply to a live, printing device with no maintenance window.

It writes no unit file and no drop-in, so it does not even need `systemctl daemon-reload`:
logrotate re-reads `/etc/logrotate.d` on every run, and directory modes are read at
`open()` time. `mqtt-client`'s `MainPID` is captured before and after as evidence that
nothing was disturbed.

## Usage

```bash
scp -r patches/2026-08-23-log-permissions-and-rotation eatabit@<device>:~/
ssh eatabit@<device>
./2026-08-23-log-permissions-and-rotation/apply.sh --check   # no root, changes nothing
sudo ./2026-08-23-log-permissions-and-rotation/apply.sh
```

`--check` exit codes: **0** already patched · **1** would refuse · **2** would apply.

Rotation then happens on the next daily `logrotate` run. To rotate immediately:

```bash
sudo logrotate -f /etc/logrotate.d/eatabit-mqtt-client
```

Rollback restores the prior directory modes and the original config, and removes
`eatabit-ble-config` if this patch created it:

```bash
sudo ./2026-08-23-log-permissions-and-rotation/apply.sh --rollback
```

## Gates

Checksums and modes are the authority; the version string is informational.

- Each of the three directories must be `777` (stock) or `755` (already fixed). Any other
  mode → **refuse**, printing the observed mode.
- `/etc/logrotate.d/eatabit-mqtt-client` must be the stock sha
  `73e6530d…` or the fixed sha `09c2f9fa…`. Anything else → **refuse**, printing the
  observed sha.
- `/etc/logrotate.d/eatabit-ble-config` must be absent or already the fixed sha
  `3a6028e4…`. Anything else → **refuse** rather than overwrite something another
  process is managing.

Post-apply it re-checks every observable **and** runs `logrotate --debug`, failing if the
`insecure permissions` error is still present. Unit state is deliberately **not** used as
evidence: a freshly rebooted device reports `logrotate.service` as `inactive` merely
because the daily timer has not fired, which reads as healthy whether or not the patch
worked.

## Known limitation — the application code can undo this

`mqtt-client.js` and `ble-config.js` create these directories at `0o777` and their log
files at `0o666` **when they find them missing**. So if a service ever starts while one of
these directories is absent, it will be re-created world-writable and rotation will break
again.

Re-running this patch fixes it. The permanent fix is the image (ISSUE-068 Phase 2 narrowed
all 14 application-code sites), or a follow-up patch carrying the application changes —
which must chain the **`mqtt-client` lineage** on top of
`2026-08-19-mqtt-keepalive-tolerance`, or it would silently revert that patch. That is
deliberately **not** this patch.
