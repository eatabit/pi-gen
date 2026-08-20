# Field Patches

Manual patches to apply to already-deployed devices over SSH, without re-flashing the image.

Each subdirectory is a self-contained patch with its own `README.md` (bug summary + affected versions) and `apply.sh` (idempotent batch script). To apply: `scp -r` the patch directory to the device, then run `sudo ./apply.sh` over SSH.

A patch lands here when:
- A bug is severe enough that fleet devices need it before the next image build / OTA window.
- The fix can be applied in-place by replacing files under `/usr/local/lib/eatabit/` and/or `/etc/systemd/system/` without re-imaging.

The same fix is **also** committed to the image source on the appropriate `hw/*` branch and shipped in a normal versioned release. The patch is a stopgap; the image is the source of truth.

## Patches

| Date | Patch | Affected versions | Severity |
| --- | --- | --- | --- |
| 2026-05-12 | [`2026-05-12-watchdog-exit-hang`](./2026-05-12-watchdog-exit-hang/) | v1.0.2–v1.0.7, v1.1.0–v1.1.1 | Critical — devices can be offline indefinitely |
| 2026-06-30 | [`2026-06-30-offline-reboot-and-expired-job`](./2026-06-30-offline-reboot-and-expired-job/) | stock/offline-reboot-patched mqtt-client.js (checksum-gated) | High — offline reboot loop + expired job blocks queue (combined rollup) |
| 2026-08-19 | [`2026-08-19-device-ready-flag-privatetmp`](./2026-08-19-device-ready-flag-privatetmp/) | all shipped versions are affected; patch accepts stock v1.0.8–v1.0.10 / v1.1.2–v1.1.4 + 2026-06 field-patch intermediates (checksum-gated, js **and** unit) | High — ready receipt reprints on every service restart; printer prints/beeps overnight in a customer's office |
