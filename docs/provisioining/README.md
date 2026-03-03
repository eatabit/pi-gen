# IoT Fleet Provisioning

## Overview

Eatabit uses [AWS IoT Fleet Provisioning by Claim](https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html) to automatically register Raspberry Pi devices with AWS IoT Core on first boot. Every device ships with a shared **claim certificate** baked into the OS image. On first run, the device exchanges this claim certificate for a unique device certificate, registers as an IoT Thing, and deletes the claim credentials.

## Architecture

```
Raspberry Pi (first boot)
│
│  iot-provision.js connects via MQTT using claim certificate
│
├─→ $aws/certificates/create/json
│     AWS IoT Core generates a new certificate + private key
│     ← $aws/certificates/create/json/accepted
│
├─→ $aws/provisioning-templates/templateProvisioning/provision/json
│     Sends { certificateOwnershipToken, parameters: { DeviceId, Version } }
│     │
│     ├─→ Pre-provisioning hook Lambda (provisioningHook)
│     │     Validates request, publishes thing.provisioned event to EventBridge
│     │     Returns { allowProvisioning: true }
│     │
│     ├─→ AWS IoT Core creates:
│     │     - IoT Thing (ThingName = DeviceId)
│     │     - Activates certificate
│     │     - Attaches policyConnect to certificate
│     │
│     ← $aws/provisioning-templates/templateProvisioning/provision/json/accepted
│
├─→ Device saves device certificate, deletes claim certificate
│
└─→ EventBridge: thing.provisioned
      │
      ├─→ onThingProvisioned-createDevice Lambda
      │     Creates Device record in DynamoDB via AppSync
      │     │
      │     └─→ DynamoDB Stream publishes device.created event
      │           │
      │           ├─→ updateShadow — Sets apiId in Thing's private shadow
      │           ├─→ createDefaultPrinter — Creates default Printer record
      │           └─→ createEvent — Records provisioning event
```

## Device-Side: `iot-provision.js`

**Location:** `iot-pi/stage3/02-build-provisioning/files/iot-provision.js`
**Installed to:** `/usr/local/lib/eatabit/bin/iot-provision.js`

### How It Works

The provisioning script uses the `aws-iot-device-sdk-v2` MQTT client to perform a two-step provisioning flow:

#### Step 1: Request a New Certificate

1. Connects to AWS IoT Core (`a3fw1u2gvi2uac-ats.iot.us-east-2.amazonaws.com`) using the shared claim certificate and private key
2. Uses the Raspberry Pi's CPU serial number from `/proc/cpuinfo` as the `DeviceId` (client ID)
3. Subscribes to accepted/rejected response topics for both certificate creation and registration
4. Publishes an empty JSON payload `{}` to `$aws/certificates/create/json`
5. On `accepted`: receives `certificatePem`, `privateKey`, and `certificateOwnershipToken`
6. Saves the new certificate to `/usr/local/lib/eatabit/cert/device.pem`
7. Saves the new private key to `/usr/local/lib/eatabit/cert/device.key`

#### Step 2: Register the Thing

1. Publishes a registration request to `$aws/provisioning-templates/templateProvisioning/provision/json` with:
   ```json
   {
     "certificateOwnershipToken": "<token from step 1>",
     "parameters": {
       "DeviceId": "<Pi CPU serial>",
       "Version": "1.0.0"
     }
   }
   ```
2. On `accepted`: saves the registration response to `/usr/local/lib/eatabit/config/aws-device.json`
3. Deletes the claim certificate and private key (one-time use)
4. Disconnects and exits with code `0`

### Error Handling

- 60-second timeout prevents the script from hanging indefinitely
- Rejected certificate or registration causes immediate disconnect and exit code `1`
- Connection errors and interrupts are logged
- All activity is logged to `/usr/local/lib/eatabit/log/provision.log`

### MQTT Topics

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `$aws/certificates/create/json` | Publish | Request new certificate |
| `$aws/certificates/create/json/accepted` | Subscribe | Receive certificate + key |
| `$aws/certificates/create/json/rejected` | Subscribe | Certificate creation failure |
| `$aws/provisioning-templates/templateProvisioning/provision/json` | Publish | Register Thing |
| `$aws/provisioning-templates/templateProvisioning/provision/json/accepted` | Subscribe | Registration success |
| `$aws/provisioning-templates/templateProvisioning/provision/json/rejected` | Subscribe | Registration failure |

## OS Image Build: Certificate Installation

**Location:** `iot-pi/stage3/02-build-provisioning/00-run.sh`

The pi-gen build script installs the following files into the OS image:

| Source File | Destination | Purpose |
|-------------|-------------|---------|
| `AmazonRootCA1.pem` | `/usr/local/lib/eatabit/cert/` | AWS root CA certificate |
| `AmazonRootCA3.pem` | `/usr/local/lib/eatabit/cert/` | AWS root CA certificate (ECC) |
| `71cc32...certificate.pem.crt` | `/usr/local/lib/eatabit/cert/` | Shared claim certificate |
| `71cc32...private.pem.key` | `/usr/local/lib/eatabit/cert/` | Shared claim private key |
| `iot-provision.js` | `/usr/local/lib/eatabit/bin/` | Provisioning script |

The directory structure is created by `iot-pi/stage3/01-create-eatabit-lib/00-run.sh`:

