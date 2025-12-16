#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const net = require("net");
const { mqtt, io, iot } = require("aws-iot-device-sdk-v2");
const { execSync } = require("child_process");
const WebSocket = require("ws");
const protobuf = require("protobufjs");
const https = require("https");

// Configuration
const EATABIT_DIR = "/usr/local/lib/eatabit";
const CERT_PATH = `${EATABIT_DIR}/cert`;
const DEVICE_CERT = `${CERT_PATH}/device.pem`;
const DEVICE_KEY = `${CERT_PATH}/device.key`;
const ROOT_CA = `${CERT_PATH}/AmazonRootCA1.pem`;
const ENDPOINT = "a3fw1u2gvi2uac-ats.iot.us-east-2.amazonaws.com";
const LOG_FILE = `${EATABIT_DIR}/log/mqtt-client.log`;
const JOBS_DIR = "/tmp";

// Secure Tunnel Configuration
const TUNNEL_PROXY_REGION = "us-east-2";
const TUNNEL_PROXY_ENDPOINT = `data.tunneling.iot.${TUNNEL_PROXY_REGION}.amazonaws.com`;
const LOCAL_PROXY_SERVICE = "SSH";
const LOCAL_PROXY_PORT = 22;

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

// Job topics (inbound)
const JOB_TOPICS = [
  `$aws/things/${DEVICE_ID}/jobs/notify-next`,
  `$aws/things/${DEVICE_ID}/jobs/start-next/accepted`,
  `$aws/things/${DEVICE_ID}/jobs/start-next/rejected`,
  `$aws/things/${DEVICE_ID}/jobs/+/update`,
  `$aws/things/${DEVICE_ID}/jobs/+/update/accepted`,
  `$aws/things/${DEVICE_ID}/jobs/+/update/rejected`,
  `$aws/things/${DEVICE_ID}/tunnels/notify`,
];

// Events topic (outbound)
const EVENTS_TOPIC = `eatabit/things/${DEVICE_ID}/events`;

log(`Starting Eatabit AWS IoT Client for device: ${DEVICE_ID}`);

// Global connection reference for publishing
let mqttConnection;

// Secure tunnel state
let activeTunnelConnection = null;
let tunnelStreamId = 1;
const activeTunnelStreams = new Map();

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

// Helper function to test if a job has expired
function isJobExpired(expiresAt) {
  return Number(expiresAt) < Math.floor(Date.now() / 1000);
}

// Secure Tunnel Protocol Buffer Message Schema (V2)
const tunnelProtoSchema = `
syntax = "proto3";

message Message {
  enum Type {
    UNKNOWN = 0;
    DATA = 1;
    STREAM_START = 2;
    STREAM_RESET = 3;
    SESSION_RESET = 4;
    SERVICE_IDS = 5;
  }
  Type type = 1;
  int32 streamId = 2;
  bool ignorable = 3;
  bytes payload = 4;
  repeated string serviceId = 5;
  repeated string availableServiceIds = 6;
  int32 connectionId = 7;
}
`;

let TunnelMessage = null;

// Initialize protobuf message type
function initTunnelProtobuf() {
  if (TunnelMessage) return TunnelMessage;

  try {
    const root = protobuf.parse(tunnelProtoSchema).root;
    TunnelMessage = root.lookupType("Message");
    return TunnelMessage;
  } catch (err) {
    log(`Failed to initialize tunnel protobuf: ${err.message}`, "ERROR");
    throw err;
  }
}

