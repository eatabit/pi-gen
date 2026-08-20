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
| 2026-08-20 | [`2026-08-20-ngrok-session-reclaim`](./2026-08-20-ngrok-session-reclaim/) | **supersedes the 2026-08-19 patch** — self-contained rollup, no prerequisite; accepts stock v1.0.8–v1.0.10 / v1.1.2–v1.1.4, the 2026-06 intermediates, and the 2026-08-19 output (checksum-gated, js **and** unit) | High — one connect/disconnect cycle wedges remote SSH until `mqtt-client` restarts; this is the delivery path every other patch ships over |

> **Removed:** `2026-08-19-device-ready-flag-privatetmp` (BUG-039) was folded into the
> 2026-08-20 rollup above and deleted — it installed the same unit byte-for-byte and a
> strictly older `mqtt-client.js`, so running it first only cost a second `mqtt-client`
> restart, and every restart drops in-flight print jobs. It remains in git history, and
> its output sha `d4647dab…` is still an accepted pre-state of the rollup.
