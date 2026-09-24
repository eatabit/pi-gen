# `2026-09-23-netwatch` — BUG-094: a device never recovers from a network outage

| | |
|---|---|
| **Lineage** | **`mqtt-client`** — entry 6, **requires 5** (`2026-08-23-app-permissions-and-shadow-churn`). Also starts the `boot-print`, `health-monitor` and `netwatch` targets, which no other patch touches. |
| **Accepted priors** | `mqtt-client.js` `7ecbf0ea…` only (entry 5's end state == image source at v1.0.11 / v1.1.5) · `boot-print.sh` `2998dd94…` · `health-monitor.js` `e251ba26…` (each byte-identical in all 17 release tags v1.0.1–v1.1.5) · the four netwatch files must be absent |
| **Restarts** | `mqtt-client.service` — **drops in-flight print jobs** (BUG-049) and closes an ngrok SSH session, so over SSH the restart+verify runs **detached** |
| **Tracker** | `BUG-094` (`iot-doc/tracking/bugs/BUG-094-iot-pi-never-recovers-from-network-outage/`) |

> **This patch restarts services.** It replaces running code, adds a timer that can
> reboot the device when it has lost the network, and changes what prints at boot.

## What it fixes

A device that lost its network stayed offline until someone power-cycled it. Every
existing recovery layer watches the MQTT session or the Node process; **none watches the
link**. A wedged radio, driver or NetworkManager state was never acted on, and since the
June offline-reboot-loop fix, a device that cannot reach AWS never escalates at all.

**netwatch** is a new oneshot + 60 s timer, independent of `mqtt-client`. When the client
reports disconnected **and** netwatch's own DNS + TCP probe of the IoT endpoint fails, it
escalates by accumulated offline time:

| Offline for | Step |
|---|---|
| 2 min | snapshot + log |
| 3 min | `nmcli con down/up` on the fingerprinted connection |
| 6 min | `nmcli radio wifi off/on` |
| 7 min | `brcmfmac` driver reload (with its loaded `brcmfmac_*` vendor module) |
| 10 min | reboot — then again at +30 min, +1 h, +2 h, +4 h, then every 6 h |

It stops as soon as the probe or the client succeeds. The backoff counter resets after
30 minutes continuously connected.

### Guards

1. **Only a network that has worked.** Steps 2–4 run only while the saved NetworkManager
   connection matches the UUID + SSID recorded when the client last connected. A factory
   reset or BLE re-provision changes it, so a never-connected device is logged, never
   disrupted — this is what keeps the June reboot loop from returning.
2. **Never interrupt a print.** `mqtt-client` publishes `printing` in its status file;
   disruptive steps are deferred while it is set.
3. **Uptime floor.** No reboot in the first 5 minutes after boot.
4. **No receipts after a watchdog-initiated reboot** — neither `booting` nor ready. A
   normal boot, and a human power-cycle, still print both.

### Receipt suppression

Before rebooting, netwatch writes `/usr/local/lib/eatabit/state/netwatch-reboot`
(`{"writtenBootId":…,"boundBootId":null}`) on the card. On the next boot `boot-print.sh`
binds it to the new `boot_id` and skips; `mqtt-client.js` sees it bound to its boot and
skips the ready receipt, but still sets the ready flag. netwatch then deletes it —
`mqtt-client` cannot, because its unit is `ProtectSystem=strict` and the state dir is not
in its `ReadWritePaths`. A marker bound to an **earlier** boot is stale and is removed,
so a human power-cycle always prints. `boot_id`, not time: the Pi has no RTC.

### Reconnect summary and health shadow

On recovery after any step, netwatch writes a summary that `mqtt-client` publishes once
as `device.networkRecovered` on `eatabit/things/<id>/events` (contract pinned in
`iot-constants` `DEVICE.EVENTS.networkRecovered`) and adds to the health shadow as
`lastNetworkRecovery`. `health-monitor.js` now reports `bssid` and takes RSSI from
`iw dev wlan0 link` (live) rather than `iwlist wlan0 last` (last scan, can be stale).

Everything netwatch does is in `/usr/local/lib/eatabit/log/netwatch.log` — card-backed,
one JSON line per entry, `fsync`'d, rotated at 1 MB × 2.

## Apply

```bash
scp -r patches/2026-09-23-netwatch eatabit@<device>:/tmp/
ssh eatabit@<device>
cd /tmp/2026-09-23-netwatch
./apply.sh --check        # 0 = already patched   1 = would refuse   2 = would apply
sudo ./apply.sh
```

Over SSH the restart+verify runs detached; reconnect and read
`/usr/local/lib/eatabit/patches/2026-09-23-netwatch/apply.log`. Then:

```bash
systemctl is-active netwatch.timer                    # active
cat /run/eatabit/mqtt-status.json                     # "connected":true
sudo tail -n 3 /usr/local/lib/eatabit/log/netwatch.log  # "startup" / "healthy" / "fingerprint"
```

**A device behind entry 5 refuses** and says why. Climb the lineage first
(`2026-08-20-ngrok-session-reclaim` → `2026-08-19-mqtt-keepalive-tolerance` →
`2026-08-23-app-permissions-and-shadow-churn`). **The version string does not decide
this — the checksums do.** A field device reporting **v1.0.7** yet sits
exactly on every accepted prior (`--check` → would apply, 2026-09-24): earlier field
patches had already carried its `mqtt-client.js` to `7ecbf0ea…`. Only a device whose
`mqtt-client.js` no lineage patch accepts needs a reflash — run `--check` and see.

## Rollback

```bash
sudo ./apply.sh --rollback
```

Disables and removes netwatch, restores the three replaced files from the backup and
restarts `mqtt-client`. `netwatch.log` and the state dir are kept as evidence; any reboot
marker is removed.
