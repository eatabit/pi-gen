#!/usr/bin/env node

const bleno = require("@abandonware/bleno");
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// Configuration
const EATABIT_DIR = "/usr/local/lib/eatabit";
const LOG_FILE = `${EATABIT_DIR}/log/ble-config.log`;
const MIN_SIGNAL_STRENGTH = 30; // Minimum signal strength for scanned networks

// Get Raspberry Pi serial number and generate device name
function getDeviceName() {
  try {
    // Try reading from stored device ID first (set by cloud-init user-data)
    let serialNumber = "";
    try {
      serialNumber = fs
        .readFileSync("/usr/local/lib/eatabit/deviceid", "utf8")
        .trim();
    } catch (e) {
      // Fallback: read from /proc/device-tree/serial-number
      try {
        serialNumber = fs
          .readFileSync("/proc/device-tree/serial-number", "utf8")
          .trim()
          .replace(/\0/g, "");
      } catch (e2) {
        // Fallback: read from /proc/cpuinfo
        const cpuInfo = fs.readFileSync("/proc/cpuinfo", "utf8");
        const match = cpuInfo.match(/Serial\s*:\s*(\w+)/);
        if (match) {
          serialNumber = match[1];
        }
      }
    }

    if (serialNumber && serialNumber.length >= 4) {
      const last4 = serialNumber.slice(-4);
      return `Eatabit-${last4}`;
    }
    return "Eatabit-XXXX"; // fallback if serial number unavailable
  } catch (err) {
    console.error(`Failed to read serial number: ${err.message}`);
    return "Eatabit-XXXX"; // fallback on error
  }
}

const DEVICE_NAME = getDeviceName();

// State
let currentSSID = "";
let currentPassword = "";
let connectionStatus = "idle"; // idle, connecting, connected, failed
let statusClients = [];
let scanClients = [];

// UUIDs for WiFi Configuration Service
const WIFI_SERVICE_UUID = "8f4c9b0e-5e57-4f9f-9a2a-4b6f8de9a3c1";
const SSID_CHAR_UUID = "0e2f3e4b-d9e2-4d0c-8a6c-2bbd2f40c3a7";
const PASSWORD_CHAR_UUID = "9c0fb5a7-6be4-4a38-b5d2-1c8af8d2a0bd";
const APPLY_CHAR_UUID = "3b1f7d6e-2cda-43c7-8c92-d0f7b8c0b6d2";
const STATUS_CHAR_UUID = "a2e6d8f3-71ac-4c17-8d79-7d7f4f5c2e43";
const CONFIG_STATUS_CHAR_UUID = "c4d5e6f7-8a9b-0c1d-2e3f-4a5b6c7d8e9f";
const SCAN_CHAR_UUID = "b3d4f5e6-7a8b-9c0d-1e2f-3a4b5c6d7e8f";

/**
 * Initialize logging
 */
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

/**
 * Log function
 */
function log(message, level = "INFO") {
  const timestamp = new Date().toISOString().replace("T", " ").slice(0, 23);
  const line = `[${timestamp}] [${level}] ${message}\n`;

  if (level === "ERROR" || level === "FATAL") {
    console.error(line.trim());
  } else {
    console.log(line.trim());
  }

  try {
    fs.appendFileSync(LOG_FILE, line);
  } catch (err) {
    console.error(`Failed to write to log file: ${err.message}`);
  }
}

initializeLogFile();

/**
 * Status code schema for BLE notifications (fits within MTU)
 * Format: "{method_code}|{result_code}|{detail_code}"
 *
 * Method codes:
 *   0 = applyWiFiConfig
 *   1 = scanWiFiNetworks
 *   2 = system/general
 *
 * Result codes:
 *   0 = failure
 *   1 = success
 *   2 = in-progress
 *
 * Detail codes for method 0 (applyWiFiConfig):
 *   0 = already connected (early-out)
 *   1 = SSID or password not set
 *   2 = connection verification failed
 *   3 = general error
 *   4 = successfully connected
 *   5 = connecting/in-progress
 */

