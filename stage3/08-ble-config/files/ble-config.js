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
let currentCutterType = "partial"; // default: "partial", "full", or "none"
let currentVolume = 4; // default: 4 (range 0-8, where 0=off)

// Config file paths
const CUTTER_CONFIG_FILE = `${EATABIT_DIR}/config/cutter-type.json`;
const VOLUME_CONFIG_FILE = `${EATABIT_DIR}/config/volume.json`;

/**
 * Load cutter type from config file
 */
function loadCutterType() {
  try {
    if (fs.existsSync(CUTTER_CONFIG_FILE)) {
      const data = JSON.parse(fs.readFileSync(CUTTER_CONFIG_FILE, "utf8"));
      if (
        data.cutterType &&
        ["partial", "full", "none"].includes(data.cutterType)
      ) {
        currentCutterType = data.cutterType;
        log(`Loaded cutter type from config: ${currentCutterType}`);
      }
    }
  } catch (err) {
    log(`Failed to load cutter type: ${err.message}`, "ERROR");
  }
}

/**
 * Save cutter type to config file
 */
function saveCutterType(value) {
  try {
    const configDir = path.dirname(CUTTER_CONFIG_FILE);
    if (!fs.existsSync(configDir)) {
      fs.mkdirSync(configDir, { recursive: true, mode: 0o777 });
    }
    fs.writeFileSync(
      CUTTER_CONFIG_FILE,
      JSON.stringify(
        { cutterType: value, timestamp: new Date().toISOString() },
        null,
        2,
      ),
      { mode: 0o666 },
    );
    log(`Saved cutter type to config: ${value}`);
  } catch (err) {
    log(`Failed to save cutter type: ${err.message}`, "ERROR");
  }
}

/**
 * Load volume setting from config file
 */
function loadVolume() {
  try {
    if (fs.existsSync(VOLUME_CONFIG_FILE)) {
      const data = JSON.parse(fs.readFileSync(VOLUME_CONFIG_FILE, "utf8"));
      if (
        typeof data.volume === "number" &&
        data.volume >= 0 &&
        data.volume <= 8
      ) {
        currentVolume = data.volume;
        log(`Loaded volume setting from config: ${currentVolume}`);
      }
    }
  } catch (err) {
    log(`Failed to load volume setting: ${err.message}`, "ERROR");
  }
}

/**
 * Save volume setting to config file
 */
function saveVolume(value) {
  try {
    const configDir = path.dirname(VOLUME_CONFIG_FILE);
    if (!fs.existsSync(configDir)) {
      fs.mkdirSync(configDir, { recursive: true, mode: 0o777 });
    }
    fs.writeFileSync(
      VOLUME_CONFIG_FILE,
      JSON.stringify(
        { volume: value, timestamp: new Date().toISOString() },
        null,
        2,
      ),
      { mode: 0o666 },
    );
    log(`Saved volume setting to config: ${value}`);
  } catch (err) {
    log(`Failed to save volume setting: ${err.message}`, "ERROR");
  }
}

// UUIDs for WiFi Configuration Service
const WIFI_SERVICE_UUID = "8f4c9b0e-5e57-4f9f-9a2a-4b6f8de9a3c1";
const SSID_CHAR_UUID = "0e2f3e4b-d9e2-4d0c-8a6c-2bbd2f40c3a7";
const PASSWORD_CHAR_UUID = "9c0fb5a7-6be4-4a38-b5d2-1c8af8d2a0bd";
const APPLY_CHAR_UUID = "3b1f7d6e-2cda-43c7-8c92-d0f7b8c0b6d2";
const STATUS_CHAR_UUID = "a2e6d8f3-71ac-4c17-8d79-7d7f4f5c2e43";
const CONFIG_STATUS_CHAR_UUID = "c4d5e6f7-8a9b-0c1d-2e3f-4a5b6c7d8e9f";
const SCAN_CHAR_UUID = "b3d4f5e6-7a8b-9c0d-1e2f-3a4b5c6d7e8f";
const CUTTER_TYPE_CHAR_UUID = "e1f2a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b";
const SOUND_CHAR_UUID = "f2a3b4c5-6d7e-8f9a-0b1c-2d3e4f5a6b7c";
const DIAGNOSTICS_CHAR_UUID = "d1a2b3c4-5e6f-7a8b-9c0d-1e2f3a4b5c6d";
const RESET_CHAR_UUID = "a1b2c3d4-e5f6-7a8b-9c0d-2e3f4a5b6c7d";

