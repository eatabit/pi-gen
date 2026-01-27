#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { mqtt, io, iot } = require("aws-iot-device-sdk-v2");
const { execSync } = require("child_process");
const ngrok = require("@ngrok/ngrok");

// Configuration
const EATABIT_DIR = "/usr/local/lib/eatabit";
const CERT_PATH = `${EATABIT_DIR}/cert`;
const DEVICE_CERT = `${CERT_PATH}/device.pem`;
const DEVICE_KEY = `${CERT_PATH}/device.key`;
const ROOT_CA = `${CERT_PATH}/AmazonRootCA1.pem`;
const ENDPOINT = "a3fw1u2gvi2uac-ats.iot.us-east-2.amazonaws.com";
const LOG_FILE = `${EATABIT_DIR}/log/mqtt-client.log`;
const JOBS_DIR = "/tmp";
const HEALTH_JSON_PATH = "/usr/local/lib/eatabit/health.json";
const DEVICE_READY_ESCPOS = `${EATABIT_DIR}/escpos/deviceReady.escpos`;

// Job statuses
JOB_EXECUTION_STATUSES = {
  IN_PROGRESS: "IN_PROGRESS",
  SUCCEEDED: "SUCCEEDED",
  FAILED: "FAILED", // Can be retried
  REJECTED: "REJECTED", // Cannot be retried
};

// Job events
JOB_EVENTS = {
  QUEUED: "QUEUED",
  DOWNLOADED: "DOWNLOADED",
  PRINTED: "PRINTED",
  EXPIRED: "EXPIRED",
  PRINTER_OFFLINE: "PRINTER_OFFLINE",
};

// Printer events
PRINTER_EVENTS = {
  POWERED_OFF: "POWERED_OFF",
  COVER_OPEN: "COVER_OPEN",
  OUT_OF_PAPER: "OUT_OF_PAPER",
  MECHANICAL_ERROR: "MECHANICAL_ERROR",
};

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

// MQTT topics
const TOPIC_PREFIX = `$aws/things/${DEVICE_ID}`;

// Shadow topics (outbound)
const PUBLIC_SHADOW_PREFIX = `${TOPIC_PREFIX}/shadow/name/public`;
const PRIVATE_SHADOW_PREFIX = `${TOPIC_PREFIX}/shadow/name/private`;

// Shadow configuration
const SHADOW_CONFIG = {
  public: {
    name: "public",
    properties: ["light", "volume", "cutterType"],
    state: {
      light: false,
      volume: 4, // 0=off, 1-8=volume level
      cutterType: "partial", // "partial" (default), "full", or "none"
    },
  },
  private: {
    name: "private",
    properties: ["apiId"],
    state: {
      apiId: "",
    },
  },
};

// Config file paths
const CUTTER_CONFIG_FILE = `${EATABIT_DIR}/config/cutter-type.json`;
const VOLUME_CONFIG_FILE = `${EATABIT_DIR}/config/volume.json`;
const LIGHT_CONFIG_FILE = `${EATABIT_DIR}/config/light.json`;

/**
 * Load local device config files into SHADOW_CONFIG.public.state
 * This makes the device config the source of truth for the public shadow
 */
function loadLocalPublicShadowConfig() {
  // Load cutter type
  try {
    if (fs.existsSync(CUTTER_CONFIG_FILE)) {
      const data = JSON.parse(fs.readFileSync(CUTTER_CONFIG_FILE, "utf8"));
      if (
        data.cutterType &&
        ["partial", "full", "none"].includes(data.cutterType)
      ) {
        SHADOW_CONFIG.public.state.cutterType = data.cutterType;
        log(`Loaded cutterType from local config: ${data.cutterType}`);
      }
    }
  } catch (err) {
    log(`Failed to load cutter config: ${err.message}`, "ERROR");
  }

  // Load volume setting
  try {
    if (fs.existsSync(VOLUME_CONFIG_FILE)) {
      const data = JSON.parse(fs.readFileSync(VOLUME_CONFIG_FILE, "utf8"));
      if (
        typeof data.volume === "number" &&
        data.volume >= 0 &&
        data.volume <= 8
      ) {
        SHADOW_CONFIG.public.state.volume = data.volume;
        log(`Loaded volume from local config: ${data.volume}`);
      }
    }
  } catch (err) {
    log(`Failed to load volume config: ${err.message}`, "ERROR");
  }

  // Load light setting
  try {
    if (fs.existsSync(LIGHT_CONFIG_FILE)) {
      const data = JSON.parse(fs.readFileSync(LIGHT_CONFIG_FILE, "utf8"));
      if (typeof data.light === "boolean") {
        SHADOW_CONFIG.public.state.light = data.light;
        log(`Loaded light from local config: ${data.light}`);
      }
    }
  } catch (err) {
    log(`Failed to load light config: ${err.message}`, "ERROR");
  }

  log(
    `Local public shadow config loaded: ${JSON.stringify(SHADOW_CONFIG.public.state)}`,
  );
}

// ESC/POS Volume Commands (from iot-doc/ESCPOS/Custom Speaker Commands.md)
// Volume: 0=off, 1-8=volume level

// Unlock parameters command
const UNLOCK_PARAMS_CMD = Buffer.from([
  0x1b, 0x1c, 0x26, 0x20, 0x56, 0x31, 0x20, 0x64, 0x6f, 0x20, 0x22, 0x75, 0x6e,
  0x6c, 0x6f, 0x63, 0x6b, 0x5f, 0x70, 0x61, 0x72, 0x61, 0x22, 0x0d, 0x0a,
]);