/**
 * Update connection status and notify subscribed clients
 * @param {number} methodCode - Operation identifier (0=wifi, 1=scan, 2=system)
 * @param {number} resultCode - Result (0=fail, 1=success, 2=in-progress)
 * @param {number} detailCode - Specific detail/reason code
 */
function updateStatus(methodCode, resultCode, detailCode) {
  const statusMessage = `${methodCode}|${resultCode}|${detailCode}`;
  connectionStatus = statusMessage;

  // Notify all subscribed clients with compact status code
  const statusBuffer = Buffer.from(statusMessage);
  statusClients.forEach((client) => {
    if (client && typeof client.notify === "function") {
      try {
        client.notify(statusBuffer);
      } catch (err) {
        log(`Failed to notify client: ${err.message}`, "ERROR");
      }
    }
  });
}

/**
 * Scan for available WiFi networks using nmcli
 */
async function scanWiFiNetworks() {
  try {
    log("Scanning for WiFi networks...");

    // Use nmcli to list available WiFi networks
    const command =
      "nmcli -t -f SSID,SIGNAL,SECURITY,ACTIVE dev wifi list 2>&1";
    const result = execSync(command, { encoding: "utf8", shell: "/bin/bash" });

    const networks = result
      .split("\n")
      .filter((line) => line.trim())
      .map((line) => {
        const parts = line.split(":");
        if (parts.length < 4) return null;

        const ssid = parts[0] || "Hidden Network";
        const signal = parseInt(parts[1]) || 0;
        const security = parts[2] || "open";
        const active = parts[3].trim() === "yes";

        return {
          ss: ssid,
          sg: signal,
          en: security !== "open" && security !== "",
          cx: active,
        };
      })
      .filter(
        (network) => network !== null && network.sg >= MIN_SIGNAL_STRENGTH,
      )
      .sort((a, b) => b.sg - a.sg);
    log(`Found ${networks.length} networks`);
    return networks;
  } catch (err) {
    log(`Failed to scan WiFi networks: ${err.message}`, "ERROR");
    return [];
  }
}

/**
 * Apply WiFi configuration using nmcli
 */
