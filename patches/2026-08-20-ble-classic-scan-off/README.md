# 2026-08-20-ble-classic-scan-off — BUG-040

> ## ⚠️ VALIDATED ON THE BENCH. NOT YET CLEARED TO SHIP.
>
> Applied and verified on three units — v1.1.4, v1.0.10 and v1.1.0, covering **both**
> hardware lines. The mechanism works: `PSCAN`/`ISCAN` are gone, BlueZ parses the config
> with zero warnings, the device is still LE-discoverable by name from another device,
> the patch no-ops on re-run, and `--rollback` restores byte-exact stock state.
>
> **Two things still gate shipping:**
>
> 1. **A2 is not yet observed.** Nobody has taken the AP away and watched a patched
>    device stay discoverable and re-provision. That is the criterion that costs a truck
>    roll if it is wrong, and no amount of the above substitutes for it.
> 2. **Pairing has not been exercised from the mobile app.** LE discovery is confirmed
>    device-to-device, but no phone has completed SSID -> Password -> Apply -> Status,
>    and nothing has driven the chunked Scan characteristic or factory reset.
>
> **And one open decision:** the patch recovers ~69% of the available jitter improvement.
> The remaining ~31% is LE advertising, which this patch deliberately does not touch.
> See *Measured results* — whether that residual is worth pursuing is a judgement call,
> not a follow-up commit.

Stops the device performing BR/EDR ("classic") **page scan** and **inquiry scan**, which
it did permanently, on a radio front-end it shares with WiFi, while never using classic
Bluetooth for anything.

## What it does NOT do — read this first

It does **not** gate, stop, mask, delay or otherwise touch the BLE provisioning path. LE
advertising and the GATT server run exactly as before: permanently, on a provisioned
device and an unprovisioned one alike.

This matters more than anything else in this document. **BLE is the last-resort way into
a Pi Zero 2 W.** There is no Ethernet. SSH rides the WiFi. The only other recovery is
`/boot/firmware/network-config` — physically pulling the SD card out of a machine in a
customer's building. A patch that made BLE conditional (on NetworkManager state, on a
dispatcher hook, on a timer) would introduce a way for a device to become unreachable
that does not exist today, and the failure would be **latent**: invisible until the
customer changes their router weeks later, at which point there is no way in and — per
`BUG-041`, the journal being volatile — no evidence either.

**This patch introduces no such way. The device is never less discoverable after it than
before it.** That property is why this shape was chosen over the three that BUG-040's
`planning.md` proposed, all of which gated the provisioning path.

## The bug

`ble-config.service` runs permanently with `hci0 UP RUNNING PSCAN ISCAN` — continuously
page- and inquiry-scanning — on a device provisioned a month earlier. On the CYW43438 the
WiFi and Bluetooth sides share **one 2.4 GHz front-end and one antenna**, arbitrated by
time-division coexistence, so that scanning **steals airtime from WiFi**.

A controlled on-device experiment (`ISSUE-064` finding 10, run 2026-08-19, WiFi
configuration untouched between arms, association never dropped) measured on the first
wireless hop to the gateway:

| Metric | BT ON | BT OFF | Improvement |
|---|---:|---:|---:|
| average RTT | 16.910 ms | **3.223 ms** | **5.2×** |
| worst case | 102.122 ms | **15.019 ms** | **6.8×** |
| jitter (`mdev`) | 22.363 ms | **2.668 ms** | **8.4×** |

Jitter is the metric that matters. The MQTT client runs `with_keep_alive_seconds(30)`
with a ~3 s ping-response window, and every observed disconnect was
`AWS_ERROR_MQTT_TIMEOUT`. One airtime stall past that window tears down an otherwise
healthy connection. With BT off the worst case is 15 ms — comfortably inside it.

## Why classic scanning costs so much, and why it buys nothing

**Where the radio-on time goes**, from the kernel's own constants
(`hci_write_fast_connectable_sync`, `hci_alloc_dev_priv`) and bleno's defaults:

