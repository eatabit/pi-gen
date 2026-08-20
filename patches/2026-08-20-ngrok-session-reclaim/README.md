# 2026-08-20 — ngrok agent session reclaim (BUG-049)

**Severity: High.** This is the remote-access path every other field patch is delivered
over. While it is broken, a patch campaign degrades to *reboot → connect → patch →
reboot* per device — and **each reboot drops in-flight print jobs**, so the maintenance
procedure inflicts the customer-visible harm itself.

> **Apply [`2026-08-19-device-ready-flag-privatetmp`](../2026-08-19-device-ready-flag-privatetmp/)
> first.** This patch deliberately accepts exactly one prior `mqtt-client.js` — that
> patch's output — and refuses to run unless the BUG-039-patched unit file is already in
> place. See *Coverage* below for why.

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

## The fix — one file, five defects, one restart

All of it lands in `mqtt-client.js`, deliberately bundled so it costs **one**
`mqtt-client` restart rather than five.

| | Fix |
| --- | --- |
| **F1** | Publish a terminal status on **both** previously silent branches — the missing-`authToken` guard, and the *"no active ngrok SSH forwarding to stop"* branch. Both used to `return` without publishing, leaving the `DeviceCommand` at `sent` forever. |
| **F2** | **Bound**, **serialise**, and **reclaim**. The tunnel is now built on a session *we own* via `SessionBuilder`, and stop closes the listener **and** the session. Every ngrok call is bounded and funnelled through a single-writer queue. |
| **F3** | Fix the check-then-act race on the `ngrokListener` global. Production-confirmed: two live tunnels from pid `124474`, the loser **uncloseable** because the handle had already been overwritten. |
| **F5** | Publish the **real** `err.message` instead of the hardcoded `"Failed to establish tunnel"`, sanitized to AWS's documented `StatusReason` constraints. |

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

**Accepted pre-state — exactly one:**

| file | sha256 | meaning |
| --- | --- | --- |
| `mqtt-client.js` | `d4647dab…bcbc3376` | output of `2026-08-19-device-ready-flag-privatetmp` |
| `mqtt-client.service` | `84aa9272…201fc25f` | that patch's unit — **required, never modified here** |

**Result:** `mqtt-client.js` = `323299af…17d026c0`.

**Why so narrow.** This payload carries BUG-039's device-ready flag in `/run/eatabit`,
which only works when the unit has `RuntimeDirectory=eatabit` — and **this patch does not
ship a unit file**. Dropping this JS on a device with the stock unit would move the flag
to a directory systemd never creates, the write would fail, and the ready receipt would
reprint on every restart: BUG-039 again, in the silent direction. So a device that has
not taken the 2026-08-19 patch is **refused**, and the refusal says so.

Both gates print the observed sha256, so an unsampled field device reports its own state
in one run rather than merely being rejected.

**Not yet byte-identical to the release.** `ISSUE-065` owns v1.0.11 / v1.1.5, and
`BUG-044` (unit) and `BUG-045` (js) also land in that cut, so the sha the release finally
ships will differ from `FIXED_JS_SHA`. A device freshly flashed to v1.0.11 / v1.1.5 will
**not** no-op here — it hits the refusal path and prints its observed sha. Safe, but not
the intended end state; `ISSUE-065` reconciles it.

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

## Usage

```sh
scp -r 2026-08-20-ngrok-session-reclaim eatabit@<device>:~/
ssh eatabit@<device>
cd 2026-08-20-ngrok-session-reclaim
sudo ./apply.sh              # apply
sudo ./apply.sh --rollback   # restore the pre-patch file
```

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
