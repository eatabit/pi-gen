# WiFi Reconnect Investigation

## Question
When devices are in poor-signal locations and lose WiFi, reports indicate they do not reconnect. Does iot-pi have any retry logic in the WiFi adapter layer?

## Findings

### WiFi Stack
The Pi image uses **NetworkManager + wpa_supplicant**, provisioned via **cloud-init / Netplan**. There is no custom `wpa_supplicant.conf` or `dhcpcd.conf` — the system relies on NetworkManager defaults.

Relevant files:
- `stage2/04-cloud-init/files/network-config` (lines 25–34) — Netplan v2 WiFi config, `dhcp4: true`, `optional: false`.
- `stage2/02-net-tweaks/00-packages` — installs `wpasupplicant`, `network-manager`, `wireless-tools`, WiFi firmware.
- `stage2/02-net-tweaks/01-run.sh` (lines 18–24) — pre-seeds NetworkManager.state with `WirelessEnabled=false` (toggled later for regulatory-domain reasons).

### Retry / Reconnect Logic — at the WiFi layer
**There is no iot-pi-specific WiFi retry logic.** Reconnect on WiFi disconnect is entirely delegated to NetworkManager's default behavior. No custom watchdog, script, or systemd unit monitors the wireless link, runs `nmcli`/`wpa_cli` reconnect commands, or cycles the radio.

### Retry logic that DOES exist (application layer only)
The retry logic lives in the MQTT client, not the network adapter:

- `stage3/03-install-mqtt-client/files/mqtt-client.js`
  - Lines 483–484: `WATCHDOG_INTERVAL_MS = 60_000`, `MAX_DISCONNECT_DURATION_MS = 150_000`.
  - Lines 1678–1709: connection watchdog — if MQTT is disconnected >2.5 minutes, `process.exit(1)`.
  - Lines 920–927, 960–967: `interrupt` / `disconnect` / `error` handlers track state.
- `stage3/03-install-mqtt-client/00-run.sh` (lines 32–70): systemd unit
  - `Restart=always`, `RestartSec=10`
  - `WatchdogSec=180`
  - `StartLimitIntervalSec=600`, `StartLimitBurst=5`
  - `StartLimitAction=reboot-force` — forces a full device reboot if restarts exceed the limit.

### Why this likely fails in poor-signal environments
1. When WiFi drops, NetworkManager is expected to auto-reconnect on its own. In practice, with marginal signal, NM can leave the interface in a `disconnected` or `failed` state and stop trying — there is no iot-pi safety net to kick it.
2. The MQTT watchdog will exit and systemd will restart `mqtt-client.service`, but **restarting the Node process does nothing for a downed wireless link** — it just reopens MQTT against an interface that still has no connectivity. The restarts burn through `StartLimitBurst` quickly.
3. After 5 restarts in 600s, `StartLimitAction=reboot-force` reboots the Pi. A reboot often does recover WiFi (fresh `wpa_supplicant` association), which may explain why some devices "eventually" come back — but it is a blunt recovery path that depends on the MQTT failure cascade actually firing, and it is not guaranteed within any specific window.
4. There is nothing that periodically scans, lowers roaming thresholds, cycles `rfkill`, or calls `nmcli device wifi rescan` / `nmcli connection up <ssid>` when the link is down.

## Summary
- **WiFi-layer retry logic in iot-pi: none.** Reconnect is fully delegated to NetworkManager defaults.
- **Application-layer retry exists** in `mqtt-client` + systemd, but it cannot fix a downed wireless link — at best it triggers a reboot after ~10 minutes of failed restarts.
- The reported symptom (device fails to reconnect after WiFi drop in poor-signal locations) is consistent with NetworkManager giving up on a marginal AP and nothing in iot-pi prodding it to retry.

## Areas to consider (not implemented)
- A lightweight systemd timer/service that pings the gateway or runs `nmcli -t -f STATE general` and, on failure, runs `nmcli connection up <ssid>` or `nmcli device wifi rescan`.
- Tuning NetworkManager `connection.autoconnect-retries=0` (infinite) and `connection.autoconnect=true` for the provisioned WiFi profile. See detailed analysis below.
- Cycling `rfkill` or the `wlan0` interface as an escalation step before falling through to a full reboot.
- Logging WiFi state transitions to make future field reports diagnosable.

---

## Deep dive: `connection.autoconnect` and `connection.autoconnect-retries`

### Current state in iot-pi

WiFi profiles are created in two places, and **neither sets these properties**:

1. **Cloud-init / Netplan** (`stage2/04-cloud-init/files/network-config`) — renders a Netplan v2 YAML at first boot. Netplan translates this into a NetworkManager keyfile under `/etc/NetworkManager/system-connections/`. The generated keyfile inherits NM defaults for any property not explicitly set.

2. **BLE config service** (`stage3/08-ble-config/files/ble-config.js`, lines 363–367) — creates profiles via `nmcli con add`. The commands specify `type`, `con-name`, `ifname`, `ssid`, and optionally security, but never set `connection.autoconnect` or `connection.autoconnect-retries`. Again, NM defaults apply.

### What the NetworkManager defaults are

| Property | Default value | Effect |
|---|---|---|
| `connection.autoconnect` | `true` | NM will attempt to activate the connection automatically when the interface is available and not already connected. |
| `connection.autoconnect-retries` | `-1` (which resolves to `4`) | NM tries to activate the connection **4 times**, then marks the profile as blocked until the user (or a script) manually intervenes, or the device is restarted. |