| Source | Parameters | Duty cycle |
|---|---|---:|
| Page scan, `FastConnectable = true` | INTERLACED, 160 ms interval (`0x0100`) / 11.25 ms window (`0x0012`) | ~7% → **~14%** interlaced |
| Page scan, kernel default | STANDARD, 1.28 s (`0x0800`) / 11.25 ms | ~0.9% |
| Inquiry scan while discoverable | 1.28 s / 11.25 ms | ~0.9% |
| LE advertising | bleno default 100 ms, 3 channels | ~1.1% |

So classic scanning is roughly **an order of magnitude** more radio-on time than the LE
advertising provisioning actually needs.

**And the product never uses classic Bluetooth.** `ble-config.js` advertises through
`@abandonware/bleno` — `bleno.startAdvertising(DEVICE_NAME, [WIFI_SERVICE_UUID])`, LE
advertising and LE GATT, and bleno issues no BR/EDR commands at all. The mobile app finds
the device with `react-native-ble-plx`'s `startDeviceScan` (`iot-expo/hooks/useBLE.ts`),
which is LE-only and filters on the LE advertisement's local name. Nothing in the pairing
flow issues a classic inquiry.

Classic page and inquiry scan are therefore **pure cost**. Turning them off cannot break
provisioning, because provisioning never used them.

> **Expected, not proven:** this should recover *most* — not all — of the measured delta,
> leaving roughly the LE advertising term. Quantifying the residual is what `measure.sh`
> is for. If it turns out LE advertising is a large share, this patch is still a strict
> improvement but is **not sufficient**, and the next step (gating LE) has a completely
> different risk profile because LE advertising *is* the way back into a device that has
> lost WiFi. **That is a decision for a human. Stop and raise it.**

## The two files

| File | Change |
|---|---|
| `/etc/bluetooth/main.conf` | The eatabit block gains `ControllerMode = le` (removes BR/EDR entirely: no PSCAN, no ISCAN) and flips `FastConnectable` from `true` to `false`. |
| `/etc/systemd/system/bluetooth-poweron.service` | Drops the `bluetoothctl discoverable on` `ExecStart`, which is what turned inquiry scan on at every boot. |

Installing only the first leaves a unit that re-asserts discoverability at each boot.
Installing only the second leaves the interlaced page scan running. **Both, or neither.**

`ble-config.js` and `ble-config.service` are **not modified**. Neither is
`mqtt-client.js` or `mqtt-client.service`.

### A correction to BUG-040's planning.md

`planning.md` states that `main.conf`'s `Discoverable = true` / `DiscoverableTimeout = 0`
are "where permanent `ISCAN` comes from". **`Discoverable` is not a BlueZ option.** It
does not appear in bluez 5.79 `src/main.conf`, and trixie ships 5.79+. Neither do
`InitiallyPowered`, `Pairable` (the real key is `AlwaysPairable`) or `[LE] Autoconnect`
(the real key is `Autoconnecttimeout`). **Four of the twelve keys in the shipped block
have never done anything.**

Permanent `ISCAN` comes from `bluetoothctl discoverable on` in the power-on unit;
`DiscoverableTimeout = 0` only stops it expiring. The four inert keys are dropped here so
the file stops implying a mechanism it does not have.

## Affected versions

`stage3/08-ble-config/00-run.sh` is **byte-identical across all fifteen released tags**
(sha `463f9099…`), so there is exactly **one** prior block sha and **one** prior unit sha
to accept — not a matrix.

| Versions | `00-run.sh` | main.conf block | poweron unit | Affected |
|---|---|---|---|---|
| v1.0.1 – v1.0.10 | `463f9099…` | `a3209a4c…` | `183052ae…` | **yes** |
| v1.1.0 – v1.1.4 | `463f9099…` | `a3209a4c…` | `183052ae…` | **yes** |

