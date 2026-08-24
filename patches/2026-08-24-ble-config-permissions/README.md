# `2026-08-24-ble-config-permissions` — ISSUE-068

Narrows the six permissive-mode literals in `ble-config.js`. **Applies to every released
variant.** Restarts only `ble-config.service`, so it drops no print jobs and closes no
SSH session.

## What it fixes

`ble-config.js` creates `/usr/local/lib/eatabit/{config,log}` at mode `0o777` and its
config and log files at `0o666`, **whenever it finds them missing**. logrotate refuses to
rotate a file whose parent directory is world-writable unless the config carries an `su`
directive — so those directories are part of why `mqtt-client.log` had never once been
rotated.

[`2026-08-23-log-permissions-and-rotation`](../2026-08-23-log-permissions-and-rotation/)
narrows the directories that exist **now**; this one stops `ble-config` **re-creating**
them wide open. Neither is sufficient alone.

**Six edits, and nothing else:**

```
3x  mode: 0o777  ->  mode: 0o755
3x  mode: 0o666  ->  mode: 0o644
```

## Why it transforms in place instead of shipping a file

`ble-config.js` has **five distinct variants** across the 15 releases, and the split is by
**release history, not hardware line**:

| Variant | Releases |
|---|---|
| `eac92d78…` | v1.0.1, v1.0.2 |
| `4654037f…` | v1.0.3 |
| `d70edf02…` | v1.0.4–v1.0.6, **v1.1.0** |
| `ecbf9a06…` | v1.0.7, v1.0.8, **v1.1.1, v1.1.2** |
| `2cda3a88…` | v1.0.9, **v1.0.10, v1.1.3, v1.1.4** |

Shipping **one** file for everyone would install some other release's application logic —
dozens of unrelated lines of BLE pairing and WiFi-config code — to deliver six one-word
edits. Shipping **five** files fixes that, but leaves the patch unable to touch any
variant nobody enumerated, including every future release.

**Transforming in place gives the same result as either.** The substitution is
deterministic, so for a known variant `sed(prior)` is byte-identical to what a whole-file
payload would have installed — verified on-device against GNU `sed`: `d70edf02…`
transforms to exactly `a912dda0…`, the sha the shipped payload had.

So the variant table survives as **assertions**, not payloads:

- **Known prior** → transform, then require the result to equal that row's expected sha.
  Identical guarantee to a payload.
- **Unknown prior** → transform still applies; verification falls back to properties (no
  permissive literals remain, the file still parses), and the prior/result pair is
  recorded in the marker so it can be enumerated later.

## Gates

- The file must contain **exactly** 3× `mode: 0o777` and 3× `mode: 0o666` — verified
  identical in all five released variants. Any other count is a file this patch does not
  understand, and it **refuses** rather than transforming blindly.
- Zero of both means already patched → no-op.
- The transform is written to a temp file and verified **before** it replaces the live
  one: literals gone, `node --check` passes, and (for a known prior) the sha matches.

> The temp file is deliberately named with a `.js` suffix. `node --check` resolves module
> format from the extension and throws `ERR_UNKNOWN_FILE_EXTENSION` on anything else — so
> a bare `mktemp` suffix makes the parse check fail on a perfectly valid file, which reads
> as "the transform broke it" when nothing is wrong. This was a real bug caught on
> hardware.

## Restarts only `ble-config.service`

**No detach, by design.** ngrok runs inside `mqtt-client`, not this service, so restarting
`ble-config` neither drops an SSH session nor disturbs in-flight print jobs.
`run_detached_if_ssh()` is absent because keeping it would be dead code whose log text
("restarting … will CLOSE this session") is false here. `is_remote_session()` **is** kept
verbatim from `_template` (BUG-047), because `--check` reports session context and a
future revision that ever restarts a tunnel-carrying service must not reinvent that
detection.

## Lineage — `ble-config`, and independent of `mqtt-client`

This is the **first patch in this tree to modify `ble-config.js`**.
`2026-08-20-ble-classic-scan-off` reads its sha for diagnostics but explicitly does not
modify it (`apply.sh:102`).

**Being separate from
[`2026-08-23-app-permissions-and-shadow-churn`](../2026-08-23-app-permissions-and-shadow-churn/)
is the point, not tidiness.** That patch requires the `mqtt-client` lineage head, and that
lineage's entry point (`2026-08-20-ngrok-session-reclaim`) accepts only stock
v1.0.8–v1.0.10 / v1.1.2–v1.1.4 — so a device on **v1.0.1–v1.0.7, v1.1.0 or v1.1.1 cannot
enter that lineage at all.** While the two fixes were welded together, that dead end
governed this one too, even though this change needs no lineage and applies to every
released variant. Split, each reaches as far as it actually can.

> **Sequencing note.** `2026-08-20-ble-classic-scan-off` also restarts
> `ble-config.service` and then **verifies** it, scanning its journal since a timestamp.
> Running the two concurrently can make that scan see restart noise it did not cause. They
> share no file, so ordering is free — just run them back to back rather than at the same
> time.

## Usage

```bash
scp -r patches/2026-08-24-ble-config-permissions eatabit@<device>:~/
ssh eatabit@<device>
./2026-08-24-ble-config-permissions/apply.sh --check   # no root, changes nothing
sudo ./2026-08-24-ble-config-permissions/apply.sh
```

`--check` exit codes: **0** already patched · **1** would refuse · **2** would apply.

```bash
sudo ./2026-08-24-ble-config-permissions/apply.sh --rollback
```

## Verified on hardware

Bench devices `.126` (v1.1.0, `d70edf02` variant), `.80` (v1.0.10) and `.121` (v1.1.4),
2026-08-24:

- `--check` on a stock prior → exit 2, naming the expected result sha.
- Apply on `.126` → transform parsed, **result matched the expected sha for the variant**,
  installed, `ble-config.service` returned active.
- `--check` on a patched device → exit 0; re-apply → no-op.
- Rollback restored `d70edf02…` exactly and left the service active.
- On `.80`/`.121`, already at the fixed file, the patch correctly reports "no permissive
  literals remain".
