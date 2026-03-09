# Changelog

All notable changes to the iot-pi image are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `iot-provision.js` reads version from `/usr/local/lib/eatabit/version` instead of hardcoding it

## [1.0.0] — 2026-03-09

### Added

- Initial Raspberry Pi OS image (Debian Trixie, arm64)
- AWS IoT Core fleet provisioning (`iot-provision.js`)
- MQTT client with Device Shadow reporting (`mqtt-client.js`)
- Cloud-init and SSH enabled by default