> **`v1.1.0` exists.** BUG-040's `bug.md` asserted there is no `v1.1.0` tag; that is
> backwards. `v1.1.0` is an annotated tag dated 2026-03-31 at `5146b0c`, present on
> `origin` and locally, and a factory-fresh v1.1.0 unit was LAN-validated during
> `BUG-049`. The `2026-05-12-watchdog-exit-hang` README that cites "v1.1.0–v1.1.1" is
> correct. `bug.md` has been corrected.
>
> The tags actually **missing from `origin`** are **`v1.0.3`, `v1.0.9` and `v1.1.3`** —
> they exist only in local checkouts and were never pushed. The eatabit tag count is
> **15**, not 14.
>
> **Local-only tags are included in the sha sweep** on purpose: a device *could* have
> been flashed from a local build, and in any case all three carry the same
> `00-run.sh`, so including them costs nothing and excluding them risks a gap.

`ble-config.js` has five distinct generations across the fifteen tags. This patch does
not modify it, so it is **not gated** — gating on a file you do not touch only refuses
devices you could have helped. Its sha is **reported** so a run identifies the device's
generation:

| sha256 | Versions |
|---|---|
| `eac92d78…` | v1.0.1, v1.0.2 |
| `4654037f…` | v1.0.3 |
| `d70edf02…` | v1.0.4, v1.0.5, v1.0.6, **v1.1.0** |
| `ecbf9a06…` | v1.0.7, v1.0.8, v1.1.1, v1.1.2 |
| `2cda3a88…` | v1.0.9, v1.0.10, v1.1.3, v1.1.4 |

> `bug.md`'s table mapped `d70edf02…` to "v1.0.4–v1.0.6". It is also **v1.1.0** — a
> consequence of the same missing-tag error. Corrected there too.

## Usage

```bash
scp -r 2026-08-20-ble-classic-scan-off pi@<device>:~/
ssh pi@<device>
cd 2026-08-20-ble-classic-scan-off

./apply.sh --check          # DRY RUN. No root. Changes nothing.
sudo ./apply.sh             # apply
sudo ./apply.sh --rollback  # restore from backup

./apply.sh --selftest       # exercise the main.conf rewrite against fixtures;
                            # no device, no root, changes nothing outside /tmp
sudo ./measure.sh           # the radio measurement (see below)
```

`--check` exit codes: `0` already patched · `1` would refuse · `2` would apply. Use it to
survey a fleet — **a device's version string does not determine the outcome, its file
checksums do**, and a device can carry a version whose files an earlier patch altered.

### The ngrok tunnel is not at risk

This patch does not modify or restart `mqtt-client.service`, and ngrok runs inside that
process. `ISSUE-064` separately measured that restarting `ble-config` + `bluetooth` does
**not** drop the tunnel. The restart+verify still runs **detached** over SSH anyway: it
costs nothing and removes a failure mode where a dropped session kills the verify
half-way and leaves the auto-rollback unrun.

## Gating

Checksums, never version strings; each surface gated independently so a half-applied
device is completed rather than refused. An unrecognised file is never overwritten, and
the refusal **prints the observed sha256** so an unsampled device reports its own state.

**`main.conf` is gated on the sha of the eatabit block, not the whole file.** The whole
file is stock-BlueZ-for-that-image *plus* our block, so its sha varies with the base image
and is not a usable gate.

### The `cat >>` trap

`00-run.sh` shipped the block with `cat >> /etc/bluetooth/main.conf` — an **append**, with
no end marker, producing a file with two `[General]` sections where the second is ours. Two
consequences:

1. A naive re-apply leaves a **third** `[General]` section and a config nobody can reason
   about. `apply.sh` rewrites the block **in place** and never appends. `--selftest` runs
   the rewrite three times and asserts the section count does not move.
2. The block must be **last** in the file, because BlueZ uses GKeyFile semantics where the
   last assignment of a key wins. Content *before* our block is harmless — we win.
   Content *after* it would override us, silently, and could put `FastConnectable` or
   `ControllerMode` straight back while the patch looked applied. **`apply.sh` refuses if
   anything non-blank follows the end marker**, printing what it found.

