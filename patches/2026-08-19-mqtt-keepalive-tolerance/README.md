# 2026-08-19 — MQTT keep-alive has no tolerance for a late `PINGRESP` (`BUG-045`)

| | |
|---|---|
| **Tracker** | `BUG-045` |
| **Lineage** | `mqtt-client` — chains **after** [`2026-08-20-ngrok-session-reclaim`](../2026-08-20-ngrok-session-reclaim/) |
| **Target file** | `/usr/local/lib/eatabit/bin/mqtt-client.js` (js only — **no unit change**) |
| **Restarts** | `mqtt-client.service` — once |
| **Severity** | Medium — healthy connections torn down by ordinary airtime contention |

## The bug

`mqtt-client.js` sets `with_keep_alive_seconds(30)` and never sets a ping timeout, so the
AWS CRT default of **3000 ms** applies. A `PINGRESP` that arrives even slightly late tears
the connection down.

On device `00000000d9b7e5d1` every observed disconnect was **`AWS_ERROR_MQTT_TIMEOUT`**, and
the connected durations landed on a keep-alive boundary plus the ping timeout every time —
**33.2 s, 63.2 s, 93.2 s, 243.3 s, 273.3 s, 398.5 s**, i.e. `n × 30 s + ~3.2 s`. Meanwhile the
WiFi association never dropped (zero NetworkManager reassociations in 21+ hours) and signal
sat at **−47 dBm**. The link was fine; one packet exchange missed a three-second window.

## The fix

```js
configBuilder.with_keep_alive_seconds(30);
configBuilder.with_ping_timeout_ms(10_000);   // <- added
```

Keep-alive is **unchanged**. Only the response window widens, 3 s → 10 s.

| | before | after |
|---|---|---|
| keep-alive | 30 s | 30 s |
| ping timeout | 3 s (CRT default) | **10 s** |
| worst-case disconnect on a genuine outage | ~33 s | **~40 s** |
| Layer 1 watchdog `MAX_DISCONNECT_DURATION_MS` | 150 s | 150 s |
| systemd `WatchdogSec` | 180 s | 180 s |

`keep_alive + ping_timeout` (40 s) stays far below the Layer 1 watchdog (150 s), which stays
below the Layer 3 escalation budget. The SDK requires `ping_timeout < keep_alive`; 10 s < 30 s
holds with margin. **Cost: genuine-offline detection is 7 s slower.**

> ### What this does NOT do
>
> It does **not** add tolerance for a genuinely **lost** `PINGRESP`. The CRT MQTT311 client
> sends one `PINGREQ` per keep-alive interval and tears down if no response arrives inside
> `ping_timeout`; there is no missed-ping counter and no retry inside the window. This buys
> tolerance for **latency**, not for packet loss. If the `~33 s` disconnect cluster merely
> moves to `~40 s` rather than thinning out, the cause is loss and this is the wrong fix.

## Coverage

**Checksum-gated, and deliberately narrow — exactly one accepted prior state.**

| | sha256 |
|---|---|
| `FIXED_SHA` (end state) | `b009b68c8692314ed8476f3bbb3b1d479c3d97fca67240f7bcf96e44444ed339` |
| accepted prior | `1d49a43a401d782bf9d72f69f2c9346c21405a17685185bdbd50f03986d60121` |

That single prior is the output of `2026-08-20-ngrok-session-reclaim`, which is also the repo
source on **both** `hw/1.0` and `hw/1.1`.

**Why not accept stock builds too, as the lineage head does?** Because the payload here is
derived from the head generation, which stores its device-ready guard flag at
`/run/eatabit/device-ready-printed`. That directory exists only because the head's **unit**
declares `RuntimeDirectory=eatabit`. Stock units (`v1.0.8`–`v1.0.10`, `v1.1.2`–`v1.1.4`) carry
`PrivateTmp=true` and **no** `RuntimeDirectory` — verified against
`v1.1.4:stage3/03-install-mqtt-client/00-run.sh` on 2026-08-23. Accepting a stock sha would
therefore install js that needs `/run/eatabit` onto a device whose unit never creates it,
silently reintroducing `BUG-039` from a patch that touches no unit at all.

The head is self-contained and already fleet-applied, so requiring it costs nothing.

**Run `2026-08-20-ngrok-session-reclaim` first.** Anything else is refused, with the observed
sha printed. Devices outside the patch set get the fix through the `v1.0.11` / `v1.1.5` image
release instead.

`KNOWN_VERSIONS` is informational only. It includes `1.1.0` because bench device
`0000000003c45d6d` reports that string while running head files — a field patch does not
change `VERSION`, and there is no `v1.1.0` release tag at all.

## Usage

```bash
./apply.sh --check      # dry run: 0 = already patched, 1 = would refuse, 2 = would apply
sudo ./apply.sh         # apply
sudo ./apply.sh --rollback
```

`--check` needs no root and changes nothing — run it first over a fragile tunnel.

> **The restart drops your SSH session.** `ngrok` runs *inside* `mqtt-client.service`, so
> restarting it closes the tunnel you are patching over. `apply.sh` detects an SSH session
> (including through `sudo`, whose `env_reset` strips `SSH_CONNECTION`) and re-execs the
> restart+verify **detached**, logging to
> `/usr/local/lib/eatabit/patches/2026-08-19-mqtt-keepalive-tolerance/apply.log`. Reconnect,
> then read that log and the `applied` marker beside it. Restarting also spends from the
> `StartLimitBurst` budget (`BUG-044`).

## Safety

- Backs up the original to `…/backup/mqtt-client.js` **before** installing anything.
- `node --check` on the bundled file **before** install, and again on the installed file.
- **Auto-restore**: if `mqtt-client.service` does not come back `active`, the original is put
  back and the service restarted before the script fails.
- Idempotent: re-running on a device already at `FIXED_SHA` no-ops.
- `--rollback` restores from the backup and restarts.

## Image source

The same one-line change lands in image source on **both** hardware lines, and the shipped
file is byte-identical to what this patch installs — so a reflashed device lands on
`FIXED_SHA` and this patch no-ops. Ships in `v1.0.11` / `v1.1.5` (`ISSUE-065`).