// Additional speaker config command
const SPEAKER_CONFIG_CMD = Buffer.from([
  0x1b, 0x1c, 0x26, 0x20, 0x56, 0x31, 0x20, 0x73, 0x65, 0x74, 0x6b, 0x65, 0x79,
  0x0d, 0x0a, 0x00, 0x92, 0x01, 0x01, 0x00,
]);

// Save parameter zone command
const SAVE_PARAMS_CMD = Buffer.from([
  0x1b, 0x1c, 0x26, 0x20, 0x56, 0x31, 0x20, 0x64, 0x6f, 0x20, 0x22, 0x73, 0x61,
  0x76, 0x65, 0x5f, 0x70, 0x61, 0x72, 0x61, 0x5f, 0x7a, 0x6f, 0x6e, 0x65, 0x22,
  0x0d, 0x0a,
]);

// Reset printer command (required after speaker ON/OFF changes)
const RESET_PRINTER_CMD = Buffer.from([
  0x1b, 0x1c, 0x26, 0x20, 0x56, 0x31, 0x20, 0x64, 0x6f, 0x20, 0x22, 0x72, 0x65,
  0x73, 0x65, 0x74, 0x5f, 0x70, 0x72, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x22, 0x0d,
  0x0a,
]);

/**
 * Generate ESC/POS commands for setting volume
 * @param {number} volume - Volume level 0-8 (0=off, 1-8=volume)
 * @returns {Buffer[]} Array of command buffers
 */
function getVolumeCommands(volume) {
  const commands = [UNLOCK_PARAMS_CMD];

  if (volume === 0) {
    // Speaker OFF
    commands.push(
      Buffer.from([
        0x1b, 0x1c, 0x26, 0x20, 0x56, 0x31, 0x20, 0x73, 0x65, 0x74, 0x6b, 0x65,
        0x79, 0x0d, 0x0a, 0x00, 0xee, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00,
      ]),
    );
  } else {
    // Speaker ON
    commands.push(
      Buffer.from([
        0x1b, 0x1c, 0x26, 0x20, 0x56, 0x31, 0x20, 0x73, 0x65, 0x74, 0x6b, 0x65,
        0x79, 0x0d, 0x0a, 0x00, 0xee, 0x01, 0x04, 0x01, 0x00, 0x00, 0x00,
      ]),
    );
    // Set volume level (1-8)
    commands.push(
      Buffer.from([
        0x1b,
        0x1c,
        0x26,
        0x20,
        0x56,
        0x31,
        0x20,
        0x73,
        0x65,
        0x74,
        0x6b,
        0x65,
        0x79,
        0x0d,
        0x0a,
        0x00,
        0xef,
        0x01,
        0x01,
        volume,
      ]),
    );
  }

  commands.push(SPEAKER_CONFIG_CMD);
  commands.push(SAVE_PARAMS_CMD);
  commands.push(RESET_PRINTER_CMD);

  return commands;
}

/**
 * Execute ESC/POS volume command to set printer speaker volume
 * @param {number} volume - Volume level 0-8 (0=off, 1-8=volume)
 */
function executeVolumeCommand(volume) {
  try {
    const commands = getVolumeCommands(volume);
    for (const cmd of commands) {
      fs.writeFileSync("/dev/usb/lp0", cmd);
    }
    log(`Volume set to ${volume} via ESC/POS commands`);
  } catch (err) {
    log(`Failed to execute volume command: ${err.message}`, "ERROR");
  }
}

/**
 * Watch cutter config file for changes (from BLE service)
 * When the file changes, update the shadow with the new value
 */
function watchCutterConfigFile() {
  const configDir = path.dirname(CUTTER_CONFIG_FILE);

  // Ensure config directory exists
  if (!fs.existsSync(configDir)) {
    fs.mkdirSync(configDir, { recursive: true, mode: 0o777 });
  }

  // Debounce to prevent multiple triggers
  let debounceTimer = null;

  fs.watch(configDir, (eventType, filename) => {
    if (filename === path.basename(CUTTER_CONFIG_FILE)) {
      // Debounce file change events
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(async () => {
        try {
          if (!fs.existsSync(CUTTER_CONFIG_FILE)) return;

          const data = JSON.parse(fs.readFileSync(CUTTER_CONFIG_FILE, "utf8"));
          if (
            data.cutterType &&
            ["partial", "full", "none"].includes(data.cutterType)
          ) {
            const currentValue = SHADOW_CONFIG.public.state.cutterType;
            if (data.cutterType !== currentValue) {
              log(
                `Cutter config file changed: ${currentValue} -> ${data.cutterType}`,
              );
              SHADOW_CONFIG.public.state.cutterType = data.cutterType;
              await updateShadowReportedState("public");
            }
          }
        } catch (err) {
          log(
            `Failed to process cutter config change: ${err.message}`,
            "ERROR",
          );
        }
      }, 100);
    }
  });

  log("Watching cutter config file for changes");
}

/**
 * Watch volume config file for changes (from BLE service)
 * When the file changes, update the shadow with the new value and execute ESC/POS command
 */
