# Field patch rollout log

Per-device record of what was applied, when, the evidence it worked, and what is still
outstanding. One row per device per patch, newest campaign first.

**Why this file exists beside the patches rather than in a tracker item:** a rollout spans
several records at once (`BUG-041`, `BUG-042`, `BUG-045`, `BUG-049`, `BUG-057`,
`ISSUE-068`), so it has no single owning item. Per-bug artifacts such as
`BUG-040/artifacts/field-rollout-and-baselines.md` remain authoritative for that bug's own
detail; this file is the cross-cutting view.

**Timestamps are UTC unless a `+01:00` offset is shown.** Several devices were on
`Europe/London` when patched and their markers record BST — the offset is preserved
verbatim rather than normalised, because the marker file is the primary evidence.

**A device's version string does not determine patch applicability — its file checksums
do.** That rule decided three cases in this campaign, twice against the prediction the
version string implied. See *Checksum gate, not version* below.

---

## EXCLUDED — local test bench devices. Do not patch.

These three are the **local test bench** on the 192.168.1.0/24 LAN. They are **out of scope
for field rollouts** and must not be patched as part of one. They are the validation
hardware and are frequently mid-experiment with uncommitted patches.

| IP | Device | FW |
|---|---|---|
| `192.168.1.80` | `00000000ce4c5d90` | v1.0.10 |
| `192.168.1.121` | `00000000cce04a18` | v1.1.4 |
| `192.168.1.126` | `0000000003c45d6d` | v1.1.0 |

Read-only audits of these are fine — the log2ram health check on 2026-08-24 was one, and
found all three healthy. **Applying a patch to them is not.**

> **This was tested the hard way on 2026-08-24.** A rollout request named `cce04a18`; it is
> a bench unit. Nothing was applied — the reclaim patch was already present (marker
> `2026-08-20T20:24:33+01:00`) and `--check` returned **exit 1 `WOULD REFUSE`** because its
> `js` had since moved to an unrecognised `7ecbf0ea…`. The cause: two patches installed
> that **are not in this repo** —
> `2026-08-23-log-permissions-and-rotation` and
> `2026-08-23-app-permissions-and-shadow-churn` — the latter mid apply/rollback/apply cycle
> **16 minutes before** the session connected. Another worker owned that device's state.

---

## Campaign 2026-08-23 → 2026-08-24

### Devices

| Device | UUID | FW | Line |
|---|---|---|---|
| `000000003e83bb41` | `21f0e3ad-e2fe-4019-8aa0-85b1eccc8a8b` | v1.1.0 | hw/1.1 |
| `00000000db996da7` | `d5f40af8-dabe-40a1-a808-41872656b818` | v1.0.6 | hw/1.0 |
| `00000000a15e12da` | `75b73129-c874-44de-baec-987267924be4` | v1.1.4 | hw/1.1 |
| `00000000c3343f47` | `1b403828-0409-4aa0-afbd-cb0ad3692b69` | v1.1.4 | hw/1.1 |
| `0000000042288e07` | `172144e4-aa9a-451e-be66-b98233f39be9` | v1.1.1 | hw/1.1 |
| `0000000096a39148` | `1382dc9c-9abb-4b48-b0f7-61c6179de18b` | v1.1.1 | hw/1.1 |
| `0000000092f7766c` | `512055fd-ae2e-41e3-bdbb-6b3665cfccf0` | v1.1.1 | hw/1.1 |
| `00000000bd396b5c` | `583bd49e-87db-4892-94fe-ec3f19a368e6` | v1.1.1 | hw/1.1 |
| `00000000edec02ad` | `34e4e3b1-7193-4c37-99f3-216289625363` | v1.1.0 | hw/1.1 |
| `0000000094300990` | `147e874c-b5dd-49ac-a8da-6c965804353c` | v1.1.1 | hw/1.1 |
| `0000000019dffb8b` | `cac961b2-722d-4bf8-bb35-cbd0976bbbf6` | **v1.0.2** | hw/1.0 |

### What was applied