```
/usr/local/lib/eatabit/
├── bin/          # Scripts (iot-provision.js, iot-mqtt-client.js)
├── cert/         # Certificates (claim cert → device cert after provisioning)
├── config/       # AWS device config (aws-device.json, written during provisioning)
├── log/          # Log files (provision.log, mqtt-client.log)
└── version       # OS image version
```

## Cloud Infrastructure

### Provisioning Template

**Location:** `iot-backend/stacks/iot/resources/templates/provisioning.ts`

The CDK stack creates a `CfnProvisioningTemplate` named `templateProvisioning` that defines what AWS IoT Core creates when a device registers:

#### Template Parameters

| Parameter | Type | Source |
|-----------|------|--------|
| `DeviceId` | String | Pi CPU serial number |
| `Version` | String | Provisioning script version |

#### Resources Created by the Template

1. **Certificate** — Activates the certificate created in Step 1 (`AWS::IoT::Certificate`)
2. **Policy** — Attaches `policyConnect` to the certificate (`AWS::IoT::Policy`)
3. **Thing** — Creates an IoT Thing with `ThingName = DeviceId` and `Version` attribute (`AWS::IoT::Thing`)

#### IAM Role

The template uses `roleProvisioning` with the `AWSIoTThingsRegistration` managed policy, which grants AWS IoT Core permission to create Things, certificates, and policies during provisioning.

### IoT Policies

#### `policyFleetProvisioning` (Claim Certificate)

Attached to the shared claim certificate. Restricts claim certificates to only provisioning operations:

- **Connect** — Allow connecting with any client ID
- **Publish/Receive** — `$aws/certificates/create/*` and `$aws/provisioning-templates/templateProvisioning/provision/*`
- **Subscribe** — Same topic filters as Publish/Receive

#### `policyConnect` (Device Certificate)

Attached to each device's unique certificate after provisioning. Grants operational permissions scoped to the Thing name:

- **Connect** — `iot:Connect` scoped to `client/${ThingName}`
- **Subscribe** — `$aws/**/${ThingName}/*`, Thing shadows (public + private)
- **Receive** — Same topics as Subscribe
- **Publish** — `$aws/**/${ThingName}/*`, `eatabit/things/${ThingName}/events`, `eatabit/things/${ThingName}/jobs/*`, Thing shadows (public + private)

### Pre-Provisioning Hook

**Location:** `iot-backend/stacks/iot/resources/functions/provisioningHook/`

A Lambda function invoked by AWS IoT Core before completing provisioning. It:

1. Receives `{ clientId, certificateId }` from IoT Core
2. Publishes a `thing.provisioned` event to EventBridge with the `clientId` and `certificateId`
3. Returns `{ allowProvisioning: true }` to approve the provisioning

The Lambda has permissions for CloudWatch Logs and EventBridge `PutEvents`. It is invoked by the `iot.amazonaws.com` service principal.

## Downstream Event Processing

When the `thing.provisioned` event is published to EventBridge, it triggers the following chain:

### 1. Create Device Record

**Lambda:** `onThingProvisioned-createDevice`
**Trigger:** EventBridge rule matching `source: "iot"`, `detailType: "thing.provisioned"`

- Receives `clientId` (hardware ID) and `certificateId`
- Checks for existing Device with the same `hardwareId` (idempotent)
- Creates a Device record in DynamoDB via AppSync GraphQL with:
  - `hardwareId` = clientId
  - `certificateId` in metadata
  - `thingArn`
  - `hardwareVersion: 20`
  - `enabled: true`

### 2. DynamoDB Stream → `device.created` Event

The Device table's DynamoDB stream detects the INSERT and publishes a `device.created` event, triggering three parallel consumers:

| Consumer | Purpose |
|----------|---------|
| **updateShadow** | Sets `apiId` (Device record ID) in the Thing's private named shadow so the device knows its API identity |
| **createDefaultPrinter** | Creates a default Printer record associated with the Device, including a unique email and default job template |
| **createEvent** | Records the provisioning event in the Event table for audit/history |

## File Reference

| File | Purpose |
|------|---------|
| `iot-pi/stage3/01-create-eatabit-lib/00-run.sh` | Creates `/usr/local/lib/eatabit/` directory structure |
| `iot-pi/stage3/02-build-provisioning/00-run.sh` | Installs certificates and provisioning script |
| `iot-pi/stage3/02-build-provisioning/files/iot-provision.js` | Device-side provisioning script |
| `iot-backend/stacks/iot/resources/templates/provisioning.ts` | CDK provisioning template and IoT policies |
| `iot-backend/stacks/iot/resources/functions/provisioningHook/lambda.ts` | Pre-provisioning hook Lambda construct |
| `iot-backend/stacks/iot/resources/functions/provisioningHook/src/index.ts` | Pre-provisioning hook handler |
| `iot-constants/src/constants/iot.ts` | IoT event constants (`thing.provisioned`, `SOURCE`) |

## Security Considerations

- **Claim certificate is single-use per device** — deleted after successful provisioning, preventing reuse
- **Device certificates are unique** — each device gets its own certificate and private key
- **Policy scoping** — `policyConnect` restricts device operations to topics containing their own Thing name
- **Pre-provisioning hook** — all provisioning requests pass through the Lambda for validation and audit
- **60-second timeout** — prevents provisioning script from hanging indefinitely
