# Device Node dependency versions

The Raspberry Pi gateway installs three Node packages **globally at first boot**, from
`stage2/04-cloud-init/files/user-data` (the cloud-init `runcmd:` block). This file records
the exact versions a given release tag installs, so the dependency set can be read **from
the repo, without touching a device**.

Tracker item: **ISSUE-067**.

## Pinned set

| Package | Version | How it is fixed |
| --- | --- | --- |
| `aws-iot-device-sdk-v2` | `1.28.0` | Pinned **directly** in `user-data`. |
| `aws-crt` | `1.33.1` | **Transitive, not pinned directly.** See below. |
| `@ngrok/ngrok` | `1.7.0` | Pinned **directly** in `user-data`. |
| `@abandonware/bleno` | `0.6.2` | Pinned **directly** in `user-data`. Built on-device via `node-gyp rebuild`. |

Established **2026-08-23** via `npm view`, against the versions already running on
hardware. `aws-iot-device-sdk-v2@1.28.0` was npm `latest` on that date, so the pin is not
a rollback.

## `aws-crt` is fixed transitively — there is no line for it in `user-data`

Do not read the table above as saying `aws-crt` is pinned directly. It is not, and no
`npm install -g aws-crt@…` line exists or should be added.

`aws-crt` is fixed because `aws-iot-device-sdk-v2@1.28.0` declares it as an **exact
literal**, not a semver range:

```
$ npm view aws-iot-device-sdk-v2@1.28.0 dependencies
{
  '@aws-sdk/util-utf8-browser': '^3.109.0',
  'aws-crt': '1.33.1',
  uuid: '^8.3.2'
}
```

Pinning the SDK therefore fixes `aws-crt` as a consequence. This matters because `aws-crt`
is the C library implementing the MQTT client, keep-alive and ping handling — the
component that actually drives device connection behaviour.

Note that the SDK's other two dependencies (`@aws-sdk/util-utf8-browser`, `uuid`) **are**
ranges and remain unpinned. They are small, pure-JS, and not on the connection path. If
that ever stops being acceptable, the escalation is a `package.json` + `package-lock.json`
installed with `npm ci` (evaluated and deferred under ISSUE-067).

## Rule: re-check on any SDK bump

**Any future bump of `aws-iot-device-sdk-v2` must re-run:**

```
npm view aws-iot-device-sdk-v2@<new-version> dependencies
```

**and confirm `aws-crt` is still an exact literal.** If it has become a range (`^1.33.1`,
`~1.33.1`, …), this manifest no longer describes the tree that gets installed, the
`aws-crt` row above is false, and pinning top-level versions is no longer sufficient — a
lockfile-based install (`package.json` + `npm ci`) is required instead.

Update the table and the date in this file whenever any pin changes.

## Scope — new flashes only

These pins take effect at **first boot**, under cloud-init `runcmd:`, which runs **once per
device**. A device already provisioned will never re-run them and keeps whatever versions
it resolved on its own first-boot day. Pinning stops new drift; it does not converge the
existing fleet. Remediation for already-provisioned devices is a separate open question on
ISSUE-067.

Both hardware lines (`hw/1.0` and `hw/1.1`) carry these pins.
