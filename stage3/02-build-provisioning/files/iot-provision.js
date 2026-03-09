#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { mqtt, io, iot } = require("aws-iot-device-sdk-v2");

// Eatabit library directory
const EATABIT_ROOT_DIR = "/usr/local/lib/eatabit";

// Claim cert paths (bootstrap)
const EATABIT_CERT_PATH = `${EATABIT_ROOT_DIR}/cert`;
const CLAIM_CERT = `${EATABIT_CERT_PATH}/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt`;
const CLAIM_KEY = `${EATABIT_CERT_PATH}/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key`;
const ROOT_CA = `${EATABIT_CERT_PATH}/AmazonRootCA1.pem`;

const AWS_IOT_ENDPOINT = "a3fw1u2gvi2uac-ats.iot.us-east-2.amazonaws.com";
const TEMPLATE_NAME = "templateProvisioning";
const DEVICE_ID = fs
  .readFileSync("/proc/cpuinfo", "utf8")
  .match(/Serial\s*:\s*(\w+)/)[1]; // Pi serial
const VERSION = fs.readFileSync(`${EATABIT_ROOT_DIR}/version`, "utf8").trim();
const AWS_DEVICE_FILE = `${EATABIT_ROOT_DIR}/config/aws-device.json`;

const LOG_FILE = `${EATABIT_ROOT_DIR}/log/provision.log`;

// Topic shortcuts
const TOPIC_CERT_CREATE = "$aws/certificates/create/json";
const TOPIC_CERT_ACCEPTED = "$aws/certificates/create/json/accepted";
const TOPIC_CERT_REJECTED = "$aws/certificates/create/json/rejected";
const TOPIC_REGISTER = `$aws/provisioning-templates/${TEMPLATE_NAME}/provision/json`;
const TOPIC_REGISTER_ACCEPTED = `$aws/provisioning-templates/${TEMPLATE_NAME}/provision/json/accepted`;
const TOPIC_REGISTER_REJECTED = `$aws/provisioning-templates/${TEMPLATE_NAME}/provision/json/rejected`;

const TARGET_CERT_PATH = `${EATABIT_CERT_PATH}/device.pem`;
const TARGET_KEY_PATH = `${EATABIT_CERT_PATH}/device.key`;

// Ensure log directory and file exist
try {
  const logDir = path.dirname(LOG_FILE);
  if (!fs.existsSync(logDir)) {
    fs.mkdirSync(logDir, { recursive: true });
  }
  if (!fs.existsSync(LOG_FILE)) {
    fs.writeFileSync(LOG_FILE, "", { mode: 0o644 });
  }
} catch (err) {
  console.error(`Failed to initialize log file: ${err.message}`);
}

function log(message, level = "INFO") {
  const timestamp = new Date().toISOString().replace("T", " ").slice(0, 19);
  const line = `[${timestamp}] ${level}: ${message}\n`;
  console.log(line.trim());
  try {
    fs.appendFileSync(LOG_FILE, line);
  } catch (err) {
    console.error("Failed to write to log file:", err.message);
  }
}

log(`Starting provisioning with broker: ${AWS_IOT_ENDPOINT}`);

function decodePayload(payload) {
  try {
    if (Buffer.isBuffer(payload)) {
      return payload.toString("utf8");
    }
    if (payload instanceof ArrayBuffer) {
      return Buffer.from(payload).toString("utf8");
    }
    if (ArrayBuffer.isView(payload)) {
      return Buffer.from(
        payload.buffer,
        payload.byteOffset,
        payload.byteLength
      ).toString("utf8");
    }
    return String(payload);
  } catch {
    return String(payload);
  }
}