Both the legacy (unmarked, runs to EOF) and the new marked form are recognised, so a
device patched twice, or patched and then reflashed, converges on the same file.

## The recovery self-check

**`apply.sh` will not exit SUCCESS without proving the device still advertises, and rolls
itself back if it cannot.** This is deliberately not delegated to the operator: the
rollout stages catch a *bad patch*, but only the device can catch a *device-specific*
failure — a BlueZ that behaves differently on that image, an adapter that will not come
back LE-only, a bleno that fails to re-advertise.

After bouncing `bluetooth`, `bluetooth-poweron` and `ble-config` (never `mqtt-client`), it
asserts:

- `ble-config.service` and `bluetooth.service` are active;
- `hci0` is `UP RUNNING`;
- **`hci0` no longer shows `PSCAN` or `ISCAN`** — this is also the on-hardware test of
  BlueZ's last-key-wins parse. If our block lost to an earlier key, the flags are still
  there, the check fails, and the patch rolls back rather than shipping a change that
  looks applied and does nothing on the radio;
- `ble-config` logged **LE advertising restarted** *and* **GATT service re-registered**
  since the bounce — not at some point in the past.

Any failure restores both files, bounces Bluetooth back, and records
`result=failed-rolledback`.

**What it cannot prove:** that a phone completes a pairing. Nothing running on the device
can prove that. That needs the app, and it is listed below.

## Measured results

Bench: three v20 printers on one LAN, inches apart. `measure.sh` alone was **not
sufficient** here — it changes the radio on one device, and with two identical units
beside it still page-scanning at ~14% duty, the "Bluetooth off" arm is not a
Bluetooth-off environment. Two runs failed that way, one producing the physically
impossible result that all-Bluetooth-off was *worse* than as-is. The valid method
switches every unit together and pings from all of them at once.

| Arm | avg (ms) | max (ms) | **mdev (ms)** | n |
|---|---:|---:|---:|---:|
| `asis` — as shipped | 9.172 | 50.623 | **11.900** | 9 |
| `classic` off, LE on — **what this patch does** | 4.248 | 35.141 | **6.475** | 9 |
| `fastconn` off only | 5.368 | 44.330 | **8.797** | 9 |
| `alloff` — floor | 3.234 | 23.794 | **4.010** | 9 |

Ordering is monotone and physically coherent: `alloff < classic < fastconn < asis`.

- **Jitter 1.84x better**, average **2.16x better**.
- The patch recovers **~69%** of the total available improvement.
- **~31% residual** — roughly 2.5 ms of mdev — is LE advertising, untouched by design.

**These are directional figures, not precise ones.** Per-arm spread is wide and
individual hosts show local inversions; the bench is a hostile RF environment (an LE
scan found a Marshall Stanmore II, two CloudPrints, two BT_Printers and a dozen
anonymous advertisers alongside our units). The as-is -> patch gap is the largest and
most consistent effect and survives the ordering bias, since `asis` always ran in the
most favourable slot of each round.

Absolute values are **not** comparable to ISSUE-064 finding 10 (a lone device on a
different network). Use that record for the shape of the gap, not as a target.

### The `FastConnectable` question, answered

`fastconn` (8.797) sits between `asis` (11.900) and `classic` (6.475), so reverting it
helps materially on its own but is **not** a substitute for dropping classic scan. Both
ship. It remains worth having independently because it is the only lever that helps an
**unprovisioned** device, which is still advertising and scanning by design.

## Verified on hardware

