# Stage 3 — 02-build-provisioning

This build stage installs everything needed for AWS IoT fleet provisioning on the Raspberry Pi. It copies claim credentials and root CAs into the image, then installs the provisioning script that runs on first boot to register the device with AWS IoT Core.

## Build Script (`00-run.sh`)

The pi-gen build script copies the following files into `${EATABIT_ROOT_DIR}` (`/usr/local/lib/eatabit`):

| Source File | Destination | Purpose |
|---|---|---|
| `AmazonRootCA1.pem` | `cert/` | Amazon root CA for TLS verification |
| `AmazonRootCA3.pem` | `cert/` | Backup/alternate Amazon root CA |
| `71cc32...certificate.pem.crt` | `cert/` | Claim certificate for bootstrap authentication |
| `71cc32...private.pem.key` | `cert/` | Claim private key for bootstrap authentication |
| `iot-provision.js` | `bin/` | Provisioning script (installed as executable) |

All copy operations are guarded — the build fails immediately if any file copy fails.

## Provisioning Script (`iot-provision.js`)

A Node.js script that implements [AWS IoT fleet provisioning by claim](https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html). It uses temporary "claim" credentials (baked into the image at build time) to authenticate with AWS IoT Core, request a unique device certificate, and register the device — all without manual intervention.

### Dependencies

- `aws-iot-device-sdk-v2` — AWS IoT Device SDK for JavaScript v2 (MQTT client, TLS)
- `fs`, `path` — Node.js built-ins

### Configuration

| Constant | Value | Description |
|---|---|---|
| `EATABIT_ROOT_DIR` | `/usr/local/lib/eatabit` | Root directory for all Eatabit files |
| `AWS_IOT_ENDPOINT` | `a3fw1u2gvi2uac-ats.iot.us-east-2.amazonaws.com` | AWS IoT Core MQTT broker (us-east-2) |
| `TEMPLATE_NAME` | `templateProvisioning` | AWS IoT provisioning template name |
| `VERSION` | `1.0.0` | Device firmware version sent during registration |
| `PROVISION_TIMEOUT_MS` | `60000` | Hard timeout — exits with code 1 after 60 seconds |

### Device Identity

The device ID is extracted from `/proc/cpuinfo` by parsing the `Serial` field:

```javascript
const DEVICE_ID = fs
  .readFileSync("/proc/cpuinfo", "utf8")
  .match(/Serial\s*:\s*(\w+)/)[1];
```

This is the Raspberry Pi's unique hardware serial number, making each device naturally identifiable without external provisioning databases.

### File Paths

| Path | Purpose |
|---|---|
| `cert/71cc32...certificate.pem.crt` | Claim certificate (bootstrap, deleted after provisioning) |
| `cert/71cc32...private.pem.key` | Claim private key (bootstrap, deleted after provisioning) |
| `cert/AmazonRootCA1.pem` | Root CA for TLS |
| `cert/device.pem` | Device-specific certificate (created during provisioning) |
| `cert/device.key` | Device-specific private key (created during provisioning) |
| `config/aws-device.json` | Registration response from AWS (thing name, config) |
| `log/provision.log` | Provisioning log file |

### Provisioning Flow

The script implements a two-step MQTT-based provisioning protocol:

```
┌─────────────┐                              ┌───────────────┐
│  Raspberry   │                              │  AWS IoT Core │
│     Pi       │                              │               │
└──────┬──────┘                              └───────┬───────┘
       │                                             │
       │  1. Connect (TLS mutual auth w/ claim cert) │
       │────────────────────────────────────────────▶│
       │                                             │
       │  2. Subscribe to response topics            │
       │────────────────────────────────────────────▶│
       │                                             │
       │  3. Publish to $aws/certificates/create/json│
       │────────────────────────────────────────────▶│
       │                                             │
       │  4. Receive new cert + key + ownership token│
       │◀────────────────────────────────────────────│
       │                                             │
       │  5. Save cert → device.pem, key → device.key│
       │                                             │
       │  6. Publish register request with token     │
       │     + DeviceId (Pi serial) + Version        │
       │────────────────────────────────────────────▶│
       │                                             │
       │  7. Receive registration accepted           │
       │◀────────────────────────────────────────────│
       │                                             │
       │  8. Save response → aws-device.json         │
       │  9. Delete claim cert + key                 │
       │ 10. Disconnect, exit 0                      │
       │                                             │
```