// Health data file path
const HEALTH_JSON_PATH = "/usr/local/lib/eatabit/health.json";

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
 * Create Cutter Type Characteristic (Read/Write)
 * Allows clients to get/set the printer cutter type: "partial", "full", or "none"
 */
function createCutterTypeCharacteristic() {
  return new bleno.Characteristic({
    uuid: CUTTER_TYPE_CHAR_UUID,
    properties: ["read", "write"],
    onReadRequest: (offset, callback) => {
      log(`Cutter type read request, current: ${currentCutterType}`);
      const buffer = Buffer.from(currentCutterType);
      callback(bleno.Characteristic.RESULT_SUCCESS, buffer);
    },
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      const value = data.toString("utf8").trim();
      if (["partial", "full", "none"].includes(value)) {
        currentCutterType = value;
        saveCutterType(currentCutterType);
        log(`Cutter type written: ${currentCutterType}`);
        callback(bleno.Characteristic.RESULT_SUCCESS);
      } else {
        log(`Invalid cutter type value: ${value}`, "ERROR");
        callback(bleno.Characteristic.RESULT_UNLIKELY_ERROR);
      }
    },
  });
}

/**
 * Create Volume Characteristic (Read/Write)
 * Allows clients to get/set the printer volume: 0-8 (0=off, 1-8=volume level)
 */
function createVolumeCharacteristic() {
  return new bleno.Characteristic({
    uuid: SOUND_CHAR_UUID,
    properties: ["read", "write"],
    onReadRequest: (offset, callback) => {
      log(`Volume read request, current: ${currentVolume}`);
      const buffer = Buffer.from(String(currentVolume));
      callback(bleno.Characteristic.RESULT_SUCCESS, buffer);
    },
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      const value = parseInt(data.toString("utf8").trim(), 10);
      if (!isNaN(value) && value >= 0 && value <= 8) {
        currentVolume = value;
        saveVolume(currentVolume);
        log(`Volume written: ${currentVolume}`);
        callback(bleno.Characteristic.RESULT_SUCCESS);
      } else {
        log(`Invalid volume value: ${value}`, "ERROR");
        callback(bleno.Characteristic.RESULT_UNLIKELY_ERROR);
      }
    },
  });
}

/**
 * Format bytes to human-readable string
 */
function formatBytes(bytes) {
  if (bytes === null || bytes === undefined) return "N/A";
  const units = ["B", "KB", "MB", "GB"];
  let unitIndex = 0;
  let value = bytes;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return `${value.toFixed(1)} ${units[unitIndex]}`;
}

/**
 * Query live WiFi state from system commands
 */
function getWifiConfiguration() {
  try {
    // Get connected WiFi SSID
    const iwconfig = execSync("iwconfig wlan0 2>/dev/null || echo ''", {
      encoding: "utf8",
      shell: "/bin/bash",
    }).trim();

    const ssidMatch = iwconfig.match(/ESSID:"([^"]*)"/);
    const ssid = ssidMatch ? ssidMatch[1] : null;

    // Get WiFi signal strength
    const iwlist = execSync(
      "iwlist wlan0 last 2>/dev/null | grep 'Signal level' || echo ''",
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();

    const signalMatch = iwlist.match(/Signal level[=:]\s*([-\d]+)/);
    const signalStrength = signalMatch ? parseInt(signalMatch[1]) : null;

    // Get IP configuration
    const ipaddr = execSync(
      "ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo ''",
      { encoding: "utf8", shell: "/bin/bash" }
    )
      .trim()
      .split("\n")[0];

    // Get gateway
    const gateway = execSync(
      "ip route show 2>/dev/null | grep default | awk '{print $3}' || echo ''",
      { encoding: "utf8", shell: "/bin/bash" }
    )
      .trim()
      .split("\n")[0];

    // Get DNS servers
    const dns = execSync(
      "cat /etc/resolv.conf 2>/dev/null | grep nameserver | awk '{print $2}' || echo ''",
      { encoding: "utf8", shell: "/bin/bash" }
    )
      .trim()
      .split("\n")
      .filter((x) => x);

    // Get WiFi connection quality
    const quality = execSync(
      "iwconfig wlan0 2>/dev/null | grep 'Link Quality' | sed 's/.*Link Quality=\\([^ ]*\\).*/\\1/' || echo ''",
      { encoding: "utf8", shell: "/bin/bash" }
    )
      .trim();

    return {
      connected: ssid !== null && ssid !== "",
      ssid: ssid,
      ipAddress: ipaddr || null,
      gateway: gateway || null,
      dnsServers: dns,
      signalStrength: signalStrength,
      linkQuality: quality || null,
    };
  } catch (err) {
    return {
      connected: false,
      error: err.message,
    };
  }
}