| Device | Patch | Applied (marker) | Evidence |
|---|---|---|---|
| `3e83bb41` | gateway-timezone-utc | `2026-08-23T21:20:18+00:00` | MainPID 280197 unchanged; 3-way agreement |
| `db996da7` | ngrok-session-reclaim | `2026-08-23T23:37:38+01:00` | js `1d49a43a`, unit `84aa9272`; 3×3 cycles all 200 |
| `db996da7` | gateway-timezone-utc | `2026-08-24T01:04:06+00:00` | MainPID 1437 unchanged; 3-way agreement |
| `db996da7` | mqtt-keepalive-tolerance | `2026-08-24T01:11:31+00:00` | js `b009b68c`; `with_ping_timeout_ms(10_000)` live |
| `db996da7` | log2ram-timer-hourly-sync | `2026-08-24T01:46:53+00:00` | **sync verified 02:00:18Z** — 73,137 B → 118 B |
| `a15e12da` | log2ram-timer-hourly-sync | `2026-08-24T03:19:52+01:00` | **sync verified 03:00:20Z** — 378,680 B → 128 B |
| `a15e12da` | gateway-timezone-utc | `2026-08-24T02:24:11+00:00` | MainPID 14160 unchanged |
| `a15e12da` | mqtt-keepalive-tolerance | `2026-08-24T02:28:40+00:00` | js `b009b68c`; PID 4448 → 21581 |
| `c3343f47` | gateway-timezone-utc | `2026-08-24T12:05:39+00:00` | MainPID 21208 unchanged |
| `c3343f47` | mqtt-keepalive-tolerance | `2026-08-24T12:16:51+00:00` | js `b009b68c`; DNS guard 5/5 pre-restart |
| `c3343f47` | log2ram-timer-hourly-sync | `2026-08-24T12:22:49+00:00` | installed; **first sync NOT observed** |
| `42288e07` | ngrok-session-reclaim | `2026-08-24T16:02:22+01:00` | js `1d49a43a`, unit `84aa9272`; 3×3 cycles all 200 |
| `42288e07` | mqtt-keepalive-tolerance | `2026-08-24T16:11:36+01:00` | js `b009b68c`; DNS guard 5/5 pre-restart |
| `42288e07` | gateway-timezone-utc | `2026-08-24T15:23:23+00:00` | MainPID 2053 unchanged; 3-way agreement |
| `42288e07` | log2ram-timer-hourly-sync | `2026-08-24T15:23:45+00:00` | installed; **first sync NOT observed** |
| `42288e07` | ble-classic-scan-off | `2026-08-24T15:25:45+00:00` | `PSCAN ISCAN` → gone; self-check passed; mqtt-client untouched |
| `92f7766c` | ngrok-session-reclaim | `2026-08-24T17:07:07+01:00` | js `1d49a43a`, unit `84aa9272`; 3×3 cycles all 200; needed a reboot first |
| `92f7766c` | gateway-timezone-utc | `2026-08-24T16:19:16+00:00` | MainPID 1532 unchanged; 3-way agreement |
| `92f7766c` | log2ram-timer-hourly-sync | `2026-08-24T16:19:22+00:00` | installed; **first sync NOT observed** |
| `92f7766c` | ble-classic-scan-off | `2026-08-24T16:21:25+00:00` | `PSCAN ISCAN` → gone; self-check passed; mqtt-client untouched |
| `92f7766c` | mqtt-keepalive-tolerance | `2026-08-24T16:22:03+00:00` | js `b009b68c`; DNS guard 5/5; PID 1532 → 3373 |
| `bd396b5c` | ngrok-session-reclaim | `2026-08-24T17:46:00+01:00` | js `1d49a43a`, unit `84aa9272`; 3×3 cycles all 200 |
| `bd396b5c` | gateway-timezone-utc | `2026-08-24T16:55:45+00:00` | MainPID 2276 unchanged |
| `bd396b5c` | log2ram-timer-hourly-sync | `2026-08-24T16:55:50+00:00` | **first sync VERIFIED 17:00:07Z** — 73,138 B → 119 B |
| `bd396b5c` | ble-classic-scan-off | `2026-08-24T16:56:34+00:00` | `PSCAN ISCAN` → gone; self-check passed |
| `bd396b5c` | mqtt-keepalive-tolerance | `2026-08-24T16:57:15+00:00` | js `b009b68c`; reconnect took 58 s (degraded link) |
| `edec02ad` | ngrok-session-reclaim | `2026-08-24T18:25:32+01:00` | js `1d49a43a`, unit `84aa9272`; needed a reboot first; **first v1.1.0 field device** |
| `edec02ad` | gateway-timezone-utc | `2026-08-24T17:48:09+00:00` | MainPID 1487 unchanged |
| `edec02ad` | log2ram-timer-hourly-sync | `2026-08-24T17:48:15+00:00` | **first sync VERIFIED 18:00:03Z** — 73,058 B → 119 B |
| `edec02ad` | ble-classic-scan-off | `2026-08-24T17:50:20+00:00` | `PSCAN ISCAN` → gone; **5.44× mdev** |
| `edec02ad` | mqtt-keepalive-tolerance | `2026-08-24T17:51:02+00:00` | js `b009b68c`; DNS guard 5/5; PID 1487 → 3434 |
| `94300990` | **watchdog-exit-hang** | `2026-08-24T19:29:37+01:00` | **factory-fresh device, first patch ever**; js `177e10b8`→`e80b7a17`, unit `7999b8b6`→`e92b2a15` |
| `94300990` | ngrok-session-reclaim | `2026-08-24T19:36:07+01:00` | js `1d49a43a`, unit `84aa9272`; 3×3 cycles all 200 |
| `94300990` | gateway-timezone-utc | `2026-08-24T18:44:44+00:00` | MainPID 2274 unchanged |
| `94300990` | log2ram-timer-hourly-sync | `2026-08-24T18:44:50+00:00` | **first sync VERIFIED 19:00:05Z** — 73,139 B → 119 B |
| `94300990` | ble-classic-scan-off | `2026-08-24T18:45:20+00:00` | `PSCAN ISCAN` → gone; 2.45× mdev |
| `94300990` | mqtt-keepalive-tolerance | `2026-08-24T18:46:01+00:00` | js `b009b68c`; DNS guard 5/5; PID 2274 → 3939 |
| `19dffb8b` | ngrok-session-reclaim | `2026-08-24T20:31:12+01:00` | js `1d49a43a`, unit `84aa9272`; needed a reboot first; 3×3 cycles all 200 |
| `19dffb8b` | gateway-timezone-utc | `2026-08-24T19:42:47+00:00` | MainPID 1494 unchanged |
| `19dffb8b` | log2ram-timer-hourly-sync | `2026-08-24T19:42:53+00:00` | **first sync VERIFIED 20:00:03Z** — 73,144 B → 119 B |
| `19dffb8b` | ble-classic-scan-off | `2026-08-24T19:43:25+00:00` | `PSCAN ISCAN` → gone; 1.74× mdev |
| `19dffb8b` | mqtt-keepalive-tolerance | `2026-08-24T19:44:06+00:00` | js `b009b68c`; DNS guard 5/5; PID 1494 → 3232 |