// Handle secure tunnel connection
function handleSecureTunnel(accessToken, region) {
  if (activeTunnelConnection) {
    log("Tunnel already active, closing previous connection");
    try {
      activeTunnelConnection.close();
    } catch (err) {
      log(`Error closing previous tunnel: ${err.message}`, "WARN");
    }
  }

  log(`Opening secure tunnel to region: ${region || TUNNEL_PROXY_REGION}`);

  const proxyEndpoint = region
    ? `data.tunneling.iot.${region}.amazonaws.com`
    : TUNNEL_PROXY_ENDPOINT;

  // Access token must be in query string
  const wsUrl = `wss://${proxyEndpoint}/tunnel?local-proxy-mode=destination&access-token=${encodeURIComponent(
    accessToken
  )}`;

  try {
    initTunnelProtobuf();

    // Create HTTPS agent with proper TLS configuration
    const agent = new https.Agent({
      rejectUnauthorized: true,
    });

    // IMPORTANT: This WebSocket is independent of the MQTT connection
    // AWS IoT Secure Tunneling requires the 'aws.iot.securetunneling-2.0' protocol
    const ws = new WebSocket(wsUrl, ["aws.iot.securetunneling-2.0"], {
      agent: agent,
    });

    activeTunnelConnection = ws;
    tunnelStreamId = 1;
    activeTunnelStreams.clear();

    ws.on("open", () => {
      log("Secure tunnel WebSocket connected");

      // Send SERVICE_IDS message to advertise available services
      const serviceIdsMsg = TunnelMessage.create({
        type: 5, // SERVICE_IDS
        serviceId: [LOCAL_PROXY_SERVICE],
        availableServiceIds: [LOCAL_PROXY_SERVICE],
      });

      const encoded = TunnelMessage.encode(serviceIdsMsg).finish();
      ws.send(encoded);
      log(`Advertised service: ${LOCAL_PROXY_SERVICE}`);
    });

    ws.on("message", (data) => {
      try {
        const message = TunnelMessage.decode(new Uint8Array(data));
        handleTunnelMessage(ws, message);
      } catch (err) {
        log(`Failed to decode tunnel message: ${err.message}`, "ERROR");
      }
    });

    ws.on("error", (error) => {
      log(`Secure tunnel error: ${error.message}`, "ERROR");
    });

    ws.on("close", (code, reason) => {
      log(`Secure tunnel closed: ${code} - ${reason}`);

      // Clean up all active streams
      for (const [streamId, socket] of activeTunnelStreams.entries()) {
        try {
          socket.destroy();
        } catch (err) {
          log(`Error closing stream ${streamId}: ${err.message}`, "WARN");
        }
      }
      activeTunnelStreams.clear();
      activeTunnelConnection = null;
    });
  } catch (err) {
    log(`Failed to create secure tunnel: ${err.message}`, "ERROR");
  }
}

// Handle incoming tunnel protocol messages
function handleTunnelMessage(ws, message) {
  const { type, streamId, payload } = message;

  switch (type) {
    case 2: // STREAM_START
      log(`Tunnel STREAM_START for stream ${streamId}`);
      handleStreamStart(ws, streamId);
      break;

    case 1: // DATA
      if (payload && payload.length > 0) {
        const socket = activeTunnelStreams.get(streamId);
        if (socket && !socket.destroyed) {
          socket.write(Buffer.from(payload));
        } else {
          log(`Received data for unknown/closed stream ${streamId}`, "WARN");
        }
      }
      break;

    case 3: // STREAM_RESET
      log(`Tunnel STREAM_RESET for stream ${streamId}`);
      handleStreamReset(streamId);
      break;

    case 4: // SESSION_RESET
      log("Tunnel SESSION_RESET received");
      // Close all streams and reconnect
      for (const socket of activeTunnelStreams.values()) {
        try {
          socket.destroy();
        } catch (err) {}
      }
      activeTunnelStreams.clear();
      break;

    case 5: // SERVICE_IDS (ignore echo from server)
      // Server echoes SERVICE_IDS back, this is normal
      break;

    default:
      log(`Unknown tunnel message type: ${type}`, "WARN");
  }
}

// Handle stream start - create TCP connection to local service
function handleStreamStart(ws, streamId) {
  if (activeTunnelStreams.has(streamId)) {
    log(`Stream ${streamId} already exists`, "WARN");
    return;
  }

  log(
    `Creating TCP connection to localhost:${LOCAL_PROXY_PORT} for stream ${streamId}`
  );

  const socket = new net.Socket();
  socket.setKeepAlive(true, 30000); // Enable TCP keepalive
  activeTunnelStreams.set(streamId, socket);

  socket.connect(LOCAL_PROXY_PORT, "localhost", () => {
    log(`TCP connection established for stream ${streamId}`);
  });

  socket.on("data", (data) => {
    // Forward data from local service to tunnel
    if (ws.readyState === WebSocket.OPEN) {
      const dataMsg = TunnelMessage.create({
        type: 1, // DATA
        streamId: streamId,
        payload: data,
      });

      const encoded = TunnelMessage.encode(dataMsg).finish();
      ws.send(encoded);
    }
  });

  socket.on("end", () => {
    log(`TCP connection ended for stream ${streamId}`);

    // Send STREAM_RESET to tunnel
    if (ws.readyState === WebSocket.OPEN) {
      const resetMsg = TunnelMessage.create({
        type: 3, // STREAM_RESET
        streamId: streamId,
      });

      const encoded = TunnelMessage.encode(resetMsg).finish();
      ws.send(encoded);
    }

    activeTunnelStreams.delete(streamId);
  });

  socket.on("error", (err) => {
    log(`TCP socket error for stream ${streamId}: ${err.message}`, "ERROR");

    // Send STREAM_RESET to tunnel
    if (ws.readyState === WebSocket.OPEN) {
      const resetMsg = TunnelMessage.create({
        type: 3, // STREAM_RESET
        streamId: streamId,
      });

      const encoded = TunnelMessage.encode(resetMsg).finish();
      ws.send(encoded);
    }

    socket.destroy();
    activeTunnelStreams.delete(streamId);
  });

  socket.on("close", (hadError) => {
    log(`TCP socket closed for stream ${streamId}, had error: ${hadError}`);
    activeTunnelStreams.delete(streamId);
  });
}