/**
 * Print diagnostics page to thermal printer
 * Reads health.json and formats it for thermal output with partial cut
 */
function printDiagnostics() {
  try {
    log("Printing diagnostics page...");

    // Read health data
    let healthData = {};
    if (fs.existsSync(HEALTH_JSON_PATH)) {
      healthData = JSON.parse(fs.readFileSync(HEALTH_JSON_PATH, "utf8"));
    } else {
      log("Health data file not found", "WARN");
    }

    // Read device ID
    let deviceId = "Unknown";
    try {
      deviceId = fs
        .readFileSync("/usr/local/lib/eatabit/deviceid", "utf8")
        .trim();
    } catch (e) {
      log("Could not read device ID", "WARN");
    }

    // Read build version
    let buildVersion = "Unknown";
    try {
      buildVersion = fs
        .readFileSync("/usr/local/lib/eatabit/version", "utf8")
        .trim();
    } catch (e) {
      log("Could not read build version", "WARN");
    }

    // ESC/POS commands
    const ESC = 0x1b;
    const GS = 0x1d;

    // Initialize printer
    const init = Buffer.from([ESC, 0x40]); // ESC @ - Initialize

    // Bold on/off
    const boldOn = Buffer.from([ESC, 0x45, 0x01]); // ESC E 1
    const boldOff = Buffer.from([ESC, 0x45, 0x00]); // ESC E 0

    // Center alignment
    const centerAlign = Buffer.from([ESC, 0x61, 0x01]); // ESC a 1
    const leftAlign = Buffer.from([ESC, 0x61, 0x00]); // ESC a 0

    // Double height/width for title
    const doubleSize = Buffer.from([GS, 0x21, 0x11]); // GS ! 0x11
    const normalSize = Buffer.from([GS, 0x21, 0x00]); // GS ! 0x00

    // Partial cut command
    const partialCut = Buffer.from([GS, 0x56, 0x01]); // GS V 1

    // Build diagnostic content
    const lines = [];

    // Title
    lines.push(init);
    lines.push(centerAlign);
    lines.push(doubleSize);
    lines.push(boldOn);
    lines.push(Buffer.from("DIAGNOSTICS\n"));
    lines.push(normalSize);
    lines.push(boldOff);
    lines.push(Buffer.from("================================\n"));
    lines.push(leftAlign);

    // Timestamp
    lines.push(Buffer.from(`Date: ${new Date().toLocaleString()}\n`));
    lines.push(Buffer.from(`Device: ${deviceId}\n`));
    lines.push(Buffer.from(`Version: ${buildVersion}\n`));
    lines.push(Buffer.from("--------------------------------\n"));

    // System info
    lines.push(boldOn);
    lines.push(Buffer.from("SYSTEM\n"));
    lines.push(boldOff);

    if (healthData.system) {
      const sys = healthData.system;

      // Uptime (sys.uptime is an object with {seconds, formatted})
      if (sys.uptime && sys.uptime.formatted) {
        lines.push(Buffer.from(`Uptime: ${sys.uptime.formatted}\n`));
      }

      // Load average (array of 3 numbers)
      if (sys.loadAverage && Array.isArray(sys.loadAverage)) {
        const load = sys.loadAverage.map((l) => l.toFixed(2)).join(", ");
        lines.push(Buffer.from(`Load: ${load}\n`));
      }

      // Memory (totalMemory and freeMemory in bytes)
      if (sys.totalMemory && sys.freeMemory !== undefined) {
        const usedMem = sys.totalMemory - sys.freeMemory;
        lines.push(
          Buffer.from(
            `Memory: ${formatBytes(usedMem)} / ${formatBytes(sys.totalMemory)}\n`,
          ),
        );
      }

      // Disk (sys.disk.root has total, used, free, usagePercent)
      if (sys.disk && sys.disk.root) {
        const root = sys.disk.root;
        if (root.usagePercent !== null) {
          lines.push(
            Buffer.from(
              `Disk: ${formatBytes(root.used)} / ${formatBytes(root.total)} (${root.usagePercent}%)\n`,
            ),
          );
        }
      }

      // CPU count
      if (sys.cpuCount) {
        lines.push(Buffer.from(`CPUs: ${sys.cpuCount}\n`));
      }
    } else {
      lines.push(Buffer.from("No system data available\n"));
    }

    lines.push(Buffer.from("--------------------------------\n"));

    // Network info
    lines.push(boldOn);
    lines.push(Buffer.from("NETWORK\n"));
    lines.push(boldOff);

    const wifi = getWifiConfiguration();
    if (wifi) {
      // Connection status
      lines.push(
        Buffer.from(`WiFi: ${wifi.connected ? "Connected" : "Disconnected"}\n`),
      );

      if (wifi.connected) {
        if (wifi.ssid) {
          lines.push(Buffer.from(`SSID: ${wifi.ssid}\n`));
        }
        if (wifi.ipAddress) {
          lines.push(Buffer.from(`IP: ${wifi.ipAddress}\n`));
        }
        if (wifi.gateway) {
          lines.push(Buffer.from(`Gateway: ${wifi.gateway}\n`));
        }
        if (wifi.signalStrength !== null) {
          lines.push(Buffer.from(`Signal: ${wifi.signalStrength} dBm\n`));
        }
        if (wifi.linkQuality) {
          lines.push(Buffer.from(`Quality: ${wifi.linkQuality}\n`));
        }
      }
    } else {
      lines.push(Buffer.from("No network data available\n"));
    }

    lines.push(Buffer.from("--------------------------------\n"));

    // Services info
    lines.push(boldOn);
    lines.push(Buffer.from("SERVICES\n"));
    lines.push(boldOff);

    if (healthData.services) {
      for (const [name, svc] of Object.entries(healthData.services)) {
        // Service status is an object with {active, enabled, state, ...}
        if (typeof svc === "object" && svc !== null) {
          const statusStr = svc.active ? "Running" : "Stopped";
          lines.push(Buffer.from(`${name}: ${statusStr}\n`));
        } else {
          // Fallback for simple boolean
          const statusStr = svc ? "Running" : "Stopped";
          lines.push(Buffer.from(`${name}: ${statusStr}\n`));
        }
      }
    } else {
      lines.push(Buffer.from("No service data available\n"));
    }

    lines.push(Buffer.from("--------------------------------\n"));

    // Device info
    lines.push(boldOn);
    lines.push(Buffer.from("DEVICE\n"));
    lines.push(boldOff);

    if (healthData.device) {
      const dev = healthData.device;
      if (dev.hostname) lines.push(Buffer.from(`Hostname: ${dev.hostname}\n`));
      if (dev.platform) lines.push(Buffer.from(`Platform: ${dev.platform}\n`));
      if (dev.arch) lines.push(Buffer.from(`Arch: ${dev.arch}\n`));
    } else {
      lines.push(Buffer.from("No device data available\n"));
    }

    if (deviceId && deviceId !== "Unknown") {
      // Device ID QR code
      const deviceIdData = Buffer.from(deviceId, "utf8");
      const deviceIdDataLen = deviceIdData.length + 3;

      // Set QR code model (Model 2)
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]));
      // Set QR code size (module size 6)
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x43, 0x06]));
      // Set error correction level (L = 48)
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x45, 0x30]));
      // Store QR code data
      lines.push(Buffer.from([GS, 0x28, 0x6b, deviceIdDataLen & 0xff, (deviceIdDataLen >> 8) & 0xff, 0x31, 0x50, 0x30]));
      lines.push(deviceIdData);
      // Print QR code
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x51, 0x30]));
    }

    // Printer serial number QR code
    lines.push(Buffer.from("--------------------------------\n"));
    lines.push(boldOn);
    lines.push(Buffer.from("PRINTER SERIAL\n"));
    lines.push(boldOff);

    let serialNumber = "";
    try {
      serialNumber = execSync(
        "udevadm info --name=/dev/usb/lp0 --attribute-walk | grep -i '{serial}' | head -1 | awk -F'\"' '{print $2}'",
        { encoding: "utf8", shell: "/bin/bash" },
      ).trim();
    } catch (e) {
      log("Could not read printer serial number", "WARN");
    }

    if (serialNumber) {
      lines.push(Buffer.from(`S/N: ${serialNumber}\n`));

      // ESC/POS QR code: GS ( k
      const qrData = Buffer.from(serialNumber, "utf8");
      const qrDataLen = qrData.length + 3; // pL pH = data length + 3

      // Set QR code model (Model 2)
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]));
      // Set QR code size (module size 6)
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x43, 0x06]));
      // Set error correction level (L = 48)
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x45, 0x30]));
      // Store QR code data
      lines.push(Buffer.from([GS, 0x28, 0x6b, qrDataLen & 0xff, (qrDataLen >> 8) & 0xff, 0x31, 0x50, 0x30]));
      lines.push(qrData);
      // Print QR code
      lines.push(Buffer.from([GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x51, 0x30]));
    } else {
      lines.push(Buffer.from("S/N: Not available\n"));
    }

    lines.push(Buffer.from("\n"));
    lines.push(centerAlign);
    lines.push(Buffer.from("================================\n"));
    lines.push(Buffer.from("End of Diagnostics\n"));
    lines.push(Buffer.from("\n\n\n\n\n\n")); // Feed paper

    // Partial cut
    lines.push(partialCut);

    // Write to printer
    const output = Buffer.concat(lines);
    fs.writeFileSync("/dev/usb/lp0", output);

    log("Diagnostics page printed successfully");
    return true;
  } catch (err) {
    log(`Failed to print diagnostics: ${err.message}`, "ERROR");
    return false;
  }
}

