# 2026-09-23 — Wi-Fi power-save off (BUG-093)

> **v1.0.11 / v1.1.5 DO NOT carry this fix.** It postdates both releases. A freshly
> flashed v1.0.11 or v1.1.5 device reports *would apply*; only images built after this
> patch merged carry the conf file and report *already fixed*.

> | | |
> |---|---|
> | **Lineage** | `wifi-powersave` — adds `/etc/NetworkManager/conf.d/eatabit-wifi-powersave.conf`. **New, independent lineage**: no existing patch targets that file |
> | **Position** | 1 of 1 |
> | **Prerequisite** | **none** |
> | **Independent of** | **every other patch here.** Shares no target file, and therefore no checksum, with any other lineage. Apply in any order relative to them, or on its own |
> | **Restarts** | **nothing, and drops no connection.** NetworkManager is not restarted or reloaded, no connection is brought down or up, and Wi-Fi is not reassociated |
>
> Lineages and why they exist: [`../README.md`](../README.md) → *Lineages*.

**Severity: hardening (P2).** No image sets Wi-Fi power-save, so every gateway runs with
the `brcmfmac` driver default: **on**.

## Honest scope — read this before quoting the patch as a fix

- Power-save is **not proven** to have caused any specific outage. It is a known source
  of added latency and dropped associations on the Pi Zero 2 W's `brcmfmac` chip, and the
  gateway that prompted `BUG-093` (`00000000a15e12da`, v1.1.4) drops 12–27 times a day
  **[relayed in `BUG-093`, not verified by this patch]**.
- **Those drops fit a roaming pattern better than power-save:** they split 26 / 27 across
  two access points sharing one SSID **[relayed]**. This patch does nothing about roaming.
- So this patch **removes a suspect**. Its efficacy is measured, not assumed:
  `measure.sh` takes the same measurements before and after (see *Measuring efficacy*),
  and a null result is a valid outcome — the image should set power-save deliberately
  rather than inherit a driver default either way.

## What is wrong

Every NetworkManager Wi-Fi profile on the image says `802-11-wireless.powersave = 0
(default)` — it asks for nothing — and nothing in `/etc/NetworkManager/conf.d/` sets a
default. So the driver's own default stands, and `iw dev wlan0 get power_save` reads
`on`. Measured on both bench units, 2026-09-23: `192.168.1.80` (v1.0.11, `hw/1.0`) and
`192.168.1.163` (v1.1.5, `hw/1.1`) — same NetworkManager (1.52.1), same empty `conf.d`,
same netplan-rendered profile, same `on`.

With power-save on, the access point buffers frames for a dozing station until the next
beacon (100 TU here, DTIM 3), so traffic **into** the gateway waits. Traffic the gateway
originates mostly does not, because transmitting wakes the radio first — which is why
`measure.sh` pings from both directions.

## The fix

One file, byte-identical in this patch and in the image
(`stage2/02-net-tweaks/files/eatabit-wifi-powersave.conf`):

```ini
[connection]
wifi.powersave = 2
```

`2` is `NM_SETTING_WIRELESS_POWERSAVE_DISABLE`. As a `[connection]` default it applies to
every Wi-Fi profile that says `0 (default)` — including profiles created later by
re-provisioning from the app — and NetworkManager re-applies it at **every** activation.
That is the point: a bare `iw dev wlan0 set power_save off` is a one-shot that the next
reassociation undoes.

**Why not per-profile (`nmcli con modify … 802-11-wireless.powersave 2`).** On these
images the active profile is **netplan-generated** (`netplan-wlan0-<SSID>`, rendered from
`/etc/netplan/90-NM-<uuid>.yaml`), so `nmcli con modify` writes into the netplan YAML for
that one profile, and the setting is lost the next time the app provisions a network.

## Affected versions

Every released version: **v1.0.1–v1.0.11 and v1.1.0–v1.1.5**. `git grep` for
`powersave` / `power_save` finds nothing on any of the 17 release tags or either branch
tip (`BUG-093` → *Root cause*).

## The gate — deployed state, not a checksum

This patch replaces no file, so there is no prior sha to compare. It gates on three
observables and **refuses** anything it does not recognise, printing what it saw:

| # | Observable | Accepted prior | Already fixed | Refused |
|---|---|---|---|---|
| 1 | `/etc/NetworkManager/conf.d/eatabit-wifi-powersave.conf` | absent | present at the payload sha `76070047…` | present at any other sha (sha printed) |
| 2 | any **other** NetworkManager config file setting `wifi.powersave` | none | none | any (file named) — someone else already decided |
| 3 | each Wi-Fi profile's `802-11-wireless.powersave` | `default` or `disable` | same | `enable` or `ignore` — an explicit per-profile choice overrides the global default, so leaving it would report fixed while power-save stays on |

`iw dev wlan0 get power_save` is **reported and converged, never refused on** — it is
the thing being changed. A device with the conf installed but the radio still `on` (an
earlier run died between steps, or NetworkManager has not reactivated) is **partial**:
apply converges it forward.

The payload shipped beside `apply.sh` is itself checked against `FIXED_SHA` before
anything is installed, so a corrupted or edited copy refuses.

**`NetworkManager --print-config` is reported but is not a gate.** It re-parses the files
on disk, so it shows the merged *file* value, not what the running daemon holds, and it
cannot say which file set a key. It also needs root: netplan's generated
`/run/NetworkManager/conf.d/netplan.conf` is mode `0640`.

## Applying

```bash
scp -r patches/2026-09-23-wifi-powersave-off eatabit@<ip>:
ssh eatabit@<ip>
cd 2026-09-23-wifi-powersave-off
./apply.sh --check          # no root; exit 0 fixed / 1 refuse / 2 would apply
sudo ./apply.sh --check     # complete gate (reads netplan.conf too)
sudo ./apply.sh
```