`96a39148` was **verified only** through 2026-08-24 — it already carried all seven patches
(reclaim `2026-08-21T19:35:07+01:00`, keepalive `2026-08-23T17:31:37+00:00`). It was then
patched three times on 2026-08-25; see *ISSUE-068 closed end-to-end* below.

### ISSUE-068 closed end-to-end — `96a39148`, 2026-08-25

The first device in the fleet with **all three** ISSUE-068 patches, and so the first where
the fix is complete rather than half-applied.

| Device | Patch | Applied | Evidence |
|---|---|---|---|
| `96a39148` | log-permissions-and-rotation | `2026-08-25T02:00:23+00:00` | dirs `777`→`755`; both logrotate stanzas installed; `mqtt-client` PID 28480 **unchanged**; `mqtt-client.log` had gone **unrotated since 2026-04-22** (4 months, 2.9 MB) |
| `96a39148` | ble-config-permissions | `2026-08-25T02:05:09+00:00` | js `ecbf9a06`→`fff83fb7`; `0o777`×3→0, `0o666`×3→0; `ble-config` PID 7044→44990 |
| `96a39148` | app-permissions-and-shadow-churn | `2026-08-25T02:10:59+00:00` | js `b009b68c`→`7ecbf0ea`; 8 sites (`0o755`×5 + `0o644`×3); 3 snapshots retired to `/run/eatabit`; PID 28480→45656; DNS guard 5/5; reconnected in **5 s** |

**The pair is proven on hardware, not merely asserted.** `ble-config` genuinely restarted
(PID 7044 → 44990) and the directories **stayed `755`**. With the pre-patch js that restart
would have re-created them `0777` and silently undone the companion — which is exactly the
"neither is sufficient alone" claim in both READMEs, now demonstrated rather than argued.

The recreation window did **not** bite here only because `ble-config` had not restarted
since 2026-08-21, so nothing reverted the directories in the 5 minutes between the two
patches. **On a device where `ble-config` restarts more often, apply the two in immediate
succession.**

**Churn eliminated, measured before it was destroyed:** `96a39148` logged **96 health
persists/day** (2026-08-22/23/24: 96 / 102 / 96) at 1714 B each = **160.7 KiB/day** to the
card, independently confirming the patch README's ~159 KiB/day. Lifetime on-card total was
**8,792** rewrites. `rotate 7` on a 2.9 MB log also reclaims ~2.5 MB of card.

**BUG-039 held across the `mqtt-client` restart** — `/run/eatabit/device-ready-printed` kept
its original `2026-08-21 18:24:45` mtime via `RuntimeDirectoryPreserve=restart`, so no
duplicate ready receipt printed. Verified without a test print (see finding 13).

### Declined — correctly

| Device | Patch | Why |
|---|---|---|
| `db996da7` | 2026-06-30-offline-reboot-and-expired-job | **Superseded.** Its end state `2f8848db` is stock v1.0.10/v1.1.4; the device already ran `1d49a43a`, which is that generation *plus* BUG-039 + BUG-049. Verified by diff: all 130 lines it adds are present in the reclaim payload, 0 missing. Applying it would have been a downgrade. |

---

## Keepalive (BUG-045) — pre-patch baselines

The soak test is whether the **~33.2 s floor cluster thins**, not whether it relocates to
~40 s. If it merely moves, the cause is packet **loss** and this is the wrong fix — the
README's own falsification criterion.

| Device | Link | Events | Short (<16 min) fitting `n×30s+~3.2s` | **~33.2 s floor** | Soak value |
|---|---|---|---|---|---|
| `42288e07` | **65/70** | **713** | **305/430 (71%)** | **107** | **primary** |
| `c3343f47` | 28/70 | 248 | 53/127 (42%) | 14 | secondary |
| `db996da7` | — | 49 | 19/24 (79%) | 6 | secondary |
| `92f7766c` | 70/70 | 256 | 33/82 (40%) | 2 | weak — tiny floor |
| `bd396b5c` | 53/70 | 220 | 45/61 (74%) | 6 | secondary |
| `edec02ad` | **48/70** | 426 | 58/97 (60%) | 14 | secondary — worst link measured |
| `94300990` | 57/70 | 113 | 9/10 (90%) | 1 | weak — only 10 short sessions |
| `19dffb8b` | **70/70** | 369 | 37/43 (**86%**) | **23** | **SECONDARY** — cleanest signal: perfect link, so almost no loss |
| `a15e12da` | — | 5 | 0 short sessions | 0 | **useless — no cluster to thin** |

Long sessions (≥16 min) fit at 4–16%, i.e. chance, so the modulo test discriminates
properly and only the short-session column is meaningful.

**Fit rate tracks link quality**, which matches the README's claim that the patch buys
tolerance for latency and not loss:

- 65/70 → 71% latency-artifact disconnects → expect the cleanest improvement
- 28/70 → 42% → expect **partial** improvement; do **not** read that as the fix failing

---

## log2ram (BUG-041) — exposure closed

