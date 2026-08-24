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

`96a39148` was **verified only, not patched** in this campaign — it already carries all
seven patches (reclaim `2026-08-21T19:35:07+01:00`, keepalive `2026-08-23T17:31:37+00:00`).

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

On `42288e07` a within-run A/B (`measure.sh -a asis,classic`) put two arms of the **same**
radio state at mdev 6.519 and 4.470 — a **1.46× run-to-run spread**, larger than the 1.32×
"worsening" the naive before/after showed. So that before/after was noise, not a
regression. Its readings sit between the ISSUE-064 references (BT ON 22.363 ms, BT OFF
2.668 ms) and nearer the OFF end, i.e. this site was never paying the severe BR/EDR
penalty `db996da7` was.

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
2. **Confirm the first log2ram sync on `c3343f47` and `42288e07`.** Tunnel was closed before 13:00Z.
   `stat -c%y /var/hdd.log/log2ram.log` should read 2026-08-24 13:00+, not 2026-08-05.
3. **Patches still missing per device:**
   - `3e83bb41` — keepalive, log2ram, ble-classic-scan-off (only timezone applied)
   - `cce04a18` (bench) — gateway-timezone-utc; still `Europe/London`, so its hourly
     log2ram schedule skips one slot at the spring DST transition

### Findings raised, not yet actioned

4. **`BUG-057` has a second device.** Recorded as a single-device finding on `c3343f47`
   (13,840 DNS failures, 12 watchdog fires). `42288e07` shows **5,131 DNS failures and 91
   watchdog fires** — same signature, and it needed a reboot on 2026-08-24 to clear a
   wedged tunnel. Until BUG-057 ships, any `mqtt-client` restart on either device is safe
   only while DNS resolves; use a pre-restart DNS guard (5 resolves, abort on any failure).
5. **`ISSUE-068` reproduced on every device seen** — `logrotate` fails with
   `result=exit-code` because `/usr/local/lib/eatabit/log` is mode `0777`. Image source
   sets it twice (`stage3/01-create-eatabit-lib/00-run.sh:21` uses `chmod 0777`,
   `stage3/05-install-log2ram/00-run.sh:80` uses `chmod 777`), so a permissions-only fix is
   silently undone — `su root root` in the logrotate stanza is the safer single-point change.
6. **The timezone patch fires `Persistent=true` timers at the switchover.** It restarts no
   service, but systemd runs every persistent timer whose window it now considers elapsed.
   **The set is not fixed — it varies per device** by which windows have lapsed:
   `db996da7`/`a15e12da`/`3e83bb41` fired `logrotate`+`dpkg-db-backup`+`e2scrub_all`+
   `apt-daily-upgrade`; `c3343f47` added `apt-daily` (five); `42288e07` fired
   `dpkg-db-backup`+`apt-daily-upgrade`+`e2scrub_all`+**`fstrim`** and **not `logrotate`**.
   Do not plan around a specific four. `apt-daily-upgrade` **can install packages** — check
   `apt-get -s upgrade` first (it read `0 upgraded` on every device here, and nothing was
   ever installed). On `c3343f47` (28/70 link) the ngrok tunnel dropped seconds after that
   burst — probable cause, **not proven**: no OOM record in journal or `dmesg`.
7. **`2026-06-30-offline-reboot-and-expired-job` has no `--check` mode.** It supports only
   `--inline`, `--detach`, `apply`, `--rollback`, `--help`. `patches/README.md` states every
   patch has `./apply.sh --check` with 0/1/2 semantics; a campaign script trusting that will
   misread its exit code (an unknown-argument error also exits 1).
8. **The v1.1.0 release tag exists** (`3772bd8e`), contradicting
   `2026-08-19-gateway-timezone-utc/README.md` ("There is no `v1.1.0` tag") and its
   affected-versions table, which omits v1.1.0. The tag carries the same `Europe/London`
   default, so v1.1.0 devices *are* affected. Housekeeping noted in `ISSUE-065`.
9. **`96a39148` reads as unpatched to a naive check.** Its js is `b009b68c`, not the reclaim
   patch's `1d49a43a`, because keepalive superseded that js. Verify via the unit sha, the
   `applied` marker and `/run/eatabit` — not the js sha alone. The `BUG-049` fleet survey
   row saying `WOULD APPLY` is a 2026-08-20 snapshot taken one day before it was patched.

### Raised on excluded hardware — owned by another worker

14. **`/usr/local/lib/eatabit/log` was NOT writable on bench unit `cce04a18`** (observed
    2026-08-24, read-only audit). `logrotate` fails with
    `error creating output file …/mqtt-client.log.1.gz: Read-only file system`, while `/` is
    mounted `rw,noatime`, `/tmp` is writable, `dmesg` shows no ext4/mmc I/O errors and the
    path is not a separate mount — so **not** SD-card failure or a read-only root. Most
    likely a systemd sandboxing property (`ProtectSystem` / `ReadWritePaths`) introduced by
    one of the two uncommitted `2026-08-23-*` patches on that unit. Matters because
    `mqtt-client.log` is the only log that survives a power cycle (`/var/log` is tmpfs), so
    this would be a serious regression if it reached the fleet. **Not investigated further
    and not actioned** — that device's state belongs to another worker. Their patch also
    *did* fix the ISSUE-068 `0777` problem (dir now `drwxr-xr-x`, stanza `create 0644 root
    root`, rotation produced `mqtt-client.log.1`), so the two findings are related.

### Operational notes

10. **BUG-049 acceptance test** (run after every reclaim application): 3 × stop→start, all
    must return 200, and the ngrok API must show one agent session for N starts. Passed on
    `db996da7`, `a15e12da`, `42288e07`.
11. **BUG-039 verified free of charge four times** — on any later restart, check that
    `/run/eatabit/device-ready-printed` has an mtime *older* than
    `ExecMainStartTimestamp`. No test print required.
12. **`mqtt-client.service: Failed with result 'timeout'`** appears in the journal on every
    restart across all devices. Benign: the old process exceeds its stop timeout while the
    new one starts clean.
13. **Re-check idle immediately before a restart, not at recon time.** On `db996da7` a real
    customer job printed 2 m 19 s before the restart while the idle reading in hand was
    38 minutes stale. Nothing was dropped, by luck.