#### Step 1 — Certificate Creation

1. Connects to the MQTT broker using the claim certificate and key for mutual TLS authentication
2. Subscribes to four response topics (cert accepted/rejected, register accepted/rejected)
3. Publishes an empty JSON payload `{}` to `$aws/certificates/create/json`
4. On acceptance, receives and saves the new device certificate and private key to `cert/device.pem` and `cert/device.key`
5. Extracts the `certificateOwnershipToken` for the next step

#### Step 2 — Device Registration

1. Publishes to `$aws/provisioning-templates/templateProvisioning/provision/json` with:
   - `certificateOwnershipToken` — proves ownership of the newly created certificate
   - `parameters.DeviceId` — the Pi's hardware serial number
   - `parameters.Version` — firmware version (`1.0.0`)
2. On acceptance, saves the full registration response to `config/aws-device.json`
3. Deletes the claim certificate and private key (they are single-use bootstrap credentials)
4. Disconnects and exits with code 0

### MQTT Topics

| Topic | Direction | Purpose |
|---|---|---|
| `$aws/certificates/create/json` | Publish | Request new certificate |
| `$aws/certificates/create/json/accepted` | Subscribe | New cert + key + ownership token |
| `$aws/certificates/create/json/rejected` | Subscribe | Certificate creation failure |
| `$aws/provisioning-templates/templateProvisioning/provision/json` | Publish | Register device |
| `$aws/provisioning-templates/templateProvisioning/provision/json/accepted` | Subscribe | Registration success |
| `$aws/provisioning-templates/templateProvisioning/provision/json/rejected` | Subscribe | Registration failure |

### Error Handling

- **Payload decoding**: The `decodePayload` helper handles `Buffer`, `ArrayBuffer`, and `ArrayBufferView` types, falling back to `String()` coercion on any error.
- **Connection events**: Listens for `error` (logged), `interrupt` (logged), and `close` (triggers `process.exit`).
- **Timeout**: A 60-second `setTimeout` kills the process if provisioning hangs.
- **Exit codes**: `0` on success, `1` on any failure (rejection, timeout, unhandled error).
- **Claim credential cleanup failure**: Logged as a warning but does not prevent a successful exit — the device is already registered.
- **Log file initialization**: Creates the log directory and file if they don't exist; logs to both stdout and `log/provision.log`.

### Security Considerations

- **Claim credentials are ephemeral**: Deleted from the filesystem after successful provisioning, preventing reuse.
- **Claim certificates are shared**: All devices in a build batch share the same claim cert. The claim cert only has permission to call the provisioning API — it cannot publish/subscribe to application topics.
- **Device certificates are unique**: Each device gets its own certificate and private key, tied to its registered IoT Thing.
- **The claim cert hash** (`71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235`) is committed to the repo and baked into every Pi image. If compromised, it should be revoked in AWS IoT Core and a new claim cert generated.

### Post-Provisioning State

After a successful run, the filesystem looks like:

```
/usr/local/lib/eatabit/
├── bin/
│   └── iot-provision.js        # Still present (idempotent, won't re-run if device.pem exists)
├── cert/
│   ├── AmazonRootCA1.pem       # Retained (needed for ongoing MQTT connections)
│   ├── AmazonRootCA3.pem       # Retained
│   ├── device.pem              # NEW — device-specific certificate
│   └── device.key              # NEW — device-specific private key
├── config/
│   └── aws-device.json         # NEW — registration response (thing name, etc.)
└── log/
    └── provision.log           # Provisioning log
```

The claim certificate and key (`71cc32...-certificate.pem.crt` and `71cc32...-private.pem.key`) are deleted.
