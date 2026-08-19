# 2026-08-19 — device-ready flag destroyed by PrivateTmp (BUG-039)

The "device ready" receipt reprints on **every** `mqtt-client.service` restart instead of
once per power cycle. On a device whose connection is flapping, that means a thermal
printer printing and beeping through the night in a customer's closed office.

## The bug

`mqtt-client.service` sets **`PrivateTmp=true`**. systemd therefore gives the unit a
**fresh private `/tmp` mount namespace on every start** and discards the old one on stop.
The once-per-power-cycle guard was a flag file at `/tmp/eatabit-device-ready-printed`, so
it lived inside that namespace and was **destroyed by every service restart**.

A restart is the *only* thing that destroyed it. The in-code comment claimed the exact
opposite:

```js
// Persisted to /tmp so it survives service restarts but clears on reboot.
```

Both halves are false, and the comment reads as a deliberate design choice, which is why
it was believed. Correcting it is part of the fix.

The restart that triggers this in the field is the Layer 1 connection watchdog's
`process.exit(1)` after `MAX_DISCONNECT_DURATION_MS = 150_000`, with `Restart=always`.
No reboot is involved. Measured on the affected device: **5 service starts → 5 ready
prints, 1:1, with exactly one boot in 21 h 30 m.**

Reproduced on the bench on both hardware lines, 2026-08-19 — one `systemctl restart`,
ready-print count 1 → 2 within a single boot, private-tmp path keeping its boot-id
component while the random suffix changed.

## The fix — two files, both required

**`mqtt-client.service`** gains:

```
RuntimeDirectory=eatabit
RuntimeDirectoryPreserve=restart
```

systemd creates `/run/eatabit` (tmpfs), keeps it across a restart, and clears it on a
genuine reboot or power cycle.

**`mqtt-client.js`**:

- flag moves to `/run/eatabit/device-ready-printed`
- the false comment is corrected
- the flag write no longer swallows its error — a silent write failure under
  `ProtectSystem=strict` reproduces this bug *indistinguishably*, so it now logs

`PrivateTmp=true` is **not** removed. It is correct hardening; the flag was misplaced.

### Why not somewhere persistent

A path on disk survives a power cycle too, so the receipt would **never print again** —
the same bug in the silent direction, far harder to notice. `/usr/local/lib/eatabit/log`
is specifically unsafe despite being in `ReadWritePaths`: it is inside log2ram's
`LOG_DIRS`, so it is restored from disk at boot and the flag would be stale-true
(`BUG-041`).

Verified on hardware rather than assumed: `RuntimeDirectory=` grants the unit write
access to `/run/eatabit` under `ProtectSystem=strict` **without** extending
`ReadWritePaths`.

## Affected versions

**Every shipped version is affected.** `PrivateTmp=true` is present in
`stage3/03-install-mqtt-client/00-run.sh` at every tag checked — v1.0.1, v1.0.2, v1.0.4,
v1.0.6, v1.0.8, v1.0.10, v1.1.1, v1.1.2, v1.1.4. There is no unaffected range.

## Coverage — this patch does not cover the whole fleet

Gating is by **sha256 per file**, not by version string, and this patch is deliberately
**narrow**. It carries the v1.0.10 / v1.1.4 generation of `mqtt-client.js` with the
BUG-039 fix on top, and accepts only:

| File | Accepted pre-fix state |
| --- | --- |
| `mqtt-client.js` | stock v1.0.8–v1.0.10 / v1.1.2–v1.1.4, plus the three 2026-06-25/06-30 field-patch intermediates |
| `mqtt-client.service` | stock unit for v1.0.8–v1.0.10 / v1.1.2–v1.1.4 |

Devices on materially older builds — v1.0.2, v1.0.4, v1.0.6, v1.1.0, v1.1.1 — are
**refused, by design**. Dropping this `mqtt-client.js` on them would also apply many
unrelated intervening changes, which is a far larger change than this patch is scoped to
make, and their unit file is a different (older) variant as well. Those devices get the
fix through the **v1.0.11 / v1.1.5 image release** instead.

Against the connected fleet as measured on 2026-08-19 (31 devices), that means this patch
applies to roughly **7 devices** (1 × v1.0.10, 6 × v1.1.4) and the remaining ~24 are the
release's job. The customer device that prompted this bug is on v1.1.4 and **is** covered.

> Three fleet devices report Version `1.1.0`, for which **no `v1.1.0` tag exists** in
> `iot-pi`. Their state is unverified. They will be refused by checksum like any other
> unrecognized file — which is the correct outcome.

**An unrecognized file is never overwritten, and the refusal prints the observed
sha256**, the file path, and the list it was checked against. An unsampled field device
therefore reports its own state on first contact instead of merely being rejected.

