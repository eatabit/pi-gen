# 2026-08-20 — ngrok agent session reclaim (BUG-049)

**Severity: High.** This is the remote-access path every other field patch is delivered
over. While it is broken, a patch campaign degrades to *reboot → connect → patch →
reboot* per device — and **each reboot drops in-flight print jobs**, so the maintenance
procedure inflicts the customer-visible harm itself.

> ### Self-contained rollup — no prerequisite patch
>
> It absorbed and **replaced** `2026-08-19-device-ready-flag-privatetmp` (BUG-039), which
> has been **deleted** — it installed the same `mqtt-client.service` byte-for-byte and a
> strictly older `mqtt-client.js`, so it had nothing left to contribute. It remains in git
> history if you need it. A device that already took it is a **recognised pre-state** here
> and simply gets the newer JS; a device that never did gets **both files in one run**.
>
> **Why it was merged rather than sequenced.** The first cut of this patch shipped only
> `mqtt-client.js` and *required* the 2026-08-19 patch as a pre-state, because this JS
> keeps the device-ready flag in `/run/eatabit` and only the patched unit creates that
> directory. It worked — but it cost an unpatched device **two runs and therefore two
> `mqtt-client` restarts**, and every restart **drops in-flight print jobs**. Measured
> side by side on a simulated device: `08-19` then rollup = **2 restarts**; rollup alone =
> **1**, same end state. Making the maintenance procedure inflict that harm twice is
> precisely what BUG-049 exists to stop.

## The bug

After **one** connect/disconnect cycle, every subsequent `startNgrokTunnel` failed with
`reasonCode 500` / *"Failed to establish tunnel"* — consistently, single attempts
included — **until `mqtt-client` restarted**.

Measured 2026-08-20 on `00000000ce4c5d90`:

```
12:03:51  mqtt-client restarted (over LAN)
12:04:14  startNgrokTunnel  succeeded  tcp://4.tcp.ngrok.io:22091
12:06:42  stopNgrokTunnel   sent       <- never answered, still `sent` an hour later
12:27:57  startNgrokTunnel  failed 500
~13:2x    startNgrokTunnel  failed 500
```

`00000000cce04a18` showed the same pattern independently.

## Root cause — confirmed, not hypothesised

The `@ngrok/ngrok` **agent session is process-global and outlives the tunnel it was
created for.** `ngrok.forward()` builds an implicit default session and hands back only
a `Listener`; closing that listener leaves the session connected, and the module gives
you no way to reach the implicit session it made — `ngrok.disconnect()` and
`ngrok.kill()` both close **listeners**, not sessions (their own doc comments say so).
So every stop leaked a session, and once they accumulated, every later `forward()` in
the process failed until the process restarted.

Observed directly on the ngrok API: **both LAN printers holding sessions with no tunnels
attached**, and an **orphan session alive since 2026-08-17** — no tunnel for two days.

**`BUG-035`'s reaper does not help.** It reclaims ngrok **credentials**, not
**sessions**. A clean credential ledger says nothing about how many stale agent sessions
a device is holding. That distinction is the whole bug.

## The fix — two files, six defects, one restart

Five BUG-049/BUG-038 fixes in `mqtt-client.js`, plus BUG-039's two-file fix carried in
from the superseded patch. Deliberately bundled so the whole set costs **one**
`mqtt-client` restart.

| | Fix |
| --- | --- |
| **F1** | Publish a terminal status on **both** previously silent branches — the missing-`authToken` guard, and the *"no active ngrok SSH forwarding to stop"* branch. Both used to `return` without publishing, leaving the `DeviceCommand` at `sent` forever. |
| **F2** | **Bound**, **serialise**, and **reclaim**. The tunnel is now built on a session *we own* via `SessionBuilder`, and stop closes the listener **and** the session. Every ngrok call is bounded and funnelled through a single-writer queue. |
| **F3** | Fix the check-then-act race on the `ngrokListener` global. Production-confirmed: two live tunnels from pid `124474`, the loser **uncloseable** because the handle had already been overwritten. |
| **F5** | Publish the **real** `err.message` instead of the hardcoded `"Failed to establish tunnel"`, sanitized to AWS's documented `StatusReason` constraints. |

| **BUG-039** | Carried in unchanged: the device-ready receipt reprints on every service restart, because its guard flag lived in `/tmp` and `PrivateTmp=true` hands the unit a fresh `/tmp` on every start. Fixed by `RuntimeDirectory=eatabit` + `RuntimeDirectoryPreserve=restart` in the unit **and** moving the flag to `/run/eatabit` in the JS. **Both halves are required** — installing the JS without the unit reintroduces that bug silently, which is why the unit is gated here even though most target devices already have it. |