function watchVolumeConfigFile() {
  const configDir = path.dirname(VOLUME_CONFIG_FILE);

  // Ensure config directory exists
  if (!fs.existsSync(configDir)) {
    fs.mkdirSync(configDir, { recursive: true, mode: 0o777 });
  }

  // Debounce to prevent multiple triggers
  let debounceTimer = null;

  fs.watch(configDir, (eventType, filename) => {
    if (filename === path.basename(VOLUME_CONFIG_FILE)) {
      // Debounce file change events
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(async () => {
        try {
          if (!fs.existsSync(VOLUME_CONFIG_FILE)) return;

          const data = JSON.parse(fs.readFileSync(VOLUME_CONFIG_FILE, "utf8"));
          if (
            typeof data.volume === "number" &&
            data.volume >= 0 &&
            data.volume <= 8
          ) {
            const currentValue = SHADOW_CONFIG.public.state.volume;
            if (data.volume !== currentValue) {
              log(
                `Volume config file changed: ${currentValue} -> ${data.volume}`,
              );
              SHADOW_CONFIG.public.state.volume = data.volume;

              // Execute ESC/POS command to change printer volume
              executeVolumeCommand(data.volume);

              await updateShadowReportedState("public");
            }
          }
        } catch (err) {
          log(
            `Failed to process volume config change: ${err.message}`,
            "ERROR",
          );
        }
      }, 100);
    }
  });

  log("Watching volume config file for changes");
}

// Job topics (inbound)
const SUBSCRIBE_TOPICS = [
  `${TOPIC_PREFIX}/jobs/notify-next`,
  `${TOPIC_PREFIX}/jobs/start-next/accepted`,
  `${TOPIC_PREFIX}/jobs/start-next/rejected`,
  `${TOPIC_PREFIX}/jobs/+/update`,
  `${TOPIC_PREFIX}/jobs/+/update/accepted`,
  `${TOPIC_PREFIX}/jobs/+/update/rejected`,
  `$aws/commands/things/${DEVICE_ID}/executions/+/request/json`,
  // Shadow delta topics
  `${PUBLIC_SHADOW_PREFIX}/update/delta`,
  `${PRIVATE_SHADOW_PREFIX}/update/delta`,
];

// Events topic (outbound)
const EVENTS_TOPIC = `eatabit/things/${DEVICE_ID}/events`;

log(`Starting Eatabit AWS IoT Client for device: ${DEVICE_ID}`);

// Global connection reference for publishing
let mqttConnection;

// Global ngrok listener reference
let ngrokListener = null;

// Flag to track if device ready receipt has been printed (once per power cycle)
let hasDeviceReadyPrinted = false;

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

// Helper function to publish health data from health.json file
async function publishHealthData() {
  if (!mqttConnection) {
    log("Cannot publish health data: MQTT connection not established", "ERROR");
    return;
  }

  try {
    // Read health JSON file
    if (!fs.existsSync(HEALTH_JSON_PATH)) {
      log(`Health data file not found at ${HEALTH_JSON_PATH}`, "WARN");
      await publishEvent("health_data_error", {
        error: "Health data file not found",
        path: HEALTH_JSON_PATH,
      });
      return;
    }

    const healthContent = fs.readFileSync(HEALTH_JSON_PATH, "utf8");
    const healthData = JSON.parse(healthContent);

    // Publish health data as event
    const payload = JSON.stringify({
      deviceId: DEVICE_ID,
      timestamp: new Date().toISOString(),
      eventType: "health_report",
      data: healthData,
    });

    await mqttConnection.publish(EVENTS_TOPIC, payload, mqtt.QoS.AtLeastOnce);
    log(`Published health data to ${EVENTS_TOPIC}`);
  } catch (err) {
    log(`Failed to publish health data: ${err.message}`, "ERROR");
    await publishEvent("health_data_error", {
      error: err.message,
      path: HEALTH_JSON_PATH,
    });
  }
}

// Helper function to test if a job has expired
function isJobExpired(expiresAt) {
  return Number(expiresAt) < Math.floor(Date.now() / 1000);
}

// Helper function to persist shadow state to file
function persistShadowToFile(shadowName) {
  try {
    const shadowConfig = SHADOW_CONFIG[shadowName];
    if (!shadowConfig) {
      log(`Unknown shadow: ${shadowName}`, "ERROR");
      return;
    }

    const configDir = "/usr/local/lib/eatabit/config";
    const fileName = `shadow-${shadowName}.json`;
    const filePath = `${configDir}/${fileName}`;

    // Ensure directory exists
    if (!fs.existsSync(configDir)) {
      fs.mkdirSync(configDir, { recursive: true, mode: 0o777 });
    }

    // Write shadow state to file
    const stateData = JSON.stringify(
      {
        shadowName,
        timestamp: new Date().toISOString(),
        state: shadowConfig.state,
      },
      null,
      2,
    );

    fs.writeFileSync(filePath, stateData, { mode: 0o666 });
    log(`Persisted ${shadowName} shadow to ${filePath}`);
  } catch (err) {
    log(`Failed to persist shadow to file: ${err.message}`, "ERROR");
  }
}

// Helper function to update shadow reported state
async function updateShadowReportedState(shadowName) {
  if (!mqttConnection) {
    log("Cannot update shadow: MQTT connection not established", "ERROR");
    return;
  }

  try {
    const shadowConfig = SHADOW_CONFIG[shadowName];
    if (!shadowConfig) {
      log(`Unknown shadow: ${shadowName}`, "ERROR");
      return;
    }

    const reportedState = shadowConfig.state;
    const payload = JSON.stringify({
      state: {
        reported: reportedState,
      },
    });

    const topic = `${TOPIC_PREFIX}/shadow/name/${shadowName}/update`;
    await mqttConnection.publish(topic, payload, mqtt.QoS.AtLeastOnce);
    log(`Published reported state to shadow: ${shadowName}`);

    // Persist shadow state to file
    persistShadowToFile(shadowName);
  } catch (err) {
    log(`Failed to update shadow state: ${err.message}`, "ERROR");
  }
}

