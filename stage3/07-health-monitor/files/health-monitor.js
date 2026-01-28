#!/usr/bin/env node

/**
 * Health Monitor Service
 *
 * Collects system health data and writes it to /usr/local/lib/eatabit/health.json
 *
 * IMPORTANT: The health data schema is consumed by the following services:
 *   - mqtt-client (stage3/03-install-mqtt-client) - publishes health data to AWS IoT
 *   - ble-config (stage3/08-ble-config) - prints diagnostics page to thermal printer
 *
 * If you modify the health data schema, you MUST update these dependent services
 * to handle the new structure.
 */

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const os = require("os");

// Configuration
const HEALTH_JSON_PATH = "/usr/local/lib/eatabit/health.json";
const HEALTH_DIR = path.dirname(HEALTH_JSON_PATH);

/**
 * Collect health data about the Raspberry Pi device
 */
async function collectHealthData() {
  const healthData = {
    timestamp: new Date().toISOString(),
    device: {
      hostname: os.hostname(),
      platform: os.platform(),
      arch: os.arch(),
      type: os.type(),
    },
    system: {
      uptime: getSystemUptime(),
      loadAverage: os.loadavg(),
      totalMemory: os.totalmem(),
      freeMemory: os.freemem(),
      cpuCount: os.cpus().length,
      disk: getDiskUsage(),
    },
    services: {
      mqttClient: getMqttClientStatus(),
    },
    network: {
      wifi: getWifiConfiguration(),
    },
  };

  return healthData;
}

/**
 * Get system uptime in seconds
 */
function getSystemUptime() {
  try {
    const uptime = os.uptime();
    return {
      seconds: Math.floor(uptime),
      formatted: formatUptime(uptime),
    };
  } catch (err) {
    return {
      seconds: null,
      formatted: null,
      error: err.message,
    };
  }
}

/**
 * Format uptime in human-readable format
 */
function formatUptime(seconds) {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);

  return `${days}d ${hours}h ${minutes}m ${secs}s`;
}

/**
 * Get disk usage for root filesystem and eatabit directory
 */
function getDiskUsage() {
  try {
    // Get root filesystem usage
    const dfRoot = execSync(
      "df / 2>/dev/null | tail -1 | awk '{print $2, $3, $4, $5}'" || "echo ''",
      { encoding: "utf8", shell: "/bin/bash" }
    )
      .trim()
      .split(/\s+/);

    const rootTotal = dfRoot[0] ? parseInt(dfRoot[0]) * 1024 : null;
    const rootUsed = dfRoot[1] ? parseInt(dfRoot[1]) * 1024 : null;
    const rootFree = dfRoot[2] ? parseInt(dfRoot[2]) * 1024 : null;
    const rootUsagePercent = dfRoot[3] ? parseInt(dfRoot[3]) : null;

    // Get eatabit directory usage
    let eatabitSize = null;
    let eatabitUsagePercent = null;
    try {
      const eatabitUsage = execSync(
        "du -sb /usr/local/lib/eatabit 2>/dev/null | awk '{print $1}' || echo '0'",
        { encoding: "utf8", shell: "/bin/bash" }
      )
        .trim();
      eatabitSize = parseInt(eatabitUsage);

      if (rootTotal && eatabitSize) {
        eatabitUsagePercent = Math.round((eatabitSize / rootTotal) * 100);
      }
    } catch (err) {
      // Ignore error if eatabit directory doesn't exist
    }

    // Get /var/log usage
    let varLogSize = null;
    try {
      const varLogUsage = execSync(
        "du -sb /var/log 2>/dev/null | awk '{print $1}' || echo '0'",
        { encoding: "utf8", shell: "/bin/bash" }
      )
        .trim();
      varLogSize = parseInt(varLogUsage);
    } catch (err) {
      // Ignore error
    }

    return {
      root: {
        total: rootTotal,
        used: rootUsed,
        free: rootFree,
        usagePercent: rootUsagePercent,
      },
      eatabit: {
        size: eatabitSize,
        usagePercent: eatabitUsagePercent,
      },
      varLog: {
        size: varLogSize,
      },
    };
  } catch (err) {
    return {
      error: err.message,
    };
  }
}

/**
 * Get status of mqtt-client systemctl service
 */
function getMqttClientStatus() {
  try {
    const isActive = execSync(
      "systemctl is-active mqtt-client 2>/dev/null || echo 'inactive'",
      { encoding: "utf8", shell: "/bin/bash" }
    )
      .trim()
      .toLowerCase();

    const isEnabled = execSync(
      "systemctl is-enabled mqtt-client 2>/dev/null || echo 'disabled'",
      { encoding: "utf8", shell: "/bin/bash" }
    )
      .trim()
      .toLowerCase();

    // Get service status details
    const statusOutput = execSync(
      "systemctl show mqtt-client --no-pager 2>/dev/null || echo ''",
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();

    const lines = statusOutput.split("\n");
    const statusMap = {};
    lines.forEach((line) => {
      const [key, value] = line.split("=");
      if (key && value) {
        statusMap[key] = value;
      }
    });

    return {
      active: isActive === "active",
      enabled: isEnabled === "enabled",
      state: isActive,
      mainPID: statusMap["MainPID"] || null,
      memoryUsage: statusMap["MemoryCurrent"] || null,
      cpuUsageNsec: statusMap["CPUUsageNSec"] || null,
      restartCount: statusMap["NRestarts"] || "0",
      lastTimestamp: statusMap["StateChangeTimestamp"] || null,
    };
  } catch (err) {
    return {
      active: false,
      enabled: false,
      error: err.message,
    };
  }
}

/**
 * Get current WiFi configuration
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
 * Write health data to JSON file
 */
function writeHealthFile(healthData) {
  try {
    // Ensure directory exists
    if (!fs.existsSync(HEALTH_DIR)) {
      fs.mkdirSync(HEALTH_DIR, { recursive: true, mode: 0o755 });
    }

    // Write JSON file
    fs.writeFileSync(
      HEALTH_JSON_PATH,
      JSON.stringify(healthData, null, 2),
      { mode: 0o644 }
    );

    console.log(`Health data written to ${HEALTH_JSON_PATH}`);
    return true;
  } catch (err) {
    console.error(`Failed to write health file: ${err.message}`);
    return false;
  }
}

/**
 * Main entry point
 */
async function main() {
  try {
    const healthData = await collectHealthData();
    const success = writeHealthFile(healthData);

    if (success) {
      process.exit(0);
    } else {
      process.exit(1);
    }
  } catch (err) {
    console.error(`Health monitor failed: ${err.message}`);
    process.exit(1);
  }
}

main();