| Device | Unsynced before | Last disk write before | After first sync |
|---|---|---|---|
| `db996da7` | 73,137 B | boot (22:34:14Z, same day) | 118 B ✅ |
| `a15e12da` | 378,680 B | **2026-07-28** (27 days) | 128 B ✅ |
| `c3343f47` | 379,080 B | **2026-08-05** (19 days) | **not observed** ⚠ |
| `42288e07` | 73,056 B | boot (14:58Z, same day) | **not observed** ⚠ |
| `92f7766c` | 73,057 B | boot (16:02Z, same day) | **not observed** ⚠ |
| `bd396b5c` | 73,138 B | **2026-04-21** (4 months — its own provisioning date) | **119 B ✅ verified 17:00:07Z** |
| `edec02ad` | 73,058 B | same day | **119 B ✅ verified 18:00:03Z** |
| `94300990` | 73,139 B | same day | **119 B ✅ verified 19:00:05Z** |
| `19dffb8b` | 73,144 B | same day | **119 B ✅ verified 20:00:03Z** |

Bench units (`cce04a18` v1.1.4, `ce4c5d90` v1.0.10, `03c45d6d` v1.1.0) audited
2026-08-24: all three healthy — timer enabled+active, exactly one `TimersCalendar` entry,
`--check` exit 0, tmpfs/disk delta ~110 B, 0 errors in 24 h, `mqtt-client` untouched.

**Measured write cost, which the README flags as a derived bound never confirmed on
hardware:** steady state ~950–1,540 bytes per sync ≈ **25–35 KB/day**, against the derived
~1 MB/day ceiling — roughly 30× inside it. One unit reported `speedup is 620.44` on a
705 KB tree, confirming `--inplace --no-whole-file` writes only changed blocks.

---

## BLE classic-scan-off (BUG-040) — measured effect varies by site

Radio state change is proven on both devices (`hci0 UP RUNNING PSCAN ISCAN` → `UP RUNNING`,
recovery self-check passed, `mqtt-client` never restarted). The **latency benefit is not
uniform**, and on a noisy site it is not measurable at all.

| Device | Link | mdev before | mdev after | Verdict |
|---|---|---|---|---|
| `db996da7` | — | 7.799 ms | **1.424 ms** | 5.48× better; loss 1.67% → 0% |
| `42288e07` | 65/70 | 6.521 ms | 8.582 ms | **inconclusive — noise exceeds the effect** |
| `92f7766c` | 70/70 | 7.029 ms | 4.731 ms | 1.49× — **real but at the noise floor** |
| `bd396b5c` | 53/70 | 64.754 ms | 41.033 ms | 1.58× — real, but **41 ms remains: 15× the BT-OFF reference** |
| `edec02ad` | **48/70** | 53.959 ms | **9.920 ms** | **5.44×** — worst link, biggest gain |
| `94300990` | 57/70 | 13.249 ms | 5.398 ms | 2.45× — moderate, ~60% of jitter was BR/EDR |
| `19dffb8b` | **70/70** | 10.659 ms | 6.132 ms | 1.74× — post-fix avg 3.845 ms, near the BT-OFF reference |

On `42288e07` a within-run A/B (`measure.sh -a asis,classic`) put two arms of the **same**
radio state at mdev 6.519 and 4.470 — a **1.46× run-to-run spread**, larger than the 1.32×
"worsening" the naive before/after showed. So that before/after was noise, not a
regression. Its readings sit between the ISSUE-064 references (BT ON 22.363 ms, BT OFF
2.668 ms) and nearer the OFF end, i.e. this site was never paying the severe BR/EDR
penalty `db996da7` was.

**The effect does NOT track link quality — do not predict it from the link.** Six devices
measured, and the gain and the link are essentially uncorrelated:

| device | link | mdev gain |
|---|---|---|
| `edec02ad` | 48/70 (worst) | **5.44×** (largest) |
| `db996da7` | — | 5.48× |
| `94300990` | 57/70 | 2.45× |
| `19dffb8b` | 70/70 (perfect) | 1.74× |
| `bd396b5c` | 53/70 | 1.58× |
| `92f7766c` | 70/70 (perfect) | 1.49× |

What separates them is whether BR/EDR is the **dominant** jitter source. On `edec02ad`
mdev collapsed to 9.9 ms, so it was; on `bd396b5c` 41 ms of network jitter remained, so it
was not. A perfect link can show a small gain (`19dffb8b`, `92f7766c`) simply because there
was little jitter to remove — its post-fix avg of 3.845 ms sits at the ISSUE-064 BT-OFF
reference of 3.223 ms, i.e. near-optimal. The within-run A/B is the only way to know in
advance — measure, do not assume.

`92f7766c` was measured the right way round: a within-run `-a asis,classic` A/B **before**
patching, which both quantified the effect (1.49×) and predicted it would be modest —
rather than discovering that afterwards and having to separate noise from signal. Do this
on every device from now on.

**Method note:** a single 60-packet arm cannot resolve a sub-2× difference on a congested
2.4 GHz network. Use `measure.sh -a asis,classic` (within-run, same conditions) rather than
two runs minutes apart, and treat any ratio under ~1.5× as noise.

---

## Checksum gate, not version

Three devices had version strings that predicted the wrong answer:

