#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { mqtt, io, iot } = require("aws-iot-device-sdk-v2");

// Configuration
const EATABIT_DIR = "/usr/local/lib/eatabit";
const CERT_PATH = `${EATABIT_DIR}/cert`;
const DEVICE_CERT = `${CERT_PATH}/device.pem`;
const DEVICE_KEY = `${CERT_PATH}/device.key`;
const ROOT_CA = `${CERT_PATH}/AmazonRootCA1.pem`;
const ENDPOINT = "a3fw1u2gvi2uac-ats.iot.us-east-2.amazonaws.com";
const LOG_FILE = `${EATABIT_DIR}/log/eatabit-service.log`;

// Ensure log directory and file exist
function initializeLogFile() {
  try {
    const logDir = path.dirname(LOG_FILE);
    if (!fs.existsSync(logDir)) {
      fs.mkdirSync(logDir, { recursive: true, mode: 0o777 });
    }
    if (!fs.existsSync(LOG_FILE)) {
      fs.writeFileSync(LOG_FILE, "", { mode: 0o666 });
    }
  } catch (err) {
    console.error(`Failed to initialize log file: ${err.message}`);
  }
}

// Log function that writes to both console and file
function log(message, level = "INFO") {
  const timestamp = new Date().toISOString().replace("T", " ").slice(0, 23);
  const line = `[${timestamp}] [${level}] ${message}\n`;

  // Write to console
  if (level === "ERROR" || level === "FATAL") {
    console.error(line.trim());
  } else {
    console.log(line.trim());
  }

  // Write to file
  try {
    fs.appendFileSync(LOG_FILE, line);
  } catch (err) {
    console.error(`Failed to write to log file: ${err.message}`);
  }
}

// Initialize logging
initializeLogFile();

// Read device ID from file
let DEVICE_ID;
try {
  DEVICE_ID = fs.readFileSync(`${EATABIT_DIR}/deviceid`, "utf8").trim();
  if (!DEVICE_ID) {
    throw new Error("Device ID file is empty");
  }
} catch (err) {
  log(`Failed to read device ID: ${err.message}`, "ERROR");
  process.exit(1);
}

// Job topics (inbound)
const JOB_TOPICS = [
  `$aws/things/${DEVICE_ID}/jobs/notify`,
  `$aws/things/${DEVICE_ID}/jobs/get`,
  `$aws/things/${DEVICE_ID}/jobs/get/accepted`,
  `$aws/things/${DEVICE_ID}/jobs/get/rejected`,
  `$aws/things/${DEVICE_ID}/jobs/+/get`,
  `$aws/things/${DEVICE_ID}/jobs/+/get/accepted`,
  `$aws/things/${DEVICE_ID}/jobs/+/update`,
];

// Events topic (outbound)
const EVENTS_TOPIC = `eatabit/things/${DEVICE_ID}/events`;

log(`Starting Eatabit AWS IoT Client for device: ${DEVICE_ID}`);

// Global connection reference for publishing
let mqttConnection;

// Helper function to publish events
async function publishEvent(eventType, eventData) {
  if (!mqttConnection) {
    log("Cannot publish event: MQTT connection not established", "ERROR");
    return;
  }

  try {
    const payload = JSON.stringify({
      deviceId: DEVICE_ID,
      timestamp: new Date().toISOString(),
      eventType,
      data: eventData,
    });

    await mqttConnection.publish(EVENTS_TOPIC, payload, mqtt.QoS.AtLeastOnce);
    log(`Published event: ${eventType} to ${EVENTS_TOPIC}`);
  } catch (err) {
    log(`Failed to publish event: ${err.message}`, "ERROR");
  }
}

async function main() {
  const clientBootstrap = new io.ClientBootstrap();

  const configBuilder =
    iot.AwsIotMqttConnectionConfigBuilder.new_mtls_builder_from_path(
      DEVICE_CERT,
      DEVICE_KEY
    );

  configBuilder.with_certificate_authority_from_path(undefined, ROOT_CA);
  configBuilder.with_endpoint(ENDPOINT);
  configBuilder.with_client_id(DEVICE_ID);
  configBuilder.with_clean_session(false);
  configBuilder.with_keep_alive_seconds(30);

  const config = configBuilder.build();
  const client = new mqtt.MqttClient(clientBootstrap);
  const connection = client.new_connection(config);

  // Store connection globally for publishing
  mqttConnection = connection;

  // Connection event handlers
  connection.on("connect", async () => {
    log("Connected to AWS IoT Core");
    // Publish connection event
    await publishEvent("connected", { status: "online" });
  });

  connection.on("interrupt", (error) => {
    log(`Connection interrupted: ${error}`, "WARN");
  });

  connection.on("resume", (return_code, session_present) => {
    log(
      `Connection resumed. Return code: ${return_code}, Session present: ${session_present}`
    );
  });

  connection.on("disconnect", () => {
    log("Disconnected from AWS IoT Core");
  });

  connection.on("error", (error) => {
    log(`Connection error: ${error}`, "ERROR");
  });

  // Message handler
  connection.on("message", (topic, payload) => {
    try {
      const message = Buffer.from(payload).toString("utf8");
      log(`Received message on topic: ${topic}`);
      log(`Message: ${message}`);

      // Parse and handle job notification
      const data = JSON.parse(message);

      // Handle job notifications
      if (topic.includes("/jobs/notify")) {
        if (data.jobs && data.jobs.length > 0) {
          log(`Active jobs: ${data.jobs.length}`);
          data.jobs.forEach((job) => {
            log(`Job ID: ${job.jobId}, Status: ${job.status}`);
          });
        }
      }

      // Handle job get responses
      if (topic.includes("/jobs/get/accepted")) {
        if (data.inProgressJobs && data.inProgressJobs.length > 0) {
          log(`In-progress jobs: ${data.inProgressJobs.length}`);
        }
        if (data.queuedJobs && data.queuedJobs.length > 0) {
          log(`Queued jobs: ${data.queuedJobs.length}`);
        }
      }

      // Handle job get rejected
      if (topic.includes("/jobs/get/rejected")) {
        log(`Job get rejected: ${JSON.stringify(data)}`, "ERROR");
      }
    } catch (err) {
      log(`Failed to process message: ${err.message}`, "ERROR");
    }
  });

  try {
    // Connect to AWS IoT
    log(`Connecting to ${ENDPOINT}...`);
    await connection.connect();

    // Subscribe to all job topics
    for (const topic of JOB_TOPICS) {
      log(`Subscribing to ${topic}`);
      await connection.subscribe(topic, mqtt.QoS.AtLeastOnce);
    }
    log("Successfully subscribed to all job topics");

    // Keep the connection alive
    await new Promise((resolve) => {
      process.on("SIGINT", async () => {
        log("Received SIGINT, disconnecting...");
        await publishEvent("disconnected", { reason: "SIGINT" });
        await connection.disconnect();
        resolve();
      });

      process.on("SIGTERM", async () => {
        log("Received SIGTERM, disconnecting...");
        await publishEvent("disconnected", { reason: "SIGTERM" });
        await connection.disconnect();
        resolve();
      });
    });
  } catch (error) {
    log(error.message, "ERROR");
    process.exit(1);
  }
}

main().catch((err) => {
  log(err.message, "FATAL");
  process.exit(1);
});