| # | Check | Result |
|---|---|---|
| 1 | Bug reproduces: `UP RUNNING PSCAN ISCAN` | ✅ all three units |
| 2 | Gate recognises every generation — v1.0.10, v1.1.0, v1.1.4 | ✅ identical shas on all three |
| 3 | `--check` refuses safely on an unrecognised file, changing nothing | ✅ caught the two-block field state before any write |
| 4 | Apply on **hw/1.1** (v1.1.4) and **hw/1.0** (v1.0.10) | ✅ both, self-check passed |
| 5 | **A1** — patched device is not inquiry/page scanning | ✅ `UP RUNNING`, `br/edr` absent from `btmgmt` current settings |
| 6 | `main.conf` consolidates 3 `[General]` → 2, one managed block, zero legacy markers | ✅ |
| 7 | BlueZ parses the new block with **zero** unknown-key warnings | ✅ (12 warnings before the patch, 0 after) |
| 8 | **A8** — re-run is a clean no-op, no third `[General]` | ✅ |
| 9 | `--rollback` restores **byte-exact** stock `main.conf` and unit | ✅ shas match the pre-patch originals exactly |
| 10 | **Patched device still LE-discoverable by name from another device** | ✅ `Eatabit-4a18` and `Eatabit-5d90` seen in an LE scan from the control unit |
| 11 | `systemd-analyze verify` on the bundled unit | ✅ |

## Still required before shipping

| # | Required | Status |
|---|---|---|
| 1 | **A2 — AP removed; device still discoverable and re-provisionable, timed** | ❌ **not done — the blocking item** |
| 2 | iot-expo pairing end to end: SSID, Password, Status notify, Apply, chunked Scan | ❌ needs the mobile app |
| 3 | Factory reset over BLE; device returns discoverable | ❌ needs the mobile app |
| 4 | Fresh-flash / post-reset device discoverable immediately at boot | ❌ needs a reflash |
| 5 | ≥72 h MQTT flap rate from the cloud `Event` table vs pre-fix baseline (**not** the device journal — volatile, `BUG-041`) | ❌ needs elapsed time |
| 6 | Decide whether the ~31% LE residual is worth pursuing | ❌ open question for a human |

## A separate bug found while testing

**`ble-config.service` never exits on SIGTERM.** systemd waits the full
`TimeoutStopUSec=1min 30s` and then SIGKILLs it — observed exactly, 03:34:56 → 03:36:26.
The handler is:

```js
process.on("SIGTERM", async () => {
  bleno.stopAdvertising(() => { process.exit(0); });   // callback never fires
});
```

`bleno.stopAdvertising()`'s callback does not fire, so `process.exit(0)` is never
reached. This is **pre-existing and unrelated to BUG-040** — it predates this patch and
is why every `systemctl restart ble-config` takes 90 seconds, and why device shutdowns
and reboots stall for the same 90 seconds. It does not affect this patch's correctness
(the self-check passed and advertising returned), only its speed. It wants its own
record; do not fix it here.

## Rollout — staged, and no stage proceeds on reasoning alone

1. **One device** — a lab unit you can physically reach.
2. **A few.**
3. **The fleet.**

**At every stage: take the AP away and watch the device become discoverable and
re-provision from the mobile app, before widening.** "It worked at the last stage and
nothing changed" is reasoning, not an observation. The whole hazard here is that the
failure is invisible until the moment you need the recovery path — so the recovery path is
the thing that gets exercised, every time.

## Related

- `BUG-040` — this record. `ISSUE-064` finding 10 — the measurement (that record is
  `done`; cite it, do not reopen it).
- `BUG-045` — MQTT keep-alive tolerance. Independent; if flapping persists with `hci0`
  provably quiet, weight moves there.
- `BUG-041` — the device journal is volatile, which is why flap rate is measured from the
  cloud `Event` table.
- `ISSUE-065` — v1.0.11 / v1.1.5. **BUG-040 is gated by that release but is *not* in the
  `FIXED_SHA` reconciliation set** (`BUG-039`/`044`/`045`/`049`), which is about
  `mqtt-client.js` and `mqtt-client.service`. This patch shares no file and no checksum
  with those, so it can be developed, applied and rolled back independently.