| Device | FW | Version implies | Checksums said | Why |
|---|---|---|---|---|
| `db996da7` | v1.0.6 | excluded | **accepted** | prior watchdog + offline-reboot patches moved js/unit to `51a012ae`/`e92b2a15` |
| `3e83bb41` | v1.1.0 | outside `KNOWN_VERSIONS` | **accepted** | 2026-06-30 patch had already installed `2f8848db` |
| `42288e07` | v1.1.1 | "excluded by design" | **accepted** | took the two prerequisites → `2f8848db`/`e92b2a15` |

**v1.1.0 is not on the reclaim patch's exclusion list at all.** What blocks it is its
checksums *while factory-fresh* (`177e10b8`/`7999b8b6`). After
`2026-05-12-watchdog-exit-hang` → `2026-06-30-offline-reboot-and-expired-job` it becomes
`2f8848db`/`e92b2a15` and is accepted. It is a **prerequisite chain, not an exclusion**.

Stock v1.1.1 carries **identical** shas to stock v1.1.0, so the gate cannot distinguish
them. Any older-build device that has taken the two prerequisites converges on accepted
checksums — including the v1.1.1 devices the README calls "excluded by design". The gate
does not enforce that stated exclusion, and in practice v1.1.1 devices are in scope.

---

## Follow-up actions

### Open

1. **Keepalive soak (≥24 h).** Primary subject `42288e07` (107 floor events). Secondary
   `c3343f47` (14) and `db996da7` (6). Ignore `a15e12da`. Test: does the floor cluster
   **thin**, or merely relocate to ~40 s? Reminder set for 2026-08-25T12:30Z
   (`trig_011Rc5GaKdwabyAoSP11GCvy`) — **still names c3343f47/db996da7 as primary and
   should be updated to lead with `42288e07`.**
2. **Confirm the first log2ram sync on `c3343f47`, `42288e07` and `92f7766c`** — the three
   whose tunnels were closed before their first sync. `bd396b5c` and `edec02ad` were watched
   end to end and are done. Use the predicate in operational note 11, not `Result` alone.
   `stat -c%y /var/hdd.log/log2ram.log` should read 2026-08-24 13:00+, not 2026-08-05.
3. **Patches still missing per device:**
   - `3e83bb41` — keepalive, log2ram, ble-classic-scan-off (only timezone applied)
   - `92f7766c` — **complete** (6 patches) as of 2026-08-24T16:22Z
   - `cce04a18` (bench) — gateway-timezone-utc; still `Europe/London`, so its hourly
     log2ram schedule skips one slot at the spring DST transition

### Findings raised, not yet actioned

4. **`BUG-057` has a second device — and the ratio, not the count, is the signature.**
   Recorded as a single-device finding on `c3343f47` (13,840 DNS failures, 12 watchdog
   fires). `42288e07` shows **5,131 DNS failures and 91 watchdog fires** — same signature,
   and it needed a reboot on 2026-08-24 to clear a wedged tunnel. Until BUG-057 ships, any
   `mqtt-client` restart on either device is safe only while DNS resolves; use a pre-restart
   DNS guard (5 resolves, abort on any failure).

   **`96a39148` is a measured counter-example** (2026-08-25, same 4-month log window,
   2026-04-22 → 2026-08-25):

   | Device | DNS failures | Watchdog fires | Ratio | Reading |
   |---|---|---|---|---|
   | `c3343f47` | 13,840 | 12 | **1153:1** | 115.3 h offline / 7 outages; power-cycle recovery |
   | `42288e07` | 5,131 | 91 | **56:1** | stalls, does not self-clear |
   | `96a39148` | 292 | 223 | **1.3:1** | watchdog clears each run |

   A ratio near **1:1 is the healthy profile** — failures occur and are recovered — whereas
   the pathology is thousands of failures accumulating against a handful of fires. So a bare
   "device has DNS failures" count does **not** identify a BUG-057 candidate; screen on the
   ratio. `96a39148` also had 29 successful connects, no reboot in 3 d 8 h, `NRestarts=0`,
   and DNS answering in 11 ms.

   **Consequence for rollout targeting:** after ISSUE-068 landed on `96a39148` it became the
   **only field device at `7ecbf0ea…`**, which is the single accepted prior of
   `2026-08-24-mqtt-never-connected-watchdog`. It is therefore the one field device that
   *could* take that patch — while being, on this evidence, among the devices that least
   **need** it. Eligibility and need point in opposite directions here; do not let the
   former stand in for the latter when field rollout is authorized.

5. **(SUPERSEDED — ISSUE-068 shipped a better fix; see 18.)** **`ISSUE-068` reproduced on every device seen** — `logrotate` fails with
   `result=exit-code` because `/usr/local/lib/eatabit/log` is mode `0777`. Image source
   sets it twice (`stage3/01-create-eatabit-lib/00-run.sh:21` uses `chmod 0777`,
   `stage3/05-install-log2ram/00-run.sh:80` uses `chmod 777`), so a permissions-only fix is
   silently undone — `su root root` in the logrotate stanza is the safer single-point change.