**F4** (pinning `@ngrok/ngrok`) is **not** in this patch — see BUG-049's `planning.md`.

### The stop path reports SUCCEEDED when there was nothing to stop

Deliberate, and a later reader will want to "fix" it back. *"There was nothing to stop"*
means **the requested end state already holds**: the caller asked for no tunnel, and
there is no tunnel. Reporting `FAILED` for a satisfied post-condition is what **invites
the retry** — and a retry loop against a device already in the desired state is exactly
how an operator burns the window in which the device is reachable. The distinct
`reasonCode` (`NO_TUNNEL_ACTIVE`) keeps the diagnostic information without lying about
the outcome.

### Timeouts are chosen against the cloud-side window

A device-side bound longer than the command's `executionTimeoutSeconds` publishes into a
window that has already closed and buys nothing.

| | cloud window | device-side bound |
| --- | --- | --- |
| `startNgrokTunnel` | 60 s (set explicitly in `iot-backend`) | 15 s connect + 15 s listen |
| `stopNgrokTunnel` | 10 s (AWS default, deliberately) | 4 s + 4 s = 8 s worst case |

The build is bounded **per step**, not as a whole: an outer race would abandon a build
that had already connected, and the session it went on to create would be untracked and
unclosable — reintroducing this very bug on the timeout path.

## Affected versions / Coverage

Both files are gated **independently** by sha256, so a half-applied device is completed
rather than refused.

**Accepted pre-state — `mqtt-client.js`:**

| sha256 | meaning |
| --- | --- |
| `d4647dab…` | output of the deleted `2026-08-19` patch (also the pre-BUG-049 image source) |
| `2f8848db…` | stock v1.0.10 / v1.1.4 |
| `e80b7a17…` | stock v1.0.8, v1.0.9, v1.1.2, v1.1.3 |
| `51a012ae…` `b30bc9c2…` `607f3d28…` | the three 2026-06 field-patch intermediates |

**Accepted pre-state — `mqtt-client.service`:** `e92b2a15…` (stock unit,
v1.0.8–v1.0.10 / v1.1.2–v1.1.4). The already-patched unit `84aa9272…` is the target and is
left alone.

**Result:** `mqtt-client.js` = `323299af…`, `mqtt-client.service` = `84aa9272…`.

**Excluded by design:** v1.0.1, v1.0.2–v1.0.7 and v1.1.1. Dropping this `mqtt-client.js`
onto those builds would also apply **many unrelated intervening changes** — a far larger
change than this patch is scoped to make — and their unit is a different variant. Those
devices get the fix through the **v1.0.11 / v1.1.5 image release** instead.

**Fleet math** (measured 2026-08-19 for BUG-039, 31 connected devices): this patch applies
to roughly **7** — 1 × v1.0.10, 6 × v1.1.4. The remaining ~24 are the release's job. Three
devices report Version `1.1.0`, for which no tag exists; they will be refused by checksum,
which is the correct outcome, and the refusal prints their actual sha.

Both refusal paths print the observed sha256, so an unsampled field device reports its own
state in one run rather than merely being rejected.

**Not yet byte-identical to the release.** `ISSUE-065` owns v1.0.11 / v1.1.5, and
`BUG-044` (unit) and `BUG-045` (js) also land in that cut, so the shas the release finally
ships will differ from both `FIXED_*` values. A device freshly flashed to v1.0.11 / v1.1.5
will **not** no-op here — it hits the refusal path and prints its observed sha. Safe, but
not the intended end state; `ISSUE-065` reconciles it.

## Validation status

**VALIDATED ON HARDWARE, 2026-08-20 — both LAN printers, 26 assertions, 0 failures.**

| Device | IP | Version | Result |
| --- | --- | --- | --- |
| `00000000ce4c5d90` | `192.168.1.80` | **1.0.10** | applied 15:35:26, all checks pass |
| `00000000cce04a18` | `192.168.1.121` | 1.1.4 | applied 15:36:12, all checks pass |

Three start → stop → start cycles within **one** `mqtt-client` process lifetime on each
device, after a restart over LAN. Every start succeeded — including the **second and
third**, which are the assertion, and which failed `500` before this patch:

| | cycle 1 | cycle 2 | cycle 3 |
| --- | --- | --- | --- |
| `cce04a18` | 3.54 s | **2.30 s** | **2.78 s** |
| `ce4c5d90` | 2.40 s | **4.38 s** | **4.72 s** |