The `-1` default maps to a compile-time constant of 4 in the NetworkManager source (`NM_AUTOCONNECT_RETRIES_DEFAULT`). This is the critical setting: after 4 failed association attempts, NM stops trying and the connection enters state `deactivated` with the autoconnect flag internally suppressed.

### Why the default `autoconnect-retries` causes the reported problem

Consider a device in a location with marginal WiFi:

1. Signal drops → the `wlan0` interface disconnects.
2. NM immediately begins autoconnect attempts. Each attempt involves scanning, finding the SSID, and trying to associate/authenticate.
3. With a weak or intermittent signal, each attempt may fail (association timeout, DHCP timeout, 4-way handshake failure).
4. **After 4 failures, NM gives up entirely.** The profile is blocked from autoconnect. The `wlan0` interface sits in state `disconnected` indefinitely.
5. Even if the AP signal recovers seconds later, NM will not try again — it has exhausted its retry budget.

On a device with no screen, no user, and no monitoring script, this is a permanent failure state until something external intervenes (reboot, `nmcli con up`, or the MQTT watchdog cascade triggering `reboot-force`).

### What `connection.autoconnect-retries=0` changes

Setting `autoconnect-retries` to `0` means **infinite retries**. NM will never mark the profile as blocked due to failed attempts. The retry behavior becomes:

1. Signal drops → `wlan0` disconnects.
2. NM begins autoconnect attempts, same as before.
3. Each failed attempt is followed by a backoff delay (NM internally increases the delay between retries, typically up to ~5 minutes).
4. **NM never stops trying.** Even after dozens of failures, it continues scanning and attempting to associate.
5. When the AP signal returns (even minutes or hours later), NM will associate on its next retry cycle without any external intervention.

This is the single highest-impact change for the reported issue because it directly addresses the root cause: NM giving up after 4 tries.

### Backoff behavior with infinite retries

NM does not retry at a fixed interval. Its internal backoff works roughly as follows:

- **Attempts 1–4:** retry with short delay (~0–30 seconds).
- **Attempts 5+:** delay grows, typically capping around 300 seconds (5 minutes) between attempts.
- The backoff resets to zero once a connection succeeds.

This means even with `autoconnect-retries=0`, a device in a dead zone won't burn CPU or flood the airwaves — it will settle into a ~5-minute scan-and-try cycle, which is lightweight and appropriate for an embedded headless device.

### Confirming `connection.autoconnect=true`

While `autoconnect` defaults to `true`, explicitly setting it is worth doing for two reasons:

1. **Defense against profile corruption.** If a connection fails badly enough (e.g., wrong PSK stored, cert error), some NM versions can flip `autoconnect` to `false` in the keyfile. Explicitly setting it in the profile creation command makes the intent clear and recoverable.
2. **Visibility.** When debugging a device in the field, `nmcli con show <profile>` will show `connection.autoconnect: yes` explicitly rather than relying on implicit defaults. This makes it immediately clear whether the profile should be auto-activating.

### How these settings would be applied

Both properties would need to be set at profile creation time in the two provisioning paths:

**Cloud-init / Netplan path** — Netplan v2 does not directly expose `autoconnect-retries`. Options:
- Add a NetworkManager dispatcher script or a one-shot systemd unit that runs after first boot to patch the generated keyfile.
- Use a cloud-init `runcmd` to call `nmcli con modify <profile> connection.autoconnect-retries 0`.
- Write a NetworkManager conf.d drop-in (`/etc/NetworkManager/conf.d/99-autoconnect.conf`) that sets a global default, though NM does not support global override of per-connection `autoconnect-retries` — this must be set per-profile.

**BLE config path** (`ble-config.js`) — append the properties to the `nmcli con add` commands:
```
nmcli con add type wifi ... connection.autoconnect yes connection.autoconnect-retries 0
```

### Risks and trade-offs

| Consideration | Assessment |
|---|---|
| **Battery / power** | Not applicable — Pi is mains-powered. The ~5-minute retry cycle draws negligible additional power. |
| **RF interference** | Minimal. Each retry is a single scan + association attempt. Far less RF activity than a constantly-streaming video device. |
| **Wrong-network loops** | If a profile has incorrect credentials, NM will retry forever. Mitigated by the BLE config flow which verifies connectivity before returning success. A profile that was once valid (correct PSK) will remain valid — the AP doesn't change its password. |
| **Log noise** | NM will log each failed attempt to syslog. On a device with limited storage, this could fill logs over days. Mitigated by existing logrotate configuration or by setting `logging.level=WARN` in NM config. |
| **Interaction with reboot-force** | The MQTT watchdog → systemd restart → `reboot-force` cascade still functions. With infinite retries, NM may reconnect WiFi before the cascade completes, making the reboot unnecessary — this is the desired outcome. If NM reconnects and MQTT recovers, the watchdog resets and no reboot occurs. |

### Expected impact on the reported issue

With `autoconnect-retries=0`, the failure mode changes:

| Scenario | Before (default: 4 retries) | After (infinite retries) |
|---|---|---|
| Brief signal drop (<30s) | NM reconnects on retry 1–2. No issue. | Same — no change. |
| Extended drop (1–5 min) | NM exhausts 4 retries during the outage, gives up. Device stays offline until `reboot-force`. | NM continues retrying. Reconnects within ~5 minutes of signal returning. |
| Prolonged dead zone (hours) | Device stuck offline. Eventually reboots via `reboot-force`, which may or may not recover depending on signal at reboot time. | NM retries every ~5 minutes indefinitely. Reconnects whenever signal returns, without requiring a reboot. |
| AP reboots / power cycles | NM may exhaust retries during AP downtime (~2–5 min). Stuck offline. | NM retries through the AP outage. Reconnects when AP comes back. |