6. **The timezone patch fires `Persistent=true` timers at the switchover.** It restarts no
   service, but systemd runs every persistent timer whose window it now considers elapsed.
   **The set is not fixed — it varies per device** by which windows have lapsed:
   `db996da7`/`a15e12da`/`3e83bb41` fired `logrotate`+`dpkg-db-backup`+`e2scrub_all`+
   `apt-daily-upgrade`; `c3343f47` added `apt-daily` (five); `42288e07` fired
   `dpkg-db-backup`+`apt-daily-upgrade`+`e2scrub_all`+**`fstrim`** and **not `logrotate`**;
   `92f7766c` fired only **three** — `dpkg-db-backup`+`apt-daily-upgrade`+`e2scrub_all`.
   Four devices, three distinct sets.
   Do not plan around a specific four. `apt-daily-upgrade` **can install packages** — check
   `apt-get -s upgrade` first (it read `0 upgraded` on every device here, and nothing was
   ever installed). On `c3343f47` (28/70 link) the ngrok tunnel dropped seconds after that
   burst — probable cause, **not proven**: no OOM record in journal or `dmesg`.
7. **TWO patches have no `--check` mode**, though `patches/README.md` states every patch
   does with 0/1/2 semantics:
   - `2026-06-30-offline-reboot-and-expired-job`
   - `2026-05-12-watchdog-exit-hang`
   Both support only `--inline`, `--detach`, `apply`, `--rollback`, `--help`; an
   unknown-argument error also exits 1, so a campaign script trusting the convention will
   misread them. (`2026-06-30` does contain the string `--check`, but it is `node --check`
   on line 85 — a JS syntax check, not a CLI flag. Grepping for it gives a false positive.)
   **Substitute a manual dry run:** `2026-05-12` gates on version ∈ AFFECTED_VERSIONS plus
   two code signatures (`setTimeout(() => process.exit(1), 3000).unref()` in the js, and
   `StartLimitIntervalSec` **placement** in the unit), all of which can be evaluated
   read-only before applying.
8. **The v1.1.0 release tag exists** (`3772bd8e`), contradicting
   `2026-08-19-gateway-timezone-utc/README.md` ("There is no `v1.1.0` tag") and its
   affected-versions table, which omits v1.1.0. The tag carries the same `Europe/London`
   default, so v1.1.0 devices *are* affected. Housekeeping noted in `ISSUE-065`.
9. **`96a39148` reads as unpatched to a naive check.** Its js is `b009b68c`, not the reclaim
   patch's `1d49a43a`, because keepalive superseded that js. Verify via the unit sha, the
   `applied` marker and `/run/eatabit` — not the js sha alone. The `BUG-049` fleet survey
   row saying `WOULD APPLY` is a 2026-08-20 snapshot taken one day before it was patched.