// Helper function to handle shadow delta updates
async function handleShadowDelta(shadowName, desiredState) {
  try {
    const shadowConfig = SHADOW_CONFIG[shadowName];
    if (!shadowConfig) {
      log(`Unknown shadow: ${shadowName}`, "ERROR");
      return;
    }

    log(`Processing delta for ${shadowName} shadow:`, "INFO");
    log(JSON.stringify(desiredState), "INFO");

    // Update local state with desired state
    shadowConfig.properties.forEach((prop) => {
      if (desiredState.hasOwnProperty(prop)) {
        shadowConfig.state[prop] = desiredState[prop];
        log(`Updated ${shadowName}.${prop} = ${desiredState[prop]}`, "INFO");

        // Handle property-specific actions
        if (shadowName === "public") {
          if (prop === "light") {
            log(`Light ${desiredState[prop] ? "enabled" : "disabled"}`);
            // TODO: Implement light control (e.g., GPIO, LED)
          }
          if (prop === "volume") {
            log(`Volume set to: ${desiredState[prop]}`);
            // Execute ESC/POS command to change printer volume
            executeVolumeCommand(desiredState[prop]);
          }
          if (prop === "cutterType") {
            log(`Cutter type set to: ${desiredState[prop]}`);
            // Shadow reported state is updated via updateShadowReportedState() below
            // Config file is only written by BLE service, not cloud-initiated changes
          }
        } else if (shadowName === "private") {
          if (prop === "apiId") {
            log(`API ID configured: ${desiredState[prop]}`);
            // TODO: Store apiId for API authentication
          }
        }
      }
    });

    // Report updated state back to shadow
    await updateShadowReportedState(shadowName);

    // Persist shadow state to file
    persistShadowToFile(shadowName);
  } catch (err) {
    log(`Failed to handle shadow delta: ${err.message}`, "ERROR");
  }
}