function applyWiFiConfig() {
  try {
    if (!currentSSID || !currentPassword) {
      updateStatus(0, 0, 1); // method 0, fail, detail 1 (missing SSID/password)
      return false;
    }

    // Check if already connected to this SSID
    try {
      const currentConnection = execSync(
        'nmcli -t -f NAME,TYPE,DEVICE con show --active | grep "wifi:wlan0"',
        { encoding: "utf8", shell: "/bin/bash" },
      ).trim();

      if (currentConnection) {
        const connName = currentConnection.split(":")[0];
        // Check if this connection is to the target SSID
        const ssidCheck = execSync(
          `nmcli -t -f 802-11-wireless.ssid con show "${connName}"`,
          { encoding: "utf8", shell: "/bin/bash" },
        ).trim();

        const activeSsid = ssidCheck.split(":")[1];
        if (activeSsid === currentSSID) {
          log(`Already connected to ${currentSSID}, skipping reconnect`);
          updateStatus(0, 0, 0); // method 0, fail, detail 0 (already connected)
          return true;
        }
      }
    } catch (err) {
      // Not connected or error checking, continue with connection attempt
      log(`No active connection to ${currentSSID}, proceeding...`);
    }

    log(`Attempting to connect to WiFi: ${currentSSID}`);
    updateStatus(0, 2, 5); // method 0, in-progress, detail 5 (connecting)

    // Delete existing connection profile if it exists
    try {
      const existingProfiles = execSync(`nmcli -t -f NAME con show`, {
        encoding: "utf8",
        shell: "/bin/bash",
      });

      if (existingProfiles.includes(currentSSID)) {
        log(`Deleting existing connection profile: ${currentSSID}`);
        execSync(`nmcli con delete "${currentSSID}"`, {
          encoding: "utf8",
          shell: "/bin/bash",
        });
        log(`Deleted old profile: ${currentSSID}`);
      }
    } catch (err) {
      log(`No existing profile to delete for ${currentSSID}`);
    }

    // Create connection based on security type
    let createCommand;

    if (!currentPassword || currentPassword.length === 0) {
      // Open network - no security settings
      log(`Creating open (no security) connection for ${currentSSID}`);
      createCommand = `nmcli con add type wifi con-name "${currentSSID}" ifname wlan0 ssid "${currentSSID}" 2>&1`;
    } else {
      // Network with password - try WPA-PSK (covers WPA, WPA2, WPA3)
      log(`Creating WPA/WPA2/WPA3 secured connection for ${currentSSID}`);
      createCommand = `nmcli con add type wifi con-name "${currentSSID}" ifname wlan0 ssid "${currentSSID}" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${currentPassword}" 2>&1`;
    }

    log(`Creating new connection profile for ${currentSSID}`);
    let createResult;
    try {
      createResult = execSync(createCommand, {
        encoding: "utf8",
        shell: "/bin/bash",
      });
      log(`Profile creation result: ${createResult}`);
    } catch (err) {
      // If WPA-PSK fails, try WEP as fallback
      if (currentPassword && currentPassword.length > 0) {
        log(`WPA-PSK failed, attempting WEP fallback for ${currentSSID}`);
        const wepCommand = `nmcli con add type wifi con-name "${currentSSID}" ifname wlan0 ssid "${currentSSID}" wifi-sec.key-mgmt none wifi-sec.wep-key0 "${currentPassword}" 2>&1`;
        try {
          createResult = execSync(wepCommand, {
            encoding: "utf8",
            shell: "/bin/bash",
          });
          log(`WEP profile creation result: ${createResult}`);
        } catch (wepErr) {
          log(`Both WPA-PSK and WEP failed: ${wepErr.message}`, "ERROR");
          updateStatus(0, 0, 3); // method 0, fail, detail 3 (general error)
          return false;
        }
      } else {
        log(`Open network creation failed: ${err.message}`, "ERROR");
        updateStatus(0, 0, 3); // method 0, fail, detail 3 (general error)
        return false;
      }
    }

    // Bring up the connection
    const upCommand = `nmcli con up "${currentSSID}" 2>&1`;
    const result = execSync(upCommand, {
      encoding: "utf8",
      shell: "/bin/bash",
    });

    log(`WiFi connection result: ${result}`);

    // Verify connection
    const checkCommand =
      "nmcli -t -f DEVICE,STATE dev | grep -E 'wlan0.*connected'";
    try {
      execSync(checkCommand, { encoding: "utf8", shell: "/bin/bash" });
      updateStatus(0, 1, 0); // method 0, success, detail 0 (connected)
      log(`Successfully connected to ${currentSSID}`);
      return true;
    } catch (err) {
      updateStatus(0, 0, 2); // method 0, fail, detail 2 (connection verification failed)
      log(`Connection verification failed: ${err.message}`, "ERROR");
      return false;
    }
  } catch (err) {
    log(`Failed to apply WiFi config: ${err.message}`, "ERROR");
    updateStatus(0, 0, 3); // method 0, fail, detail 3 (apply config failed)
    return false;
  }
}

/**
 * Create SSID Characteristic (Read/Write)
 */
function createSSIDCharacteristic() {
  return new bleno.Characteristic({
    uuid: SSID_CHAR_UUID,
    properties: ["read", "write"],
    onReadRequest: (offset, callback) => {
      log(`SSID read request, current: ${currentSSID}`);
      const buffer = Buffer.from(currentSSID);
      callback(bleno.Characteristic.RESULT_SUCCESS, buffer);
    },
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      currentSSID = data.toString("utf8").trim();
      log(`SSID written: ${currentSSID}`);
      callback(bleno.Characteristic.RESULT_SUCCESS);
    },
  });
}

/**
 * Create Password Characteristic (Write-Only)
 */
function createPasswordCharacteristic() {
  return new bleno.Characteristic({
    uuid: PASSWORD_CHAR_UUID,
    properties: ["write"],
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      currentPassword = data.toString("utf8").trim();
      log(`Password written (length: ${currentPassword.length})`);
      callback(bleno.Characteristic.RESULT_SUCCESS);
    },
  });
}

/**
 * Create Apply Characteristic (Write-Only)
 */