async function run() {
  const clientBootstrap = new io.ClientBootstrap();
  let provisioningSucceeded = false;

  const configBuilder =
    iot.AwsIotMqttConnectionConfigBuilder.new_mtls_builder_from_path(
      CLAIM_CERT,
      CLAIM_KEY
    );
  configBuilder.with_certificate_authority_from_path(undefined, ROOT_CA);
  configBuilder.with_endpoint(AWS_IOT_ENDPOINT);
  configBuilder.with_client_id(DEVICE_ID);
  configBuilder.with_clean_session(true);

  const config = configBuilder.build();
  const client = new mqtt.MqttClient(clientBootstrap);
  const connection = client.new_connection(config);

  let ownershipToken = null;

  connection.on("connect", async () => {
    log("Connected to AWS IoT Core");

    await connection.subscribe(TOPIC_CERT_ACCEPTED, mqtt.QoS.AtLeastOnce);
    await connection.subscribe(TOPIC_CERT_REJECTED, mqtt.QoS.AtLeastOnce);
    await connection.subscribe(TOPIC_REGISTER_ACCEPTED, mqtt.QoS.AtLeastOnce);
    await connection.subscribe(TOPIC_REGISTER_REJECTED, mqtt.QoS.AtLeastOnce);

    log("Subscribed to provisioning response topics");

    // Step 1: Request new keys and certificate
    await connection.publish(
      TOPIC_CERT_CREATE,
      JSON.stringify({}),
      mqtt.QoS.AtLeastOnce
    );
    log("Published certificate creation request");
  });

  connection.on("message", async (topic, payload) => {
    const message = decodePayload(payload);

    if (topic === TOPIC_CERT_ACCEPTED) {
      log("Certificate creation accepted");

      try {
        const data = JSON.parse(message);
        const certPem = data.certificatePem;
        const privateKey = data.privateKey;
        ownershipToken = data.certificateOwnershipToken;

        // Save certificate and key
        fs.writeFileSync(TARGET_CERT_PATH, certPem + "\n");
        fs.writeFileSync(TARGET_KEY_PATH, privateKey + "\n");

        log("New certificate and private key saved");

        // Step 2: Register the thing
        const registerPayload = {
          certificateOwnershipToken: ownershipToken,
          parameters: {
            DeviceId: DEVICE_ID,
            Version: VERSION,
          },
        };

        await connection.publish(
          TOPIC_REGISTER,
          JSON.stringify(registerPayload),
          mqtt.QoS.AtLeastOnce
        );
        log("Published device registration request");
      } catch (err) {
        log(`Failed to process certificate response: ${err.message}`, "ERROR");
      }
    } else if (topic === TOPIC_CERT_REJECTED) {
      log(`Certificate creation rejected: ${message}`, "ERROR");
      connection.disconnect();
    } else if (topic === TOPIC_REGISTER_ACCEPTED) {
      log("Device registration successful");

      // Save response
      fs.writeFileSync(AWS_DEVICE_FILE, message);
      log(`Registration response saved to ${AWS_DEVICE_FILE}`);

      // Delete claim certificate and key
      try {
        fs.unlinkSync(CLAIM_CERT);
        fs.unlinkSync(CLAIM_KEY);
        log("Claim certificate and key deleted");
      } catch (err) {
        log(`Warning: Failed to delete claim credentials: ${err.message}`, "WARN");
      }

      log("Provisioning completed successfully");
      provisioningSucceeded = true;
      connection.disconnect();
    } else if (topic === TOPIC_REGISTER_REJECTED) {
      log(`Device registration rejected: ${message}`, "ERROR");
      connection.disconnect();
    }
  });

  connection.on("error", (error) => {
    log(`Connection error: ${error.message}`, "ERROR");
  });

  connection.on("interrupt", () => {
    log("Connection interrupted");
  });

  connection.on("close", () => {
    log("Connection closed");
    process.exit(provisioningSucceeded ? 0 : 1);
  });

  // Timeout to prevent hanging indefinitely
  const PROVISION_TIMEOUT_MS = 60000;
  setTimeout(() => {
    log("Provisioning timed out after 60 seconds", "ERROR");
    process.exit(1);
  }, PROVISION_TIMEOUT_MS);

  await connection.connect();
}

// Run and handle unhandled errors
run().catch((err) => {
  log(`Unexpected error: ${err.message}`, "ERROR");
  process.exit(1);
});
