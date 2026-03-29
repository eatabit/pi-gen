# Changelog

All notable changes to the iot-pi image are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