function createApplyCharacteristic() {
  return new bleno.Characteristic({
    uuid: APPLY_CHAR_UUID,
    properties: ["write"],
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      log("Apply WiFi configuration requested");
      applyWiFiConfig();
      callback(bleno.Characteristic.RESULT_SUCCESS);
    },
  });
}

/**
 * Create Status Characteristic (Read/Notify)
 */
function createStatusCharacteristic() {
  return new bleno.Characteristic({
    uuid: STATUS_CHAR_UUID,
    properties: ["read", "notify"],
    onReadRequest: (offset, callback) => {
      log(`Status read request, current: ${connectionStatus}`);
      const buffer = Buffer.from(connectionStatus);
      callback(bleno.Characteristic.RESULT_SUCCESS, buffer);
    },
    onSubscribe: (maxValueSize, updateValueCallback) => {
      log("Client subscribed to status notifications");
      statusClients.push({ notify: updateValueCallback });
    },
    onUnsubscribe: () => {
      log("Client unsubscribed from status notifications");
      statusClients = [];
    },
  });
}

/**
 * Check if device has any configured WiFi networks
 */
function hasConfiguredWiFi() {
  try {
    const command = "nmcli -t -f TYPE,NAME con show 2>&1";
    const result = execSync(command, { encoding: "utf8", shell: "/bin/bash" });

    // Filter for WiFi/802-11-wireless connections
    const wifiConnections = result
      .split("\n")
      .filter((line) => line.trim())
      .filter((line) => {
        const parts = line.split(":");
        const type = parts[0] || "";
        return type === "802-11-wireless" || type === "wifi";
      });

    return wifiConnections.length > 0;
  } catch (err) {
    log(`Failed to check WiFi configuration: ${err.message}`, "ERROR");
    return false;
  }
}

/**
 * Create Config Status Characteristic (Read)
 * Returns whether device has configured WiFi networks
 * Response: "0" = no networks configured (factory reset state), "1" = configured
 */
function createConfigStatusCharacteristic() {
  return new bleno.Characteristic({
    uuid: CONFIG_STATUS_CHAR_UUID,
    properties: ["read"],
    onReadRequest: (offset, callback) => {
      log("Config status read request");

      const hasConfig = hasConfiguredWiFi();
      const status = hasConfig ? "1" : "0";

      log(
        `Config status: ${status} (${hasConfig ? "configured" : "not configured"})`,
      );
      callback(bleno.Characteristic.RESULT_SUCCESS, Buffer.from(status));
    },
  });
}

/**
 * Create Scan Characteristic (Read/Notify/Write)
 * Allows clients to request WiFi scan and receive multipart results
 */
function createScanCharacteristic() {
  return new bleno.Characteristic({
    uuid: SCAN_CHAR_UUID,
    properties: ["read", "write", "notify"],
    onReadRequest: (offset, callback) => {
      log("Scan read request");
      callback(bleno.Characteristic.RESULT_SUCCESS, Buffer.from(""));
    },
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      const request = data.toString("utf8").trim();
      log(`Scan request: ${request}`);

      if (request === "SCAN") {
        scanWiFiNetworks()
          .then((scanResult) => {
            log("Scan result:", JSON.stringify(scanResult));

            const jsonData = JSON.stringify(scanResult);
            const dataBuffer = Buffer.from(jsonData, "utf8");

            log(`Scan result size (bytes): ${dataBuffer.length}`);

            scanClients.forEach((client) => {
              if (client && typeof client.notify === "function") {
                const mtuSize = client.maxSize || 20;

                // Pre-calculate chunks to determine accurate totalParts
                const chunks = [];
                let offset = 0;
                let index = 0;

                // First pass: calculate all chunks with temporary headers to get count
                while (offset < dataBuffer.length) {
                  // Use worst-case header length for initial calculation
                  // Format: "999|999|" = 8 bytes worst case
                  const maxHeaderLen = 8;
                  const payloadSize = Math.max(1, mtuSize - maxHeaderLen);
                  const chunk = dataBuffer.slice(offset, offset + payloadSize);
                  chunks.push(chunk);
                  offset += chunk.length;
                  index += 1;
                }

                const totalParts = chunks.length;
                log(`Scan result split into ${totalParts} chunks`);

                // Second pass: send chunks with correct totalParts in header
                chunks.forEach((chunk, idx) => {
                  const header = `${idx}|${totalParts}|`;
                  const buffer = Buffer.concat([Buffer.from(header), chunk]);

                  setTimeout(() => {
                    try {
                      client.notify(buffer);
                    } catch (err) {
                      log(
                        `Failed to send scan chunk ${idx}: ${err.message}`,
                        "ERROR",
                      );
                    }
                  }, idx * 100);
                });
              }
            });

            log(`WiFi scan sent to ${scanClients.length} subscribers`);
          })
          .catch((err) => {
            log(`Error during WiFi scan: ${err.message}`, "ERROR");
          });
      }

      callback(bleno.Characteristic.RESULT_SUCCESS);
    },
    onSubscribe: (maxValueSize, updateValueCallback) => {
      log("Client subscribed to scan notifications");
      log(`Max value size: ${maxValueSize}`);
      scanClients.push({ notify: updateValueCallback, maxSize: maxValueSize });
    },
    onUnsubscribe: () => {
      log("Client unsubscribed from scan notifications");
      scanClients = [];
    },
  });
}

