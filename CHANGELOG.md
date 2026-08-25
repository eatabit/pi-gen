# Changelog

All notable changes to the iot-pi image are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Device Node dependencies are now installed at a pinned version at first boot instead of unversioned. `stage2/04-cloud-init/files/user-data` resolved `aws-iot-device-sdk-v2`, `@ngrok/ngrok` and `@abandonware/bleno` from whatever npm `latest` happened to be on each device's first-boot day, so no two flashes were guaranteed the same tree and no release was reproducible — three bench devices carried two different `aws-crt` versions (1.33.1 and 1.32.1), the library that implements MQTT keep-alive and ping handling. They now install `aws-iot-device-sdk-v2@1.28.0`, `@ngrok/ngrok@1.7.0` and `@abandonware/bleno@0.6.2`, and the resulting set — including the transitively-fixed `aws-crt@1.33.1` — is recorded in `VERSIONS.md`, so a release tag identifies its dependency set without touching a device. Applies to newly flashed devices only; cloud-init `runcmd:` never re-runs on a provisioned device.

### Fixed

- The device-ready receipt no longer reprints on every service restart. `mqtt-client.service` sets `PrivateTmp=true`, so systemd hands the unit a fresh private `/tmp` on every start, and the once-per-power-cycle guard lived at `/tmp/eatabit-device-ready-printed` — so every restart destroyed it and the receipt printed again, including after the Layer 1 watchdog's exit at 150 s disconnected. A flapping device reprinted all night: measured in the field as 5 service starts to 5 ready prints, 1:1, across 21 h 30 m with exactly one boot. The flag moves to `/run/eatabit/device-ready-printed`, created by systemd through `RuntimeDirectory=eatabit` with `RuntimeDirectoryPreserve=restart`, so it survives a restart and clears on reboot or power cycle. The in-code comment claiming the old path already behaved that way was false in both halves and is corrected, and a silent write failure no longer passes unnoticed.
- A single late MQTT keep-alive response no longer tears down a healthy connection. `mqtt-client.js` set `with_keep_alive_seconds(30)` and never set a ping timeout, so the AWS CRT default of 3000 ms applied and a `PINGRESP` arriving slightly late killed the connection: every disconnect observed on device `00000000d9b7e5d1` was `AWS_ERROR_MQTT_TIMEOUT`, with connected durations landing on n × 30 s + ~3.2 s while the WiFi association never dropped and signal held at −47 dBm. The response window widens from 3 s to 10 s via `with_ping_timeout_ms(10_000)`; the keep-alive interval is unchanged. Genuine-offline detection moves from 33 s to 40 s, still well inside the 150 s disconnect ceiling and the 180 s `WatchdogSec`. This buys tolerance for latency, not for packet loss.
- Bluetooth no longer degrades the device's own WiFi. The adapter page- and inquiry-scanned 24/7 (`hci0 UP RUNNING PSCAN ISCAN`) on a CYW43438, which shares one 2.4 GHz front end and one antenna between WiFi and Bluetooth; first-hop jitter measured 22.363 ms with Bluetooth on against 2.668 ms with it off, WiFi untouched between arms — enough on its own to blow the MQTT ping window. Classic BR/EDR scanning is now disabled (`ControllerMode = le`, `FastConnectable = false`), which removes `PSCAN` and `ISCAN` entirely. **Provisioning is untouched and is gated on nothing:** it is Bluetooth Low Energy end to end — the device advertises through bleno and the mobile app discovers it with an LE-only scan — so no classic inquiry was ever part of pairing, and a device is never less discoverable after this change than before it. Measured across seven devices on both hardware lines, first-hop jitter improved between 1.58× and 5.48×; on one noisy site the effect was smaller than the run-to-run spread.
- Remote support tunnels can be opened more than once per `mqtt-client` lifetime. After a single connect/disconnect cycle, every later `startNgrokTunnel` failed with `reasonCode` 500 until the service restarted — and because field patches ship over that tunnel, a patch campaign degraded to reboot, connect, patch, reboot per device, dropping in-flight print jobs at every reboot. The cause is that the `@ngrok/ngrok` agent session is process-global and outlives its tunnel: `ngrok.forward()` builds an implicit session and returns only a listener, and both `disconnect()` and `kill()` close listeners rather than sessions, so nothing ever reclaimed one. Sessions are now reclaimed explicitly and the calls are bounded and serialised, and a call that returns after its bound no longer strands the session it goes on to create — observed in the field as a credential minted at 18:07:57Z whose abandoned call produced a listener-less session 811 seconds later, one leaked per start. `stopNgrokTunnel` against no active tunnel now reports success with a distinct reason code instead of failing.
- `/var/log` now reaches the SD card hourly instead of only on a clean shutdown. The image installed `log2ram-daily.timer` but only ever enabled the service, and `/var/log` is a 64 MB tmpfs — so the RAM copy was written back only by `log2ram.service`'s stop action, and any reboot that was not a clean stop destroyed the logs that would have explained it. The timer is now enabled, and a drop-in replaces the stock `OnCalendar=*-*-* 23:55:00` — a fixed wall-clock instant with a worst case near 24 hours — with an hourly schedule. Card wear is not materially affected: `log2ram` syncs with `rsync --inplace --no-whole-file`, so only changed blocks are written and raising the frequency multiplies only partial-tail-block amplification, a derived ceiling near 1 MB/day.
- Application logs are now rotated, and the log directory is no longer world-writable. `/usr/local/lib/eatabit/log` was mode 0777, and logrotate refuses to act on a file whose parent directory is world-writable unless its configuration carries an `su` directive — which this one did not, so `mqtt-client.log` had never been rotated on any released image, on either hardware line. The directory is now 0755, which costs nothing because every writer into it runs as root. `ble-config.log`, which had no rotation configuration at all, gains one. Twenty over-broad permission sites are narrowed across the install scripts and the Node applications together, since the applications re-create these paths themselves and a shell-only fix would have been undone by the next service start. Separately, `shadow-health.json` was rewritten in full every 15 minutes — 96 whole-file writes a day, roughly 159 KiB straight to the card — because an embedded timestamp made every serialisation differ; it is now written only when the state itself changes. Four inert `log2ram.conf` keys, including a `LOG_DIRS` line that `log2ram` never reads, are deleted rather than repaired.
- Gateways now keep UTC instead of `Europe/London`. Every image inherited pi-gen's build default untouched, so a device installed in Hawaii reported a UK clock — a permanent 11-hour offset on every journal line and file mtime, which actively misled the investigation it was found in, where 1:25 AM in the customer's office read as lunchtime. The default is overridden in `config` rather than in `build.sh`, which is upstream pi-gen and would conflict at every upstream sync.
- Field patches now detach correctly when applied over SSH. **This changes the field-patch tooling under `patches/`, not the running image.** The remote-session check walked the parent process chain testing for the exact process name `sshd`, but OpenSSH 9.8 and later split the per-connection process out as `sshd-session` and keep the bare name only for the listener — so under systemd socket activation the chain contains no `sshd` at all, detection reported a local console, and a patch that restarts `mqtt-client` ran the restart inline and killed the connection carrying it. The check now matches `sshd*`, a strict superset of the old test.