// Printer status check
function checkPrinterStatus() {
  try {
    // Check if printer device exists (printer must be powered on and connected)
    if (!fs.existsSync("/dev/usb/lp0")) {
      return { ready: false, reason: PRINTER_EVENTS.POWERED_OFF };
    }

    const onlineStatus = execSync(
      `printf "\\x10\\x04\\x01" > /dev/usb/lp0 && timeout 1s dd if=/dev/usb/lp0 bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" },
    ).trim();

    const offlineCause = execSync(
      `printf "\\x10\\x04\\x02" > /dev/usb/lp0 && timeout 1s dd if=/dev/usb/lp0 bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" },
    ).trim();

    const paperStatus = execSync(
      `printf "\\x10\\x04\\x04" > /dev/usb/lp0 && timeout 1s dd if=/dev/usb/lp0 bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" },
    ).trim();

    const onlineByte = parseInt(onlineStatus, 16);

    // If printer is online (bit 3 = 0) return ready
    if ((onlineByte & 0x08) === 0) {
      return { ready: true, reason: "Printer is ready" };
    }

    const offlineByte = parseInt(offlineCause, 16);
    const paperByte = parseInt(paperStatus, 16);

    if (offlineByte & 0x04) {
      return { ready: false, reason: PRINTER_EVENTS.COVER_OPEN };
    }

    if (paperByte & 0xc0) {
      return { ready: false, reason: PRINTER_EVENTS.OUT_OF_PAPER };
    }

    if (offlineByte & 0x40) {
      return { ready: false, reason: PRINTER_EVENTS.MECHANICAL_ERROR };
    }

    return { ready: true, reason: "Printer is ready" };
  } catch (err) {
    log(`Failed to check printer status: ${err.message}`, "ERROR");
    return { ready: false, reason: `Status check failed: ${err.message}` };
  }
}

// Download document from S3 URI specified in job document
function downloadDocument(filePath) {
  try {
    // Read the job JSON file
    const jobId = path.basename(filePath, ".json");
    const jobData = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const jobExpiresAt = jobData.execution?.jobDocument?.jobExpiresAt;
    const jobDownloadUri = jobData.execution?.jobDocument?.uri;

    // If the job has expired, throw an EXPIRED error
    if (isJobExpired(jobExpiresAt)) {
      throw new Error(JOB_EVENTS.EXPIRED);
    }

    log(`Downloading job ${jobId} body from URI: ${jobDownloadUri}`);

    // Download the job body document using curl
    const escposJobPath = path.join(JOBS_DIR, `${jobId}.escpos`);
    execSync(`curl -s "${jobDownloadUri}" -o "${escposJobPath}"`, {
      shell: "/bin/bash",
    });

    log(`Job ${jobId} downloaded successfully to ${escposJobPath}`);

    return JOB_EVENTS.DOWNLOADED;
  } catch (err) {
    log(`Failed to download document: ${err.message}`, "ERROR");

    // Return the specific error for handling
    if (err.message === JOB_EVENTS.EXPIRED) {
      return JOB_EVENTS.EXPIRED;
    }
  }
}

// Print document to printer
function printDocument(jobId) {
  try {
    const filePathJson = path.join(JOBS_DIR, `${jobId}.json`);
    const filePathEscPos = path.join(JOBS_DIR, `${jobId}.escpos`);

    // Read the job JSON file
    const jobData = JSON.parse(fs.readFileSync(filePathJson, "utf8"));
    const jobExpiresAt = jobData.execution?.jobDocument?.jobExpiresAt;

    // If the job has expired, throw an EXPIRED error
    if (isJobExpired(jobExpiresAt)) {
      throw new Error(JOB_EVENTS.EXPIRED);
    }

    log(`Printing job ${jobId} from ${filePathEscPos}`);

    // Pre-print check
    const preStatus = checkPrinterStatus();
    if (!preStatus.ready) {
      // Throw printer offline reason for handling
      throw new Error(preStatus.reason);
    }

    // Send raw ESC/POS directly to printer device (bypass CUPS)
    execSync(`cat "${filePathEscPos}" > /dev/usb/lp0`, { shell: "/bin/bash" });

    // Post-print check
    const postStatus = checkPrinterStatus();
    if (!postStatus.ready) {
      // Throw printer offline reason for handling
      throw new Error(postStatus.reason);
    }

    log(`Job ${jobId} printed successfully`);

    return JOB_EVENTS.PRINTED;
  } catch (err) {
    log(`Failed to print document ${jobId}: ${err.message}`, "ERROR");

    // Return the specific error for handling
    return err.message;
  }
}

async function main() {
  const clientBootstrap = new io.ClientBootstrap();

  const configBuilder =
    iot.AwsIotMqttConnectionConfigBuilder.new_mtls_builder_from_path(
      DEVICE_CERT,
      DEVICE_KEY,
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

    // Print device ready receipt on first connection per power cycle
    if (!hasDeviceReadyPrinted) {
      try {
        const printerStatus = checkPrinterStatus();
        if (printerStatus.ready && fs.existsSync(DEVICE_READY_ESCPOS)) {
          execSync(`cat "${DEVICE_READY_ESCPOS}" > /dev/usb/lp0`, {
            shell: "/bin/bash",
          });
          log("Printed device ready receipt");
        } else if (!printerStatus.ready) {
          log(`Skipping device ready print: ${printerStatus.reason}`, "WARN");
        }
      } catch (err) {
        log(`Failed to print device ready receipt: ${err.message}`, "ERROR");
      }
      hasDeviceReadyPrinted = true;
    }

    // For "public" shadow: load local config and push to AWS (device is source of truth)
    try {
      loadLocalPublicShadowConfig();
      await updateShadowReportedState("public");
      log("Pushed local config to AWS public shadow");
    } catch (err) {
      log(`Failed to push public shadow: ${err.message}`, "ERROR");
    }

    // For "private" shadow: fetch from AWS (cloud is source of truth)
    try {
      const topic = `${TOPIC_PREFIX}/shadow/name/private/get`;
      await connection.publish(topic, JSON.stringify({}), mqtt.QoS.AtLeastOnce);
      log("Requested shadow state for: private");
    } catch (err) {
      log(`Failed to request private shadow: ${err.message}`, "ERROR");
    }

    // Publish an empty JSON payload to request the next job
    try {
      await connection.publish(
        `$aws/things/${DEVICE_ID}/jobs/start-next`,
        JSON.stringify({}),
        mqtt.QoS.AtLeastOnce,
      );

      log(
        `Published start-next request to $aws/things/${DEVICE_ID}/jobs/start-next`,
      );
    } catch (err) {
      log(`Failed to publish start-next: ${err.message}`, "ERROR");
    }
  });

  connection.on("interrupt", (error) => {
    log(`Connection interrupted: ${error}`, "WARN");
  });

  connection.on("resume", async (return_code, session_present) => {
    log(
      `Connection resumed. Return code: ${return_code}, Session present: ${session_present}`,
    );

    // Publish an empty JSON payload to request the next job
    try {
      await connection.publish(
        `$aws/things/${DEVICE_ID}/jobs/start-next`,
        JSON.stringify({}),
        mqtt.QoS.AtLeastOnce,
      );

      log(
        `Published start-next request to $aws/things/${DEVICE_ID}/jobs/start-next`,
      );
    } catch (err) {
      log(`Failed to publish start-next: ${err.message}`, "ERROR");
    }
  });

  connection.on("disconnect", () => {
    log("Disconnected from AWS IoT Core");
  });

  connection.on("error", (error) => {
    log(`Connection error: ${error}`, "ERROR");
  });

  // Message handler
  connection.on("message", async (topic, payload) => {
    try {
      const message = Buffer.from(payload).toString("utf8");
      log(`Received message on topic: ${topic}`);
      log(`Message: ${message}`);

      // Parse and handle message
      const data = JSON.parse(message);

      /*
        Handle shadow delta messages
        Topics: $aws/things/{thingName}/shadow/name/{shadowName}/update/delta
        Contains the state.desired properties that differ from state.reported
      */
      if (topic.includes("/shadow/name/") && topic.includes("/update/delta")) {
        // Extract shadow name from topic
        const shadowMatch = topic.match(
          /\/shadow\/name\/([^/]+)\/update\/delta/,
        );
        if (shadowMatch) {
          const shadowName = shadowMatch[1];
          const desiredState = data.state || {};
          await handleShadowDelta(shadowName, desiredState);
        }
        return;
      }

      /*
        Handle message on $aws/things/{thingName}/jobs/notify-next OR $aws/things/thingName/jobs/start-next/accepted

        Sample message structure:
        {
          "timestamp" : 10011,
          "execution" : {
            "jobId" : "other-job",
            "status" : "IN_PROGRESS",
            "queuedAt" : 10009,
            "lastUpdatedAt" : 10009,
            "versionNumber" : 1,
            "executionNumber" : 1,
            "jobDocument" : {"c":"d"}
          }
        }
      */

      if (
        topic.includes("/jobs/start-next/accepted") ||
        topic.includes("/jobs/notify-next")
      ) {
        const jobId = data.execution?.jobId;
        const jobVersionNumber = data.execution?.versionNumber;
        const jobExpiresAt = data.execution?.jobDocument.expiresAt;

        // Early out if no job is available
        if (!jobId) {
          log("No job available at this time");
          return;
        }

        log(
          `Job notification: ${data.execution.jobId}, Status: ${data.execution.status}`,
        );

        if (jobId && jobVersionNumber && jobExpiresAt) {
          log(`Processing job ID: ${jobId}`);

          // If the job has expired, throw EXPIRED error
          try {
            if (isJobExpired(jobExpiresAt)) {
              throw new Error(JOB_EVENTS.EXPIRED);
            }
          } catch (error) {
            log(`Job ${jobId} has expired and will be rejected`);

            const rejectedPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.REJECTED, // REJECTED Jobs are NOT retried
              statusDetails: {
                event: JOB_EVENTS.EXPIRED,
              },
              expectedVersion: jobVersionNumber,
              includeJobExecutionState: true,
              includeJobDocument: false,
              clientToken: jobId, // Use jobId as clientToken
            });

            connection.publish(
              `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
              rejectedPayload,
              mqtt.QoS.AtLeastOnce,
            );

            log(`Job ${jobId} rejected due to expiration`);

            return;
          }

          // Write the job data to a JSON file in the JOBS_DIR directory
          const jobFilePath = path.join(JOBS_DIR, `${jobId}.json`);

          fs.writeFileSync(jobFilePath, JSON.stringify(data));

          log(`Job content written to: ${jobFilePath}`);

          // Update job execution status to IN_PROGRESS
          const successPayload = JSON.stringify({
            status: JOB_EXECUTION_STATUSES.IN_PROGRESS,
            statusDetails: {
              event: JOB_EVENTS.QUEUED,
            },
            expectedVersion: jobVersionNumber,
            includeJobExecutionState: true,
            includeJobDocument: false,
            clientToken: jobId, // Use jobId as clientToken
          });

          connection.publish(
            `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
            successPayload,
            mqtt.QoS.AtLeastOnce,
          );
        } else {
          log(`Invalid job document or job ID in message`, "ERROR");
        }
      }

      /* 
        Handle messages received on $aws/things/{thingName}/jobs/{jobId}/update/accepted

        Sample message structure:
        {
          "executionState": {
            "status": "QUEUED|IN_PROGRESS|FAILED|SUCCEEDED|CANCELED|TIMED_OUT|REJECTED|REMOVED",
            "statusDetails": {
                "event": "string"
            }
            "versionNumber": "number"
          },
          "timestamp": timestamp,
          "clientToken": "string"
        }
      */

      if (topic.match(/\/jobs\/.+\/update\/accepted$/)) {
        log(`Processing job update accepted message: ${JSON.stringify(data)}`);

        const jobId = data.clientToken;
        const jobStatus = data.executionState?.status;
        const jobEvent = data.executionState?.statusDetails?.event;
        const jobVersionNumber = data.executionState?.versionNumber;

        log(
          `Job update accepted with status: ${jobStatus}, event: ${jobEvent}`,
        );

        // Handle job based on jobStatus
        switch (jobStatus) {
          case JOB_EXECUTION_STATUSES.IN_PROGRESS:
            log(`Job ${jobId} in progress`);

            switch (jobEvent) {
              case JOB_EVENTS.QUEUED:
                // Download the document
                const downloadResult = downloadDocument(
                  path.join(JOBS_DIR, `${jobId}.json`),
                );

                // Handle DOWNLOADED job
                if (downloadResult === JOB_EVENTS.DOWNLOADED) {
                  const downloadedPayload = JSON.stringify({
                    status: JOB_EXECUTION_STATUSES.IN_PROGRESS,
                    statusDetails: {
                      event: JOB_EVENTS.DOWNLOADED,
                    },
                    expectedVersion: jobVersionNumber,
                    includeJobExecutionState: true,
                    includeJobDocument: false,
                    clientToken: jobId, // Use jobId as clientToken
                  });

                  connection.publish(
                    `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                    downloadedPayload,
                    mqtt.QoS.AtLeastOnce,
                  );
                }

                break;
              case JOB_EVENTS.DOWNLOADED:
                // Print the document
                const printResult = printDocument(jobId);

                // Only mark as SUCCEEDED if print was successful
                // Any other result (PRINTER_EVENTS or device errors) should be FAILED
                if (printResult !== JOB_EVENTS.PRINTED) {
                  log(
                    `Job ${jobId} cannot be printed due to printer issue: ${printResult}`,
                  );

                  // Delay before reporting failure to slow down retry cycle
                  // This gives users time to fix printer issues (e.g., add paper, power on printer)
                  log(
                    `Waiting 10 seconds before reporting failure for job ${jobId}...`,
                  );
                  await new Promise((resolve) => setTimeout(resolve, 10000));

                  const printerOfflinePayload = JSON.stringify({
                    status: JOB_EXECUTION_STATUSES.FAILED,
                    statusDetails: {
                      event: JOB_EVENTS.PRINTER_OFFLINE,
                      reason: printResult,
                    },
                    expectedVersion: jobVersionNumber,
                    includeJobExecutionState: true,
                    includeJobDocument: false,
                    clientToken: jobId, // Use jobId as clientToken
                  });

                  connection.publish(
                    `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                    printerOfflinePayload,
                    mqtt.QoS.AtLeastOnce,
                  );

                  return;
                }

                const printedPayload = JSON.stringify({
                  status: JOB_EXECUTION_STATUSES.SUCCEEDED,
                  statusDetails: {
                    event: JOB_EVENTS.PRINTED,
                    jobId,
                  },
                  expectedVersion: jobVersionNumber,
                  includeJobExecutionState: true,
                  includeJobDocument: false,
                  clientToken: jobId, // Use jobId as clientToken
                });

                connection.publish(
                  `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                  printedPayload,
                  mqtt.QoS.AtLeastOnce,
                );

                break;
              default:
                log(`Unhandled job event: ${jobEvent}`);
            }

            break;
          default:
            // For SUCCEEDED, FAILED, REJECTED - clean up job files
            log(`Job ${jobId}: ${jobStatus}, cleaning up files`);

            // Remove Job files
            fs.unlinkSync(path.join(JOBS_DIR, `${jobId}.json`));
            fs.unlinkSync(path.join(JOBS_DIR, `${jobId}.escpos`));
        }
      }

      /*
        Handle message on $aws/commands/things/{thingName}/executions/+request/JSON

        Sample message structure:
        {
          "commandId": "SetTemperature",
          "namespace": "AWS-IoT",
          "payloadTemplate": "{\"temperature\": \"${aws:iot:commandexecution::parameter:temperature}\"}",
          "parameters": [
            {
              "name": "temperature",
              "type": "INTEGER",
              "valueConditions": [
                {
                  "comparisonOperator": "IN_RANGE",
                  "operand": {
                    "numberRange": {
                      "min": "60",
                      "max": "80"
                    }
                  }
                }
              ]
            }
          ]
        }
      */

      if (
        topic.match(/\/commands\/things\/.+\/executions\/.+\/request\/json$/i)
      ) {
        log(`Processing command execution request: ${JSON.stringify(data)}`);

        const commandId = data.commandId;
        const executionId = topic.split("/")[5];

        log(
          `Command execution request received. Command ID: ${commandId} with Execution ID: ${executionId}`,
        );

        // Handle startNgrokTunnel command
        if (commandId === "startNgrokTunnel") {
          const authToken = data.authToken;

          if (!authToken) {
            log(
              "startNgrokTunnel command missing authToken parameter",
              "ERROR",
            );
            return;
          }

          log("Starting ngrok SSH forwarding...");

          try {
            // Close existing ngrok listener if any
            if (ngrokListener) {
              log("Closing existing ngrok connection...");
              await ngrokListener.close();
              ngrokListener = null;
            }

            // Start ngrok forwarding for SSH on port 22
            ngrokListener = await ngrok.forward({
              addr: 22,
              authtoken: authToken,
              proto: "tcp",
            });

            const ngrokUrl = ngrokListener.url();
            log(`ngrok SSH forwarding established: ${ngrokUrl}`, "INFO");

            // Publish SUCCESS event to $aws/commands/things/<DEVICE_ID>/executions/<executionId>/response/json
            const successPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.SUCCEEDED,
              statusReason: {
                reasonCode: "200",
                reasonDescription: "Tunnel established successfully",
              },
              result: {
                ngrokUrl: { s: ngrokUrl },
              },
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              successPayload,
              mqtt.QoS.AtLeastOnce,
            );
          } catch (err) {
            log(
              `Failed to establish ngrok SSH forwarding: ${err.message}`,
              "ERROR",
            );

            // Publish FAILED event to $aws/commands/things/<DEVICE_ID>/executions/<executionId>/response/json
            const failedPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.FAILED,
              statusReason: {
                reasonCode: "500",
                reasonDescription: "Failed to establish tunnel",
              },
              result: {},
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              failedPayload,
              mqtt.QoS.AtLeastOnce,
            );
          }
        }

        // Handle stopNgrokTunnel command
        if (commandId === "stopNgrokTunnel") {
          log("Stopping ngrok SSH forwarding...");

          try {
            if (ngrokListener) {
              await ngrokListener.close();
              ngrokListener = null;
              log("ngrok SSH forwarding stopped", "INFO");

              // Publish SUCCESS event to $aws/commands/things/<DEVICE_ID>/executions/<executionId>/response/json
              const successPayload = JSON.stringify({
                status: JOB_EXECUTION_STATUSES.SUCCEEDED,
                statusReason: {
                  reasonCode: "200",
                  reasonDescription: "Tunnel stopped successfully",
                },
                result: {},
              });

              connection.publish(
                `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
                successPayload,
                mqtt.QoS.AtLeastOnce,
              );
            } else {
              log("No active ngrok SSH forwarding to stop", "WARN");
            }
          } catch (err) {
            log(`Failed to stop ngrok SSH forwarding: ${err.message}`, "ERROR");

            // Publish failure event
            const failedPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.FAILED,
              statusReason: {
                reasonCode: "500",
                reasonDescription: "Failed to stop tunnel",
              },
              result: {},
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              failedPayload,
              mqtt.QoS.AtLeastOnce,
            );
          }
        }

        /*
        Handle Reset command

        Reset message structure:
          {
            "commandId": "reset",
            "namespace": "AWS-IoT",
            "payloadTemplate": "{\"commandId\": \"${aws:iot:commandexecution::parameter:commandId}\",\"reboot\": \"${aws:iot:commandexecution::parameter:reboot}\"}",
            "parameters": [
              {
                "name": "reboot",
                "type": "BOOLEAN"
              }
            ]
          }
        */

        if (commandId === "reset") {
          log("Processing reset command...");

          const reboot = data.reboot === true || data.reboot === "true";
          const RESET_DIR = "/usr/local/lib/eatabit/reset";
          const RESET_FLAG = `${RESET_DIR}/.reset-flag`;

          try {
            // Ensure reset directory exists with proper permissions
            if (!fs.existsSync(RESET_DIR)) {
              log("Creating reset directory...");
              fs.mkdirSync(RESET_DIR, { recursive: true, mode: 0o777 });
            }

            // Create reset flag
            log("Setting device reset flag...");
            fs.writeFileSync(RESET_FLAG, "1", { mode: 0o666 });

            log("Device reset flag set successfully");

            // Publish SUCCESS event
            const successPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.SUCCEEDED,
              statusReason: {
                reasonCode: "200",
                reasonDescription: "Reset flag set successfully",
              },
              result: {
                resetFlagSet: { b: true },
                rebooting: { b: reboot },
              },
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              successPayload,
              mqtt.QoS.AtLeastOnce,
            );

            // If reboot requested, reboot after brief delay to ensure response is sent
            if (reboot) {
              log("Rebooting device in 5 seconds...");
              setTimeout(() => {
                try {
                  execSync("shutdown -r now", { shell: "/bin/bash" });
                  log("Reboot command issued");
                } catch (err) {
                  log(`Failed to reboot device: ${err.message}`, "ERROR");
                }
              }, 5000);
            }
          } catch (err) {
            log(`Failed to process reset command: ${err.message}`, "ERROR");

            // Publish failure event
            const failedPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.FAILED,
              statusReason: {
                reasonCode: "500",
                reasonDescription: err.message,
              },
              result: {},
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              failedPayload,
              mqtt.QoS.AtLeastOnce,
            );
          }
        }

        /*
        Handle Reboot command

        Reset message structure:
          {
            "commandId": "reboot",
            "namespace": "AWS-IoT",
            "payloadTemplate": "{\"commandId\": \"${aws:iot:commandexecution::parameter:commandId}\"}"
          }
        */

        if (commandId === "reboot") {
          log("Processing reboot command...");

          try {
            // Reboot device
            log("Rebooting device...");

            // Publish SUCCESS event
            const successPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.SUCCEEDED,
              statusReason: {
                reasonCode: "200",
                reasonDescription: "Reboot command processed successfully",
              },
              result: {
                rebooting: { b: true },
              },
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              successPayload,
              mqtt.QoS.AtLeastOnce,
            );

            // Reboot after brief delay to ensure response is sent
            setTimeout(() => {
              try {
                execSync("shutdown -r now", { shell: "/bin/bash" });
                log("Reboot command issued");
              } catch (err) {
                log(`Failed to reboot device: ${err.message}`, "ERROR");
              }
            }, 5000);
          } catch (err) {
            log(`Failed to process reboot command: ${err.message}`, "ERROR");

            // Publish failure event
            const failedPayload = JSON.stringify({
              status: JOB_EXECUTION_STATUSES.FAILED,
              statusReason: {
                reasonCode: "500",
                reasonDescription: err.message,
              },
              result: {},
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              failedPayload,
              mqtt.QoS.AtLeastOnce,
            );
          }
        }
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
    for (const topic of SUBSCRIBE_TOPICS) {
      log(`Subscribing to ${topic}`);
      await connection.subscribe(topic, mqtt.QoS.AtLeastOnce);
    }
    log("Successfully subscribed to all topics");

    // Initialize shadow reported state
    log("Initializing shadow reported states...");
    await updateShadowReportedState("public");
    await updateShadowReportedState("private");

    // Watch cutter config file for BLE-initiated changes
    watchCutterConfigFile();

    // Watch volume config file for BLE-initiated changes
    watchVolumeConfigFile();

    // Start health data publishing every 15 minutes (900000 ms)
    // First publish immediately
    await publishHealthData();

    const healthInterval = setInterval(async () => {
      await publishHealthData();
    }, 900000); // 15 minutes
    await new Promise((resolve) => {
      process.on("SIGINT", async () => {
        log("Received SIGINT, disconnecting...");
        clearInterval(healthInterval);

        // Force exit after 10 seconds if graceful shutdown hangs
        const forceExit = setTimeout(() => {
          log("Graceful shutdown timed out, forcing exit");
          process.exit(0);
        }, 10000);

        try {
          await publishEvent("disconnected", { reason: "SIGINT" });
          await connection.disconnect();
        } catch (err) {
          log(`Error during shutdown: ${err.message}`, "ERROR");
        }

        clearTimeout(forceExit);
        resolve();
      });

      process.on("SIGTERM", async () => {
        log("Received SIGTERM, disconnecting...");
        clearInterval(healthInterval);

        // Force exit after 10 seconds if graceful shutdown hangs
        const forceExit = setTimeout(() => {
          log("Graceful shutdown timed out, forcing exit");
          process.exit(0);
        }, 10000);

        try {
          await publishEvent("disconnected", { reason: "SIGTERM" });
          await connection.disconnect();
        } catch (err) {
          log(`Error during shutdown: ${err.message}`, "ERROR");
        }

        clearTimeout(forceExit);
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