/**
 * Create Diagnostics Characteristic (Write-Only)
 * Writing any value triggers a diagnostics page print
 */
function createDiagnosticsCharacteristic() {
  return new bleno.Characteristic({
    uuid: DIAGNOSTICS_CHAR_UUID,
    properties: ["write"],
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      log("Diagnostics print requested via BLE");
      const success = printDiagnostics();
      if (success) {
        callback(bleno.Characteristic.RESULT_SUCCESS);
      } else {
        callback(bleno.Characteristic.RESULT_UNLIKELY_ERROR);
      }
    },
  });
}

/**
 * Remove all configured WiFi networks and reboot the device
 */
function resetDevice() {
  try {
    log("Resetting device: removing all WiFi networks...");

    // Get all WiFi connection profiles
    const profiles = execSync("nmcli -t -f TYPE,NAME con show", {
      encoding: "utf8",
      shell: "/bin/bash",
    });

    const wifiProfiles = profiles
      .split("\n")
      .filter((line) => line.trim())
      .filter((line) => {
        const type = line.split(":")[0];
        return type === "802-11-wireless" || type === "wifi";
      })
      .map((line) => line.split(":").slice(1).join(":"));

    // Delete each WiFi profile
    for (const profile of wifiProfiles) {
      try {
        log(`Deleting WiFi profile: ${profile}`);
        execSync(`nmcli con delete "${profile}"`, {
          encoding: "utf8",
          shell: "/bin/bash",
        });
      } catch (err) {
        log(`Failed to delete profile ${profile}: ${err.message}`, "ERROR");
      }
    }

    log(`Removed ${wifiProfiles.length} WiFi profile(s)`);

    // Record lastResetAt timestamp in health.json
    try {
      let healthData = {};
      if (fs.existsSync(HEALTH_JSON_PATH)) {
        healthData = JSON.parse(fs.readFileSync(HEALTH_JSON_PATH, "utf8"));
      }
      healthData.lastResetAt = new Date().toISOString();
      fs.writeFileSync(HEALTH_JSON_PATH, JSON.stringify(healthData, null, 2), {
        mode: 0o644,
      });
      log("Recorded lastResetAt in health.json");
    } catch (err) {
      log(
        `Failed to write lastResetAt to health.json: ${err.message}`,
        "ERROR",
      );
    }

    log("Rebooting device in 3 seconds...");

    // Reboot after brief delay to allow BLE response to be sent
    setTimeout(() => {
      try {
        execSync("shutdown -r now", { shell: "/bin/bash" });
      } catch (err) {
        log(`Failed to reboot: ${err.message}`, "ERROR");
      }
    }, 3000);

    return true;
  } catch (err) {
    log(`Failed to reset device: ${err.message}`, "ERROR");
    return false;
  }
}

/**
 * Create Reset Characteristic (Write-Only)
 * Writing any value removes all WiFi networks and reboots
 */
function createResetCharacteristic() {
  return new bleno.Characteristic({
    uuid: RESET_CHAR_UUID,
    properties: ["write"],
    onWriteRequest: (data, offset, withoutResponse, callback) => {
      log("Device reset requested via BLE");
      const success = resetDevice();
      if (success) {
        callback(bleno.Characteristic.RESULT_SUCCESS);
      } else {
        callback(bleno.Characteristic.RESULT_UNLIKELY_ERROR);
      }
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
      createCutterTypeCharacteristic(),
      createVolumeCharacteristic(),
      createDiagnosticsCharacteristic(),
      createResetCharacteristic(),
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

    // Load cutter type from config file
    loadCutterType();

    // Load volume setting from config file
    loadVolume();

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