/**
 * Create WiFi Configuration Service
 */
function createWiFiService() {
  return new bleno.PrimaryService({
    uuid: WIFI_SERVICE_UUID,
    characteristics: [
      createSSIDCharacteristic(),
      createPasswordCharacteristic(),
      createApplyCharacteristic(),
      createStatusCharacteristic(),
      createConfigStatusCharacteristic(),
      createScanCharacteristic(),
    ],
  });
}

/**
 * Initialize BLE Server
 */
function initializeBLE() {
  log("Initializing BLE server...");

  // Handle state changes
  bleno.on("stateChange", (state) => {
    log(`BLE state changed: ${state}`);

    if (state === "poweredOn") {
      log(`Starting BLE advertisement: ${DEVICE_NAME}`);
      bleno.startAdvertising(DEVICE_NAME, [WIFI_SERVICE_UUID], (err) => {
        if (err) {
          log(`Failed to start advertising: ${err.message}`, "ERROR");
        } else {
          log("BLE advertising started successfully");
        }
      });
    } else {
      bleno.stopAdvertising();
      log("BLE advertising stopped");
    }
  });

  // Handle advertising start
  bleno.on("advertisingStart", (err) => {
    if (err) {
      log(`Advertising error: ${err.message}`, "ERROR");
    } else {
      log("Advertising started, setting up GATT server");

      // Set up primary service and characteristics
      bleno.setServices([createWiFiService()], (err) => {
        if (err) {
          log(`Failed to set services: ${err.message}`, "ERROR");
        } else {
          log("GATT services configured successfully");
        }
      });
    }
  });

  // Handle advertising stop
  bleno.on("advertisingStop", () => {
    log("Advertising stopped");
  });

  // Handle accept connection
  bleno.on("accept", (clientAddress) => {
    log(`BLE client accepted: ${clientAddress}`);
  });

  // Handle disconnect
  bleno.on("disconnect", (clientAddress) => {
    log(`BLE client disconnected: ${clientAddress}`);
    statusClients = [];
    scanClients = [];
  });

  // Handle platform-specific events
  bleno.on("mtuChange", (mtu) => {
    log(`MTU changed to: ${mtu}`);
  });
}

/**
 * Main entry point
 */
async function main() {
  try {
    log("Starting Eatabit BLE Configuration Server");
    log(`Device Name: ${DEVICE_NAME}`);
    log(`WiFi Service UUID: ${WIFI_SERVICE_UUID}`);

    initializeBLE();

    // Handle graceful shutdown
    process.on("SIGINT", async () => {
      log("Received SIGINT, shutting down...");
      bleno.stopAdvertising(() => {
        process.exit(0);
      });
    });

    process.on("SIGTERM", async () => {
      log("Received SIGTERM, shutting down...");
      bleno.stopAdvertising(() => {
        process.exit(0);
      });
    });
  } catch (err) {
    log(`Fatal error: ${err.message}`, "FATAL");
    process.exit(1);
  }
}

main().catch((err) => {
  log(`Uncaught error: ${err.message}`, "FATAL");
  process.exit(1);
});