`--check` without root cannot read netplan's `0640` config and says **NOT FULLY
CHECKED** rather than reporting a clean gate. Run it with `sudo` for a verdict you can
act on.

Apply does, in order: back up the prior state (on every stock image this records the
conf file's **absence**, plus every observable, in `prestate`); `install -m 644` the
conf; `nmcli general reload conf`; `iw dev wlan0 set power_save off` and confirm it reads
`off`; record `mqtt-client`'s `MainPID` before and after; write the `applied` marker.
A second run on a fixed device is a no-op (exit 0, nothing touched, no marker written).

**Forbidden in this patch, and absent from it:** restarting or reloading NetworkManager,
`nmcli con up`/`down`, `nmcli device reapply`/`disconnect`. Each drops or reassociates
Wi-Fi, and Wi-Fi is the only way in.

**`nmcli general reload conf` does reach the running daemon.** Measured on
`192.168.1.80` (v1.0.11) on 2026-09-24. NetworkManager journaled
`config: signal: CONF,config-files,values,…` listing `eatabit-wifi-powersave.conf` among
the files it re-read. Apply logs those lines itself on every run. If a future NetworkManager
ignored the reload, nothing would be lost: the conf takes effect at the next activation, and
the `iw` call covers the interval.

## Rollback

```bash
sudo ./apply.sh --rollback
```

Removes the conf (or restores a pre-existing one from the backup),
`nmcli general reload conf`, sets `iw` power-save back to the recorded prior state
(`on` on a stock device), removes the marker and the backup. Same no-restart rule.

## After applying

- `iw dev wlan0 get power_save` → `Power save: off`
- `sudo ./apply.sh --check` → exit 0
- After the next reassociation, radio cycle, driver reload or reboot, still `off`.

**What actually holds it off: measured, with controls** (`192.168.1.80`, v1.0.11,
2026-09-24). The disruptions below are the same commands BUG-094's `netwatch` uses:

| Event | Without the conf (power-save forced off first) | With the conf |
|---|---|---|
| `nmcli con down` / `up` | stays **off** | off |
| `nmcli radio wifi off` / `on` | stays **off** | off |
| driver reload (`modprobe -r brcmfmac_cyw brcmfmac; modprobe brcmfmac`) | back to **on** | **off** |
| reboot | **on** (stock boot) | **off** |

`brcmfmac` keeps the last runtime setting across a reconnect or a radio cycle, so those
two events do not tell the conf from a one-shot `iw`. **A driver reload and a reboot reset
the chip to its default (on), and the conf is what turns power-save back off after both.**
Those are exactly the events a bare `iw` call would lose. They are also BUG-094 `netwatch`'s
last two recovery steps, so on a device carrying both patches, this conf is what keeps
power-save off through a netwatch recovery.


## Measuring efficacy — `measure.sh`

Read-only apart from the A/B mode, and committed **before** the before-window so that
both windows are taken by the same code. `./measure.sh --help` for all modes.

| Mode | Where | What |
|---|---|---|
| `window` | Pi, `sudo` | ping samples to the default gateway (60 packets every 15 min at the default 1 s interval), radio counters with reassociation-safe deltas, reconnects by BSSID from the journal, `mqtt-client` interruptions from its log |
| `inbound` | workstation | pings the Pi on the same schedule — the direction power-save actually delays. Portable to macOS `/bin/bash` 3.2 |
| `ab` | Pi, `sudo` | interleaved runtime toggle, `iw set power_save on/off` in alternating rounds (`-r` ≥ 3). Restores the prior state on exit, `INT`, `TERM`, `HUP` and an SSH drop (all four tested on `192.168.1.80`, 2026-09-23) |
| `abreport` | workstation | joins an `ab` run's arm times with an `inbound` run taken alongside it |

**Bench result (2026-09-24, `192.168.1.80`): no measurable effect.** The interleaved A/B
(4 rounds × 60 packets per arm) gave outbound Pi→gateway mdev of 2.6 ms with power-save on
and 5.8 ms with it off, with round-to-round spread larger than the difference. Inbound
from the workstation showed ~150 ms spikes in *both* arms. A control ping from the
workstation to the router showed the same spikes, so they come from the **workstation's
own Wi-Fi**, not the Pi. **Run `inbound` from a wired host**, or it measures the wrong
radio. A null bench result was always an acceptable outcome (*Honest scope*): a quiet
single-AP bench is not where power-save costs show, if they show at all.

**Headline metric:** `mdev` — the population standard deviation of every per-packet RTT
in the window, the same formula `ping` uses — with p95 beside it. Jitter is what maps
onto the failure mode: `mqtt-client` disconnects are `AWS_ERROR_MQTT_TIMEOUT` against a
ping window.

`brcmfmac` reports `tx failed` but **not** `tx retries` or beacon loss in
`iw station dump`; `measure.sh` prints "not reported by driver" for those, never 0. Missed
beacons come from `/proc/net/wireless`.

## Payload identity

The two copies must stay byte-identical:

```bash
shasum -a 256 patches/2026-09-23-wifi-powersave-off/eatabit-wifi-powersave.conf \
              stage2/02-net-tweaks/files/eatabit-wifi-powersave.conf
# both: 7607004708149223e138a3dc16e3904d906e043a085ebd8880c0196256d2fcac
```

## On-device state

`/usr/local/lib/eatabit/patches/2026-09-23-wifi-powersave-off/`

| Path | Holds |
|---|---|
| `backup/prestate` | every observable before the first apply |
| `backup/eatabit-wifi-powersave.conf` | only if the target pre-existed |
| `applied` | timestamp, version, power-save before/after, `mqtt-client` `MainPID` before/after |
| `apply.log` | everything apply and rollback printed |
