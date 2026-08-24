# `2026-08-24-mqtt-never-connected-watchdog` — BUG-057

> # ⛔ DO NOT INSTALL ON ANY FIELD DEVICE. BENCH ONLY.
>
> This patch is authorized for the three bench devices and **nothing else**.
> **`00000000c3343f47` is NOT a target** — despite being the device this bug was
> diagnosed from, and despite being tunnel-reachable since
> [`2026-08-20-ngrok-session-reclaim`](../2026-08-20-ngrok-session-reclaim/) landed.
> Field rollout is a **separate, later, explicitly authorized decision**. Nothing in
> this README constitutes that authorization.

> | | |
> |---|---|
> | **Lineage** | `mqtt-client` — touches `mqtt-client.js` only (**not** the unit) |
> | **Position** | 6 of 6 — current head of this lineage |
> | **Prerequisite** | [`2026-08-23-app-permissions-and-shadow-churn`](../2026-08-23-app-permissions-and-shadow-churn/) (ISSUE-068). **Exactly one accepted prior sha**; anything else is refused |
> | **Independent of** | [`2026-08-23-log-permissions-and-rotation`](../2026-08-23-log-permissions-and-rotation/) and [`2026-08-24-ble-config-permissions`](../2026-08-24-ble-config-permissions/) — no shared file |
> | **Restarts** | `mqtt-client.service` — **drops the ngrok SSH tunnel and any in-flight print job** |

Lineages and why they exist: [`../README.md`](../README.md) → *Lineages*.

## The bug

After the application connection watchdog restarts `mqtt-client`, the fresh process
must resolve the IoT endpoint again. When that lookup fails, the process retries
**every 30 s forever**, because two defects compound:

1. **`ClientBootstrap` is built once per process and never rebuilt.** It owns the CRT
   host resolver. The retry loop deliberately rebuilds the *connection* every attempt
   — but reuses that one bootstrap, so once its resolver holds a failed entry for the
   endpoint, every subsequent `connect()` inherits it. The previous fix stopped one
   layer short.
2. **The Layer 1 watchdog cannot fire in a process that has never connected.** Its
   guard was `if (!isConnected && lastDisconnectedAt)`, and `lastDisconnectedAt` is
   assigned **only** by the `interrupt` and `disconnect` handlers — which a
   never-connected process never runs. Meanwhile `SdNotify.watchdog()` is fed
   unconditionally, so systemd sees a healthy process. The device is a well-fed
   zombie: alive, reporting fine, permanently offline.

Measured on `00000000c3343f47` (v1.1.4): **13,840** consecutive
`AWS_IO_DNS_QUERY_FAILED` retries, longest single run **4,919 failures over 41 hours**,
**115.3 h offline across 7 outages — 28% of a 417 h window**. Every recovery was a
power cycle. During the 41 h stall the site was open and the network was up; a reboot
then connected in **1.4 s**.

A second device, `0000000042288e07`, shows the same signature independently:
**5,131 DNS failures against 91 watchdog fires** (~56:1) — a ratio a self-recovering
device does not accumulate. See [`../ROLLOUT-LOG.md`](../ROLLOUT-LOG.md).

## What it changes

**Change A — arm the watchdog for the never-connected case, bounded at `N = 3`.**
A separate `neverConnectedSince` clock is set at startup and cleared on connect; the
guard falls back to it. `lastDisconnectedAt` is **deliberately not seeded** — health
telemetry reports it, and seeding would report a disconnect that never happened.

The exit is **bounded at 3 restarts**, counted in
`/run/eatabit/never-connected-restarts` (tmpfs, `RuntimeDirectoryPreserve=restart`, so
it survives the restarts it counts and is cleared by a power cycle). After 3, the
process stops exiting, keeps retrying every 30 s and keeps feeding the systemd
watchdog. **This bound is not optional** — v1.0.10 removed the
exit-on-failed-initial-connect precisely because an unprovisioned or genuinely offline
device would restart forever (`docs/bugfix/offline-reboot-loop.md`); unbounded, it
would restart such a unit ~450×/day.

**Change B — rebuild the bootstrap, client and config on every attempt**, so a
poisoned resolver cannot survive a retry.

**Recovery is the restart, not a reboot.** The watchdog samples every 60 s and fires
past 150 s, so the exit is quantized to **180 s**; with the 3 s exit timer and
`RestartSec=10` a cycle is **~193 s**. Five starts need four gaps — 4 × 193 = **772 s**
against `StartLimitIntervalSec=600` — so `StartLimitBurst=5` is unreachable and
`StartLimitAction=reboot-force` never fires on this path. `N = 3` makes that structural
rather than incidental. **Anyone lowering `MAX_DISCONNECT_DURATION_MS` to ≤ 120 s must
redo that arithmetic.**

**Honest limit:** exhausting the budget does **not** strand the device — the 30 s retry
loop keeps running and reconnects when the fault clears (bench-verified: after `3/3` the
unit stayed `active` and reconnected 4 min later when DNS returned). What is given up is
further *restarts*, so the residual risk is narrow: a fault a **fresh** process would
clear but a running one will not. Telling that apart from "no network" needs a
link/reachability probe — `ISSUE-004`.

## Gates

```
FIXED_SHA           cade85490c64b651f5b505263dba744428fbdf17b9d47f333eaf431208b19d03
ACCEPTED_PRIOR_SHAS 7ecbf0ead594437934e3d0e501689a3bf99a1df77acdefb4369b57fc5655a34a
```

**Exactly one accepted prior**, and **do not widen it**. Precedent and reasoning:
BUG-045's patch carries a single accepted prior for the same reason. Bringing a device
*up* the lineage is the operator's own step, run in order; this patch is the last link
in a known chain, not a reconstructor of arbitrary device states.

Widening would also make this a **rollup**: the payload is built on top of ISSUE-068's
file, so applying it to a pre-ISSUE-068 device (`b009b68c…`) would silently deliver
ISSUE-068's changes as well. **Refusal is the correct outcome**, and the refusal prints
the observed sha.

`KNOWN_VERSIONS` includes **1.1.0**, which is a real released tag (`3772bd8`, commit
`5146b0c`) — earlier patch READMEs that treat it as a phantom are wrong. It is
informational only; the checksum is the gate.

## Usage

```bash
sudo ./apply.sh --check      # 0 = already patched   1 = would refuse   2 = would apply
sudo ./apply.sh              # apply
sudo ./apply.sh --rollback   # restore mqtt-client.js from backup
```

`--check` needs no root and changes nothing.

**Over SSH the restart-and-verify step re-execs detached** — ngrok runs inside
`mqtt-client`, so a foreground restart would kill the session doing the restarting.
`sudo ./apply.sh` returns almost immediately; reconnect and read
`/usr/local/lib/eatabit/patches/2026-08-24-mqtt-never-connected-watchdog/apply.log`.

Built from [`../_template/`](../_template/), not by copying a neighbouring patch
(BUG-047 was that defect four times over). `in_list()` is defined in the
patch-specific section because the template does not provide it.