// Handle stream reset from tunnel
function handleStreamReset(streamId) {
  const socket = activeTunnelStreams.get(streamId);
  if (socket) {
    try {
      socket.destroy();
    } catch (err) {
      log(
        `Error destroying socket for stream ${streamId}: ${err.message}`,
        "WARN"
      );
    }
    activeTunnelStreams.delete(streamId);
  }
}

// Printer status check
function checkPrinterStatus() {
  try {
    const onlineStatus = execSync(
      `printf "\\x10\\x04\\x01" > /dev/usb/lp0 && timeout 1s dd if=/dev/usb/lp0 bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();

    const offlineCause = execSync(
      `printf "\\x10\\x04\\x02" > /dev/usb/lp0 && timeout 1s dd if=/dev/usb/lp0 bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();

    const paperStatus = execSync(
      `printf "\\x10\\x04\\x04" > /dev/usb/lp0 && timeout 1s dd if=/dev/usb/lp0 bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();

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

    // Publish an empty JSON payload to request the next job
    try {
      await connection.publish(
        `$aws/things/${DEVICE_ID}/jobs/start-next`,
        JSON.stringify({}),
        mqtt.QoS.AtLeastOnce
      );

      log(
        `Published start-next request to $aws/things/${DEVICE_ID}/jobs/start-next`
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
      `Connection resumed. Return code: ${return_code}, Session present: ${session_present}`
    );

    // Publish an empty JSON payload to request the next job
    try {
      await connection.publish(
        `$aws/things/${DEVICE_ID}/jobs/start-next`,
        JSON.stringify({}),
        mqtt.QoS.AtLeastOnce
      );

      log(
        `Published start-next request to $aws/things/${DEVICE_ID}/jobs/start-next`
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
  connection.on("message", (topic, payload) => {
    try {
      const message = Buffer.from(payload).toString("utf8");
      log(`Received message on topic: ${topic}`);
      log(`Message: ${message}`);

      // Parse and handle job notification
      const data = JSON.parse(message);

      // Handle secure tunnel notifications
      if (topic.includes("/tunnels/notify")) {
        log(`Tunnel notification received`);

        const accessToken = data.clientAccessToken;
        const region = data.region;
        const services = data.services || [LOCAL_PROXY_SERVICE];

        if (accessToken) {
          log(
            `Opening tunnel with access token, services: ${services.join(", ")}`
          );
          handleSecureTunnel(accessToken, region);
        } else {
          log("Tunnel notification missing access token", "ERROR");
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
          `Job notification: ${data.execution.jobId}, Status: ${data.execution.status}`
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
              status: JOB_EXECUTION_STATUSES.FAILED,
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
              mqtt.QoS.AtLeastOnce
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
            mqtt.QoS.AtLeastOnce
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
          `Job update accepted with status: ${jobStatus}, event: ${jobEvent}`
        );

        // Handle job based on jobStatus
        switch (jobStatus) {
          case JOB_EXECUTION_STATUSES.IN_PROGRESS:
            log(`Job ${jobId} in progress`);

            switch (jobEvent) {
              case JOB_EVENTS.QUEUED:
                // Download the document
                const downloadResult = downloadDocument(
                  path.join(JOBS_DIR, `${jobId}.json`)
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
                    mqtt.QoS.AtLeastOnce
                  );
                }

                break;
              case JOB_EVENTS.DOWNLOADED:
                // Print the document
                const printResult = printDocument(jobId);

                // Handle PRINTER_OFFLINE events
                if (printResult in PRINTER_EVENTS) {
                  log(
                    `Job ${jobId} cannot be printed due to printer issue: ${printResult}`
                  );

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
                    mqtt.QoS.AtLeastOnceƒ
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
                  mqtt.QoS.AtLeastOnce
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
