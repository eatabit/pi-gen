# Changelog

All notable changes to the iot-pi image are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