Also confirmed on hardware: **zero tunnel-less agent sessions** left by either device's
cycles; the idle stop reporting `SUCCEEDED` / `NO_TUNNEL_ACTIVE`; one `mqtt-client`
process with no duplicate tunnel; the success path still carrying the tunnel URL in
`reasonDescription`; this script's **detach over SSH**, its **idempotent no-op**, and its
**refusal** paths.

An **induced failure** (ngrok's agent host blackholed via `/etc/hosts`, self-restoring)
produced, read straight from the `DeviceCommand` row with no device log dive:

```
failed | 504 | ngrok session connect timed out after 15000 ms
```

— which is F1, F2 and F5 all demonstrated at once: terminal instead of stuck at `sent`,
bounded, and carrying the real error rather than the old hardcoded constant.

> **One criterion is NOT covered on hardware, stated rather than quietly counted:** the
> missing-`authToken` guard. The backend always supplies a token, so it cannot be
> provoked through the normal command path. It is covered by unit test and inspection.

> **Correction to BUG-049's record:** it states both measured devices run 1.1.4.
> `ce4c5d90` actually runs **1.0.10** — it is on the **`hw/1.0`** line. That makes the
> `hw/1.0` landing not optional, and this patch applying cleanly to both is direct
> evidence the same change is right for both lines.

Full detail: the item's `artifacts/bug049-hardware-validation-2026-08-20.md`.

### Rollup re-validation

The hardware results above were produced by the **first cut** of this patch (JS only). The
rollup changes only the *installer* and adds `mqtt-client.service`; the `mqtt-client.js`
payload is byte-identical (`323299af…`), so the device behaviour those results measured is
unchanged. The installer was re-tested in full:

**26 assertions against a simulated device root, using the genuine stock files** recovered
from a printer's own `2026-08-19` backup directory (`2f8848db…` js, `e92b2a15…` unit — both
confirmed against the accepted list, so these are real inputs, not synthetic ones):

| case | asserted |
| --- | --- |
| virgin device (stock js + stock unit) | both files installed, both stock originals backed up, **exactly one restart** |
| device already on the `2026-08-19` patch | accepted, unit recognised as already correct and **not** reinstalled, js updated |
| already fully patched | idempotent no-op |
| unrecognised js | refused, observed sha printed, **neither** file modified |
| unrecognised unit with a good js | refused, **js not partially applied** |
| rollback from a virgin apply | **both** stock files restored |
| rollback from a `2026-08-19` device | js reverts to that patch's output, unit **not** downgraded |

**On hardware:** re-run on both LAN printers, which are already at the target state — both
correctly no-op'd, and `ExecMainStartTimestamp` was **unchanged** on both, confirming no
restart and so no disturbed print jobs.

## Usage

```sh
scp -r 2026-08-20-ngrok-session-reclaim eatabit@<device>:~/
ssh eatabit@<device>
cd 2026-08-20-ngrok-session-reclaim
sudo ./apply.sh              # apply — no prerequisite patch
sudo ./apply.sh --rollback   # restore the pre-patch files
```

> On a device that did **not** already have the BUG-039 unit, the restart starts the
> service into a freshly created `/run/eatabit`, so the ready receipt prints **exactly
> once**. That is expected and unavoidable — systemd recreates `RuntimeDirectory=` on
> start and discards anything placed there by hand, so the flag cannot be pre-seeded.
> Subsequent restarts are silent, which is the point of the BUG-039 half.

Over SSH the restart+verify runs **detached** (`setsid`) and logs to
`/usr/local/lib/eatabit/patches/2026-08-20-ngrok-session-reclaim/apply.log`, because
restarting `mqtt-client` drops the ngrok tunnel the operator is standing on. Remote
detection does **not** rely on `$SSH_CONNECTION` alone — `sudo`'s `env_reset` strips it —
it also walks the parent process chain for `sshd` (`BUG-047`).

### Verifying the fix — the *second* start is the assertion

1. `startNgrokTunnel` → expect success.
2. `stopNgrokTunnel` → expect `SUCCEEDED`, `reasonCode` `200`.
3. `startNgrokTunnel` → **must succeed.** Before this patch it failed `500`.

Repeat at least three times within one `mqtt-client` process lifetime, and confirm on the
ngrok API that **no tunnel-less agent session remains** after step 2. Restart
`mqtt-client` **over LAN**, never through the tunnel under test.