16. **BUG-035 is NOT fixed — a credential is minted per `startNgrokTunnel` ATTEMPT, including
    ones the device never answers.** The ngrok account holds **31 credentials**; 30 were
    created 2026-08-23/24 by this campaign, one per device touched (`edec02ad` 5,
    `92f7766c` 5, `db996da7` 5, `42288e07` 4, `3e83bb41` 4, `bd396b5c` 3, `c3343f47` 2,
    `a15e12da` 1, `96a39148` 1). **Decisive evidence:** credentials were minted at
    `17:14:20Z`, `17:15:54Z` and `17:17:28Z` — exactly matching three
    `$NO_RESPONSE_FROM_DEVICE` attempts on `edec02ad`. The Lambda mints the credential
    *before* dispatching the command, so a device that never answers leaves an orphan with
    no `stopNgrokTunnel` to reclaim it. Delete-on-stop only covers the success path.

    **This produced a real failure**, not just clutter: a `startNgrokTunnel` on `edec02ad`
    at `17:28:37Z` returned `500 ERR_NGROK_107` — *"The authtoken you specified is properly
    formed, but it is invalid"* — distinct from the BUG-049 wedge (`Failed to establish
    tunnel`), and it cleared on the next attempt without an `mqtt-client` restart, which
    the wedge would not allow. BUG-035 is currently recorded as **closed**; this says
    otherwise. **Not actioned:** deleting credentials is a production action on shared
    infrastructure, and deleting one in use is a plausible way to *cause* ERR_NGROK_107.

17. **A campaign inflates this fast, and it is still climbing.** 31 → 29 → 33 → **37**
    credentials over this campaign (the dip shows some reclamation does occur, just slower
    than a campaign creates them). ~30 in two days of patching. Any
    multi-device campaign should check `api.ngrok.com/credentials` before and after, and
    budget for reclamation, or it will hit the account cap mid-run.

19. **`StartLimit*` shipped in `[Service]`, where systemd ignores it — while
    `StartLimitAction=reboot-force` sat in `[Unit]`, where it works.** Found on factory-fresh
    `94300990`: `StartLimitIntervalSec=600` and `StartLimitBurst=5` were in `[Service]`
    (lines 22–23) and therefore inert, leaving an **unconstrained** reboot trigger.
    `2026-05-12-watchdog-exit-hang` moves them into `[Unit]`; after applying, systemd reports
    `StartLimitIntervalUSec=10min / Burst=5 / Action=reboot-force`. This is a concrete
    instance of the BUG-044 `reboot-force` hazard that `log2ram`'s README cites for
    destroying logs — an unpatched device can reboot-force without the rate limit ever
    engaging. Verified the fix survives both later `mqtt-client` patches (reclaim replaces
    the unit, keepalive replaces the js) — the `[Unit]` placement persists.

20. **The prerequisite chain, demonstrated end to end on one device in 40 minutes.**
    `94300990` was the only fully factory-fresh device in the campaign (no `patches/`
    directory at all) despite **625 watchdog fires** — 7× the next-worst device — on a
    healthy link (57–62/70) with 13 DNS failures. It is the cleanest proof that the gate
    works as documented:

    | time | js | unit | reclaim `--check` |
    |---|---|---|---|
    | 18:19 | `177e10b8` | `7999b8b6` | **refuse** (exit 1) |
    | 18:29 | `e80b7a17` | `e92b2a15` | *(watchdog applied)* |
    | 18:35 | — | — | **upgrade** (exit 2) |
    | 18:36 | `1d49a43a` | `84aa9272` | exit 0 |

    Both `2026-06-30` and the reclaim patch refused this device earlier the same day; the
    watchdog patch made both applicable. Note the reclaim patch went **directly** from
    `e80b7a17` — `2026-06-30` was never needed, since the rollup accepts that sha itself.

21. **Marker absence does NOT prove a patch was not applied.** On `19dffb8b` the
    `2026-06-30-offline-reboot-and-expired-job` **marker file is missing**, yet the patch is
    plainly applied: its state directory exists with a `mqtt-client.js` backup, and the js
    sits at `2f8848db`. Same on `3e83bb41`, whose two patch directories had backups and no
    markers — an older patch generation that did not write them. **Marker present ⇒
    applied. Marker absent ⇒ inconclusive**; check the state directory, its `backup/`, and
    the sha. Corrects an earlier claim in this log that "the marker is authoritative" — it
    is authoritative only in the positive direction.

    Related trap in my own tooling: `cat "$D/applied" | tr '\n' ' ' || echo ABSENT` never
    prints ABSENT, because the `||` binds to `tr`, which succeeds on empty input. Use
    `[ -f "$D/applied" ]`.

22. **A v1.0.2 device carrying `2f8848db` proves the 2026-06-30 patch was applied**, with no
    device access required. Stock v1.0.2/v1.0.3/v1.0.7 all ship `177e10b8`; the only patch
    installing `2f8848db` as a payload is `2026-06-30`; the watchdog patch ships no js
    payload and its in-place edit yields `e80b7a17` (measured). `2f8848db` is also stock
    v1.0.10/v1.1.4 — so this inference works **only** on devices whose own release predates
    that generation. Confirmed on `19dffb8b` once reachable: both patch directories present.

23. **Three new ISSUE-068 patches landed mid-campaign** (both lines; `hw/1.1` `6cfcc1a`,
    `hw/1.0` `9e2b34d`): `2026-08-23-log-permissions-and-rotation`,
    `2026-08-23-app-permissions-and-shadow-churn`, `2026-08-24-ble-config-permissions`.

    **Sequencing constraint that affects this campaign:**
    `2026-08-24-ble-config-permissions` restarts `ble-config.service`, and so does
    `2026-08-20-ble-classic-scan-off`, **which then scans its own journal to verify**. Run
    concurrently, that scan sees restart noise it did not cause. They share no file — run
    them **back to back**, never together. No device patched in this campaign carried
    `ble-config-permissions`, so no BLE self-check here was contaminated.

    **Reach differs and constrains ordering:** log-permissions restarts nothing and reaches
    every release; ble-config-permissions covers all 15; **app-permissions-and-shadow-churn
    reaches only v1.0.8–v1.0.10 / v1.1.2–v1.1.4**, because the `mqtt-client` lineage entry
    point accepts nothing else — v1.0.1–v1.0.7, v1.1.0 and v1.1.1 can never take it. That
    excludes most devices in this campaign.

    The three bench units already carry these patches, so anything sampling `.80`/`.121`/
    `.126` is skewed.

### Raised on excluded hardware — owned by another worker

18. **~~`/usr/local/lib/eatabit/log` was NOT writable on `cce04a18`~~ — RETRACTED
    2026-08-24. The finding was wrong: the behaviour it describes is ISSUE-068's fix working
    correctly.** Kept rather than deleted, because it was merged to `hw/1.1` and another
    session may have read it.

    *What I claimed:* the log directory was unwritable, probably a systemd sandboxing
    regression (`ProtectSystem` / `ReadWritePaths`) from an uncommitted `2026-08-23-*`
    patch, and serious because `mqtt-client.log` is the only log surviving a power cycle.

    *Three independent errors:*
    - **Tested as the wrong user.** I ran `touch` as `eatabit` against a `root`-owned `0755`
      directory. Failure is the expected result. Every writer runs as root —
      `2026-08-23-log-permissions-and-rotation` states this explicitly, and it is precisely
      why `0755` is safe.
    - **Discarded the error.** `touch … 2>/dev/null` left me unable to distinguish `EACCES`
      (normal) from `EROFS` (alarming). I assumed the alarming one.
    - **Cited evidence predating the change.** The logrotate error I quoted is timestamped
      `00:39:52`; that patch's marker reads `03:29:43` — about three hours later.

    *What was actually happening:* ISSUE-068 had narrowed
    `/usr/local/lib/eatabit/{log,config,reset}` from `0777` to `0755` — the fix for the very
    defect finding 5 reports. Neither `2026-08-23-app-permissions-and-shadow-churn` nor
    `2026-08-24-ble-config-permissions` contains `ProtectSystem` or `ReadWritePaths`;
    verified by grep against `hw/1.1`.

    **Their approach also beats the `su root root` in finding 5:** *"the mode is the cause,
    so 0755 fixes the class and covers every future file in the directory; `su` fixes one
    stanza and leaves the world-writable directory standing."* And
    `2026-08-24-ble-config-permissions` stops `ble-config.js` re-creating them at `0777` —
    exactly the "two chmod sites" objection I raised against a permissions-only fix.
    **Finding 5 should be read as superseded by ISSUE-068's shipped patches.**

### Operational notes

10. **BUG-049 acceptance test** (run after every reclaim application): 3 × stop→start, all
    must return 200, and the ngrok API must show one agent session for N starts. Passed on
    `db996da7`, `a15e12da`, `42288e07`, `92f7766c`, `bd396b5c`. On `edec02ad` 2 of 3
    assertions passed; the third failed `500 ERR_NGROK_107` (a credential fault — see 16),
    not the wedge, and the session half still passed at 1 session for 4 starts.
11. **The "did the sync fire?" predicate — two wrong answers before the right one.**
    - ❌ `stat -c%y /var/hdd.log/log2ram.log` vs a remembered value. That file's mtime is
      written *during* the sync, so arming a watch after it has already run waits for a
      change that already happened. Gave a false **NOT FIRED** on `bd396b5c`.
    - ❌ `systemctl show log2ram-daily.service -p Result`. A unit that has **never run**
      also reports `Result=success`. On `edec02ad` this read `success` a full seven minutes
      *before* the first sync — it would have declared victory early.
    - ✅ **`ExecMainStartTimestamp` non-empty, plus the tmpfs/disk byte gap.** An empty
      timestamp is the unambiguous "never ran" signal; the gap (~100–120 B when synced,
      tens of KB when not) is the independent confirmation. Both were correct on every
      device.

12. **Session reclamation is not instantaneous — re-check before calling a leak.** On
    `92f7766c` the ngrok API showed **3** sessions immediately after 4 starts + 3 stops,
    which looks like the BUG-049 leak. Thirty seconds later it was **1**, stable across
    three checks. Sample the session count ~30 s after the final stop, not immediately.

13. **BUG-039 verified free of charge five times** — on any later restart, check that
    `/run/eatabit/device-ready-printed` has an mtime *older* than
    `ExecMainStartTimestamp`. No test print required.
14. **`mqtt-client.service: Failed with result 'timeout'`** appears in the journal on every
    restart across all devices. Benign: the old process exceeds its stop timeout while the
    new one starts clean.
15. **Re-check idle immediately before a restart, not at recon time.** On `db996da7` a real
    customer job printed 2 m 19 s before the restart while the idle reading in hand was
    38 minutes stale. Nothing was dropped, by luck.

24. **`2026-08-24-mqtt-never-connected-watchdog` is BENCH ONLY and was correctly declined
    on `96a39148`** (2026-08-25). Its README opens with an explicit prohibition — *"DO NOT
    INSTALL ON ANY FIELD DEVICE… Field rollout is a separate, later, explicitly authorized
    decision"* — and names `c3343f47`, the device the bug was diagnosed from, as **not** a
    target. `96a39148` is field-reachable only via ngrok, so it is a field device. The gate
    would have passed (`7ecbf0ea…` matches the sole accepted prior); the **policy** is what
    refused. Recorded because a future operator reading only the sha gate will find this
    device eligible and may mistake that for authorization.

25. **Three documentation defects in `2026-08-23-app-permissions-and-shadow-churn`**, found
    while applying it to `96a39148` (2026-08-25). The `apply.sh` is correct in all three
    cases; only the prose is wrong.
    - **The version-exclusion claim is false, and `96a39148` disproves it.** The README and
      `apply.sh`'s refusal text (~line 252) both state a device on *"v1.0.1–v1.0.7, v1.1.0
      or v1.1.1 CANNOT enter the lineage and so cannot take this patch at all."* `96a39148`
      is **v1.1.1** and took it cleanly. The rule governs *stock* shas, not version strings:
      a v1.1.1 that has already run `watchdog-exit-hang` and `2026-06-30` carries an
      accepted prior sha and enters normally. As written, the message will cause an operator
      to abandon a patchable device. (Consistent with finding 8 and the `KNOWN_VERSIONS`
      note in the BUG-057 patch: v1.1.0 is a real tag, `3772bd8`.)
    - **The Payloads table and Gates section still describe `ble-config.js`** — five
      variants with prior/fixed shas — but no `ble-config.js` ships in that directory and
      `apply.sh` is `mqtt-client.js`-only. Stale text left by the deliberate split into
      `2026-08-24-ble-config-permissions`.
    - **The patch depends on `RuntimeDirectory=eatabit` but does not gate on it.** The
      snapshots move to `/run/eatabit`; if that directory is absent the persist path has
      nowhere to write. In practice the js sha implies the unit (reaching `b009b68c…`
      requires `ngrok-session-reclaim`, which installs unit `84aa9272…`), so this is latent
      rather than live — but it is an unchecked assumption, not a checked one. Verified
      manually on `96a39148` before applying.

26. **ISSUE-068 is not fully closed in the field even after all three patches.**
    `cutter-type.json`, `light.json` and `volume.json` remain **`0666`** on `96a39148` after
    all three applied. The image source now installs them `0644`
    (`stage3/03-install-mqtt-client/00-run.sh`), but **no field patch narrows them** — the
    companion patch fixed directories, the app patch fixed the code that creates them. So a
    patched device and a reflashed device do **not** converge on these three files, which
    contradicts the convergence property the payload tables otherwise guarantee. Low
    severity (root-owned; logrotate does not read them), but it means "ISSUE-068 closed on a
    device" currently means *directories and creation modes*, not *all file modes*.