## [1.0.10] — 2026-06-30

### Fixed

- Offline reboot loop: a device with no usable network (factory reset / no WiFi config, or lost network) reboot-looped every ~2–4 minutes. `mqtt-client` never signaled systemd `READY` (the connect couldn't succeed), so the `Type=notify` start kept failing until `StartLimitAction=reboot-force`. It now sends `READY=1` before connecting and retries the initial connect in the background instead of exiting, so an offline device stays up and waits (BLE-provisionable) instead of looping. The Layer 1 watchdog and reboot-force for genuine pre-readiness crashes are preserved.
- Expired jobs stuck `IN_PROGRESS` blocking the queue: an expired job is now terminated with a status legal for its current execution state — `FAILED` when already `IN_PROGRESS` (arrived via `start-next`), `REJECTED` when still `QUEUED` — and a job that expires mid-download now fails cleanly instead of being silently dropped. Previously the device tried to `REJECT` an `IN_PROGRESS` execution (an illegal transition), leaving it stuck and suppressing `notify-next` for every later job.

## [1.0.9] — 2026-06-03

### Fixed

- BLE WiFi config rejected open (passwordless) networks: `applyWiFiConfig` in `ble-config.js` returned "missing SSID/password" (status `0|0|1`) whenever the password was empty, so it never reached the open-network branch that creates an unsecured nmcli profile. The mobile app offers open networks ("leave blank for open networks"), so configuring one always failed on-device. Now only the SSID is required.

## [1.0.8] — 2026-05-12

### Fixed

- MQTT client watchdog `process.exit(1)` was unreachable because the preceding `await publishEvent(...)` could hang forever on a wedged AWS IoT SDK connection — a field device observed offline for 18h with ~1000 "Connection watchdog triggered" log lines and no actual exit. The publish is now fire-and-forget with a `setTimeout` backstop.
- `mqtt-client.service` `StartLimitIntervalSec` and `StartLimitBurst` were in `[Service]` instead of `[Unit]` and were silently ignored by systemd (visible in journalctl as `Unknown key 'StartLimitIntervalSec' in section [Service]`), disabling Layer 3 restart escalation. Moved to `[Unit]`.

## [1.0.7] — 2026-04-09

### Fixed

- Enable infinite WiFi autoconnect retries (`connection.autoconnect-retries=0`) for all WiFi profiles — devices in poor-signal locations would permanently disconnect after 4 failed reconnect attempts (NetworkManager default) and never recover without a reboot
- Explicitly set `connection.autoconnect=true` on WiFi profiles created via BLE config and cloud-init to guard against profile corruption

## [1.0.6] — 2026-03-29

### Fixed

- Add sudo and hardware groups to cloud-init eatabit user — user was missing `sudo`, `dialout`, `gpio`, `spi`, `i2c`, and other groups assigned by pi-gen
- Enable passwordless sudo for eatabit user via cloud-init `sudo` directive

## [1.0.5] — 2026-03-29

### Fixed

- Disable "Sound after cutting" in buzzer config (setkey 0xDB) — the one-shot cut beep was overriding the optical sensor's continuous buzzer when a second order printed before paper was pulled

## [1.0.4] — 2026-03-17

### Added

- Wifi disable ESC/POS command (`wifi-disable.bin`) to turn off printer wifi radio
- Documentation for wifi disable command sequence (`docs/ESCPOS/Custom Setup Commands.md`)
- `printer-config` journalctl command to Raspberry Commands reference
- Stage README for `stage3/13-install-printer-config`

### Changed

- Printer config service uses per-command marker files instead of single `.configured` flag — each command can be retried individually
- Printer config service detects and recovers from printer reboots between commands

### Fixed

- Diagnostic sheet now queries live systemctl status for services instead of reading stale health.json snapshot

## [1.0.3] — 2026-03-10

### Added

- Print build version on diagnostics page

## [1.0.2] — 2026-03-10

### Added

- Disable printer wifi radio via ESC/POS command on first boot

### Fixed

- Revert eatabit user home directory to default `/home/eatabit` — custom homedir (`/usr/local/lib/eatabit`) broke SSH public key authentication
- Always set eatabit user shell to `/bin/bash` — upstream pi-gen change (`4b9cd15`) set shell to `nologin` when no password is configured, breaking SSH key-only login
- Validate presigned S3 URL before printing — use `curl --fail` to detect expired URLs instead of silently printing S3 XML error responses

## [1.0.1] — 2026-03-09

### Added

- WiFi configuration query in `ble-config.js` (SSID, signal strength, IP, gateway, DNS, link quality)
- Documentation for provisioning stage (`stage3/02-build-provisioning/README.md`)
- Documentation for health monitor stage (`stage3/07-health-monitor/README.md`)
- Documentation for BLE config stage (`stage3/08-ble-config/README.md`)
- Release workflow documentation (`docs/RELEASES.md`)
- Changelog (`CHANGELOG.md`)

### Changed

- Set eatabit user home directory to `/usr/local/lib/eatabit` via cloud-init
- `iot-provision.js` reads version from `/usr/local/lib/eatabit/version` instead of hardcoding it
- Rewrite `docs/Git.md` with accurate remote, branch, and rebase workflow
- Fix Status LED pin mapping: Pin 3 is Green, Pin 4 is Blue (was swapped)
- Update Status LED resistor values for Green and Blue from 33Ω to 100Ω
- Reduce ready print and reset print image width to 90% of paper width with centering

## [1.0.0] — 2026-03-09

### Added

- Initial Raspberry Pi OS image (Debian Trixie, arm64)
- AWS IoT Core fleet provisioning (`iot-provision.js`)
- MQTT client with Device Shadow reporting (`mqtt-client.js`)
- Cloud-init and SSH enabled by default