## Applying

```sh
scp -r 2026-08-19-device-ready-flag-privatetmp eatabit@<device>:/tmp/
ssh eatabit@<device>
sudo /tmp/2026-08-19-device-ready-flag-privatetmp/apply.sh
```

**Restarting `mqtt-client.service` drops the ngrok SSH tunnel** — ngrok runs *inside* that
process. Over SSH the script runs the restart and verification **detached** and logs to
`/usr/local/lib/eatabit/patches/2026-08-19-device-ready-flag-privatetmp/apply.log`.
Reconnect (re-issue the `startNgrokTunnel` cloud command) and read that log.

**Applying prints exactly one ready receipt.** The patch restarts the service into a
freshly-created `/run/eatabit`, so the guard is absent for that one start. This is
expected and unavoidable — seeding the flag beforehand does not work, because systemd
recreates a `RuntimeDirectory=` on start and discards anything placed there by hand.
Every restart *after* that one is silent, which is the point of the fix.

> **Remote-session detection does not rely on `$SSH_CONNECTION`.** `sudo`'s `env_reset`
> strips `SSH_CONNECTION`, `SSH_CLIENT` and `SSH_TTY`, and the documented invocation is
> `sudo ./apply.sh` — so an environment-only check reports "local console" while running
> over SSH, executes the restart inline, and kills the very tunnel it is running over.
> This script also walks the parent process chain for `sshd`, which survives `sudo`.
> `--inline` and `--detach` force either behaviour explicitly.

Rollback:

```sh
sudo /tmp/2026-08-19-device-ready-flag-privatetmp/apply.sh --rollback
```

## Safety behaviour

- **Idempotent** — a second run no-ops once both files are at the fixed shas.
- **Independently gated per file** — a half-applied device (a previous run that died
  between the two installs) is completed rather than refused.
- `systemd-analyze verify` runs on the bundled unit **before** it is installed. A bad unit
  means a service that will not start, on a device that may need a site visit.
- `node --check` runs on the installed `mqtt-client.js`; failure restores the backup.
- After restart the script asserts the service is `active`, that `/run/eatabit` exists,
  and that the journal shows **no** failed flag write. Any of those restores the originals
  and restarts.
- Originals are backed up to
  `/usr/local/lib/eatabit/patches/2026-08-19-device-ready-flag-privatetmp/backup/`.

## Verifying the fix on a device

A restart must **not** reprint; a reboot **must**.

```sh
# 1. restart must NOT reprint
sudo systemctl restart mqtt-client.service       # detached if over SSH
systemctl show mqtt-client.service -p ExecMainStartTimestamp
ls -l --time-style=full-iso /run/eatabit/device-ready-printed
```

The proof is that the **flag's mtime is OLDER than `ExecMainStartTimestamp`**. Presence
alone does not distinguish "survived the restart" from "recreated by a fresh reprint" —
before the fix the file is present too, just with a newer mtime.

```sh
# 2. reboot MUST reprint  -- do not skip this half
sudo reboot
# after it returns:
sudo journalctl -u mqtt-client.service -b | grep -c 'Printed device ready receipt'   # expect 1
```

A fix that stops the restart reprint *and* the reboot reprint has replaced a noisy
failure with a silent one.

> `StartLimitBurst=5` with `StartLimitAction=reboot-force` means a fast restart loop ends
> in a forced reboot — which clears `/run` and **correctly** reprints. Check
> `journalctl --list-boots` before calling a post-fix reprint a regression (`BUG-044`).

## Image source

The same change is committed to image source on **both** hardware lines and ships in
**v1.0.11** (`hw/1.0`) and **v1.1.5** (`hw/1.1`) — `ISSUE-065`. The files bundled here are
byte-identical to what those releases ship, so a device flashed to them lands on the fixed
shas and this patch no-ops.

| File | Fixed sha256 |
| --- | --- |
| `mqtt-client.js` | `d4647dab55ee858206446c9cc0be5c284ac40554f04a75252cc90abafcbc3376` |
| `mqtt-client.service` | `84aa9272b43699c7d337f8b6e63f2b90d38306335d51bb3475e2e2f4201fc25f` |

## Related

- `BUG-041` — log2ram restores `/usr/local/lib/eatabit/log` at boot (why that path is unsafe)
- `BUG-042` — device clock skew; journal timestamps are BST while app log lines are UTC
- `BUG-044` — `StartLimitBurst` / `reboot-force` restart budget
- `ISSUE-064` — the connectivity flapping that triggers the restarts (**not** fixed here)
- `ISSUE-065` — the v1.0.11 / v1.1.5 release that carries this fix to the rest of the fleet
