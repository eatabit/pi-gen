#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { mqtt, io, iot } = require("aws-iot-device-sdk-v2");
const { execSync } = require("child_process");
const ngrok = require("@ngrok/ngrok");
// sd_notify via systemd-notify CLI — no native addons or libsystemd-dev required.
// systemd-notify is pre-installed on all systemd-based systems.
const SdNotify = {
  ready() {
    try {
      execSync("systemd-notify --ready", { stdio: "ignore" });
    } catch {}
  },
  watchdog() {
    try {
      execSync("systemd-notify WATCHDOG=1", { stdio: "ignore" });
    } catch {}
  },
};

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
const VERSION_FILE = `${EATABIT_DIR}/version`;
const STATUS_LED_SCRIPT = `${EATABIT_DIR}/bin/status-led.sh`;

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
  STALE_URL: "STALE_URL",
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

// Control status LED via systemd services
function setStatusLedConnected() {
  try {
    execSync(
      "systemctl stop status-led-ok.service 2>/dev/null; " +
        `${STATUS_LED_SCRIPT} green`,
      { shell: "/bin/bash" },
    );
  } catch (err) {
    log(`Failed to set status LED to green: ${err.message}`, "ERROR");
  }
}

function setStatusLedDisconnected() {
  try {
    execSync("systemctl restart status-led-ok.service", { shell: "/bin/bash" });
  } catch (err) {
    log(`Failed to restore status LED to flash-blue: ${err.message}`, "ERROR");
  }
}

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

// Read image version from file
let IMAGE_VERSION;
try {
  IMAGE_VERSION = fs.readFileSync(VERSION_FILE, "utf8").trim();
  if (!IMAGE_VERSION) {
    throw new Error("Version file is empty");
  }
  log(`Image version: ${IMAGE_VERSION}`);
} catch (err) {
  log(`Failed to read image version: ${err.message}`, "ERROR");
  IMAGE_VERSION = "unknown";
}

// MQTT topics
const TOPIC_PREFIX = `$aws/things/${DEVICE_ID}`;

// Shadow topics (outbound)
const PUBLIC_SHADOW_PREFIX = `${TOPIC_PREFIX}/shadow/name/public`;
const PRIVATE_SHADOW_PREFIX = `${TOPIC_PREFIX}/shadow/name/private`;
const HEALTH_SHADOW_PREFIX = `${TOPIC_PREFIX}/shadow/name/health`;

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
    properties: ["apiId", "deviceId", "imageVersion"],
    state: {
      apiId: "",
      deviceId: "",
      imageVersion: IMAGE_VERSION,
    },
  },
  health: {
    name: "health",
    properties: [], // Read-only from cloud side, no desired state
    state: {},
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
  0x76, 0x65, 0x5f, 0x70, 0x61, 0x72, 0x61, 0x6d, 0x5f, 0x7a, 0x6f, 0x6e, 0x65,
  0x22, 0x0d, 0x0a,
]);

// Restart printer command (required after speaker ON/OFF changes)
const RESTART_PRINTER_CMD = Buffer.from([
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
  commands.push(RESTART_PRINTER_CMD);

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
  `${HEALTH_SHADOW_PREFIX}/update/delta`,
];

// Events topic (outbound)
const EVENTS_TOPIC = `eatabit/things/${DEVICE_ID}/events`;

log(`Starting Eatabit AWS IoT Client for device: ${DEVICE_ID}`);

// Global connection reference for publishing
let mqttConnection;

// --- ngrok tunnel state and helpers (BUG-049) --------------------------------
//
// This block replaces a bare `let ngrokListener = null`. Three defects lived on that
// one global, and all three are fixed here rather than around the call sites.
//
// 1. THE AGENT SESSION OUTLIVED ITS TUNNEL. `ngrok.forward()` creates an implicit,
//    process-global default session and hands back only a Listener. Closing that
//    listener leaves the session connected, and @ngrok/ngrok exposes no way to reach
//    the implicit session it created: `ngrok.disconnect()` and `ngrok.kill()` both
//    close LISTENERS, not sessions (verified against the installed 1.7.0 index.d.ts,
//    whose own doc comments read "Close a listener with the given url, or all
//    listeners if no url is defined" and "Close all listeners"). So every stop leaked
//    a session; once enough stale sessions accumulated, every later forward() in the
//    process failed until mqtt-client restarted. Measured on the fleet: both LAN
//    printers holding sessions with NO tunnels attached, one orphan alive two days.
//
//    The fix is to stop using the implicit session at all. We build our OWN session
//    with SessionBuilder, keep it beside its listener, and close BOTH on stop.
//
//    BUG-035's reaper does not help here: it reclaims ngrok CREDENTIALS, not
//    sessions. A clean credential ledger says nothing about how many stale agent
//    sessions a device is holding. That distinction is the whole bug.
//
// 2. THE HANDLE WAS RACED. `if (ngrokListener)` was tested and then reassigned across
//    an `await`, in both the start and the stop handler, so two concurrent starts
//    could each open a tunnel while the loser's handle was overwritten -- leaving a
//    live tunnel that nothing held a reference to and nothing could close.
//    Production-confirmed: two live tunnels from pid 124474. Fixed by funnelling
//    every ngrok operation through runNgrokOp() below, so the handle is single-writer.
//
// 3. THE CALLS WERE UNBOUNDED. An ngrok call that never returned left the
//    DeviceCommand at `sent` forever -- observed 2026-08-20, a stopNgrokTunnel still
//    `sent` an hour later. Fixed by withTimeout() below, which always publishes a
//    terminal status.

// The live tunnel, or null. Written ONLY from inside runNgrokOp(), which is what makes
// it impossible to overwrite a handle that has not been closed.
let ngrokTunnel = null; // { session, listener, url }

// Serialises every ngrok operation: a start and a stop can no longer interleave. Each
// operation runs after the previous one settles, whether it resolved or rejected --
// hence the same callback in both slots of .then(). A rejected op must not poison the
// chain for every later command.
let ngrokOpChain = Promise.resolve();

function runNgrokOp(fn) {
  const result = ngrokOpChain.then(fn, fn);
  ngrokOpChain = result.then(
    () => {},
    () => {},
  );
  return result;
}

// Bounds on the ngrok calls, chosen against the CLOUD-side execution timeout: a
// device-side bound LONGER than the command's executionTimeoutSeconds publishes into a
// window that has already closed and buys nothing.
//
//   startNgrokTunnel -- executionTimeoutSeconds = 60, set explicitly in iot-backend
//                       (START_NGROK_TUNNEL_TIMEOUT_SECONDS in
//                       onDeviceCommandCreated/sendCommand/src/lib/tunnelStartLock.ts).
//   stopNgrokTunnel  -- deliberately left at AWS's 10 s default.
//
// A healthy start completes in ~2 s and a slow bench run took 7.25 s, so 15 s per build
// step is generous and the two together still leave half the cloud window spare.
// Teardown is two RPCs bounded at 4 s each, so a worst-case stop answers in 8 s --
// inside the 10 s stop window, which is the tighter of the two and therefore the one
// that sets the budget.
//
// The build is bounded PER STEP rather than as a whole on purpose. An outer race around
// the entire build would abandon a build that had already connected, and the session it
// went on to create would be untracked and unclosable -- reintroducing this very bug on
// the timeout path. Bounding each step keeps us inside buildNgrokTunnel()'s catch, where
// whatever was created can still be torn down.
//
// 25 s for connect, widened from 15 s: healthy connects measure 191 ms to 7.25 s, so
// this is ~3x the slowest healthy case and it leaves 20 s of the cloud window spare at
// 25 + 15 = 40 s worst case. **It does NOT rescue v1.1.0's ~811 s stall** (BUG-048), and
// no value that fits inside a 60 s cloud window could -- a start that slow can never be
// reported as success. What makes that case safe is reclaimStranded() below, not the
// bound.
const NGROK_CONNECT_TIMEOUT_MS = 25000;
const NGROK_LISTEN_TIMEOUT_MS = 15000;
const NGROK_CLOSE_TIMEOUT_MS = 4000;

// What the tunnel points at on the device: the local SSH daemon. Plain host:port, not a
// URL -- Listener.forward() is documented as taking "a TCP address or a file socket
// path", and the SDK's own TCP example passes a bare address.
const NGROK_FORWARD_ADDR = "localhost:22";

// Bound a promise. NOTE: the underlying call is native and cannot be cancelled, so on
// expiry it keeps running in the background -- we stop WAITING for it, we do not stop
// it. That is the right trade: an unbounded wait is what left a DeviceCommand at `sent`
// forever, and a command that answers late is worse than one that answers FAILED.
//
// `onAbandon`, when given, is called with the promise's eventual value IF the bound
// expired first. That is what stops an abandoned call from leaking whatever it goes on
// to create. `expired` is set only by the timer, never by the success path, so a call
// that finishes in time never triggers it -- do not rewrite this as a flag set after
// the await, which would race the promise's own continuation and reclaim a resource we
// are about to use.
function withTimeout(promise, ms, label, onAbandon) {
  let timer;
  let expired = false;
  const expiry = new Promise((_resolve, reject) => {
    timer = setTimeout(() => {
      expired = true;
      const err = new Error(`${label} timed out after ${ms} ms`);
      err.ngrokTimeout = true;
      reject(err);
    }, ms);
  });
  if (onAbandon) {
    promise.then(
      (value) => {
        if (expired) onAbandon(value);
      },
      () => {},
    );
  }
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer));
}

// Reclaim something a bounded ngrok call produced AFTER we stopped waiting for it.
//
// WHY THIS EXISTS, measured rather than theorised. The first cut of this fix bounded
// connect() and simply walked away on expiry, with a comment calling the leftover
// session a small "residual leak ... 15 s wide against a call that normally takes ~2 s".
// On v1.1.0 firmware that call does not take ~2 s: BUG-048 measured it blocking ~811 s,
// and a patched v1.1.0 device in the field reproduced it exactly -- its credential was
// minted at 18:07:57Z and the session it created finally appeared at 18:21:28Z, 811 s
// later, with no listener and nothing holding a reference to it.
//
// So the residual was not small: on that firmware EVERY start leaked exactly one
// session, which is this record's own defect reintroduced on the timeout path. And it
// is unrecoverable -- @ngrok/ngrok cannot enumerate sessions, deleting the owning
// credential does NOT terminate the session (verified against the ngrok API), and
// BUG-035's reaper reclaims credentials only. Nothing but a device restart clears it.
//
// Fire-and-forget on purpose: nobody is waiting on this path any more, and the command
// it belonged to has already published its terminal status.
function reclaimStranded(what, resource) {
  if (!resource) return;
  log(
    `ngrok ${what} returned AFTER its timeout -- closing the stranded ${what}`,
    "WARN",
  );
  Promise.resolve()
    .then(() => resource.close())
    .then(
      () => log(`stranded ngrok ${what} closed`),
      (err) =>
        log(
          `failed to close stranded ngrok ${what}: ${err.message} -- it may persist until this process restarts`,
          "ERROR",
        ),
    );
}

// AWS IoT validates StatusReason, and getting it wrong replaces a useless reason with
// NO reason -- strictly worse than the hardcoded string this fix removes. Per the AWS
// IoT API reference (StatusReason, retrieved 2026-08-20):
//
//   reasonCode        max 64,   pattern [A-Z0-9_-]+ , REQUIRED
//   reasonDescription max 1024, pattern [^\p{C}]*   , optional
//
// The PATTERN is the trap here, not the length: \p{C} excludes every control
// character, and a raw err.message routinely contains newlines. So sanitize before
// publishing, always.
const NGROK_REASON_MAX = 1000; // under the documented 1024, with margin

function statusReasonText(text, fallback) {
  const cleaned = String(text === undefined || text === null ? "" : text)
    .replace(/\p{C}+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return fallback;
  // Slice by code POINT, not code unit: cutting a surrogate pair in half emits a lone
  // surrogate and fails validation for a different reason than the one we avoided.
  return Array.from(cleaned).slice(0, NGROK_REASON_MAX).join("");
}

// reasonCode values. Every one must match [A-Z0-9_-]+ -- a lowercase code is REJECTED.
// "200"/"500" are kept exactly as they were so nothing downstream has to change; the
// symbolic codes are additive.
const NGROK_REASON = {
  OK: "200",
  ERROR: "500",
  TIMEOUT: "504",
  NO_TUNNEL_ACTIVE: "NO_TUNNEL_ACTIVE",
  MISSING_AUTHTOKEN: "MISSING_AUTHTOKEN",
};

function ngrokFailureCode(err) {
  return err && err.ngrokTimeout ? NGROK_REASON.TIMEOUT : NGROK_REASON.ERROR;
}

// Close a tunnel AND RECLAIM ITS SESSION. Both, always -- and the session even when the
// listener close fails, because an abandoned session is precisely the leak this record
// exists to stop. Never throws: teardown runs on paths that must still publish a
// terminal status, so it reports problems instead of replacing them with its own.
async function teardownNgrokTunnel(tunnel, reason) {
  const problems = [];
  if (!tunnel) return problems;

  if (tunnel.listener) {
    try {
      await withTimeout(
        tunnel.listener.close(),
        NGROK_CLOSE_TIMEOUT_MS,
        "ngrok listener.close()",
      );
    } catch (err) {
      problems.push(`listener.close(): ${err.message}`);
    }
  }

  if (tunnel.session) {
    try {
      await withTimeout(
        tunnel.session.close(),
        NGROK_CLOSE_TIMEOUT_MS,
        "ngrok session.close()",
      );
    } catch (err) {
      // A session we could not close is a session the agent may still be holding, and
      // that is the wedge. Log it loudly -- it is now the one line that tells an
      // operator the leak recurred.
      problems.push(`session.close(): ${err.message}`);
    }
  }

  if (problems.length) {
    log(
      `ngrok teardown (${reason}) INCOMPLETE -- a session may still be held: ${problems.join("; ")}`,
      "ERROR",
    );
  } else {
    log(`ngrok teardown (${reason}): listener and session both closed`);
  }
  return problems;
}

// Build a tunnel on a session we own, so that stopping it can actually reclaim it.
//
// RESIDUAL LEAK, stated rather than hidden: if connect() itself overruns its bound and
// then succeeds anyway, it produces a session we never received a handle to and cannot
// close -- @ngrok/ngrok exposes no way to enumerate sessions (only listeners, via
// ngrok.listeners()). That window is 15 s wide against a call that normally takes ~2 s,
// and it is strictly smaller than the old behaviour, which leaked a session on EVERY
// stop. If it ever fires it is now visible: the failure publishes a real timeout reason
// instead of the old hardcoded string.
async function buildNgrokTunnel(authToken) {
  const tag = JSON.stringify({ deviceId: DEVICE_ID, image: IMAGE_VERSION });
  let session = null;
  let listener = null;
  try {
    session = await withTimeout(
      new ngrok.SessionBuilder().authtoken(authToken).metadata(tag).connect(),
      NGROK_CONNECT_TIMEOUT_MS,
      "ngrok session connect",
      (late) => reclaimStranded("session", late),
    );

    listener = await withTimeout(
      session
        .tcpEndpoint()
        .metadata(tag)
        .forwardsTo(NGROK_FORWARD_ADDR)
        .listen(),
      NGROK_LISTEN_TIMEOUT_MS,
      "ngrok tcp listen",
      // A listener arriving late is a LIVE TUNNEL nothing holds a reference to -- worse
      // than a stranded session, because it is reachable from the internet. The catch
      // below closes the session too, which should take its listeners with it; this is
      // belt and braces for the case where it does not.
      (late) => reclaimStranded("listener", late),
    );

    // Start the forwarding task. Deliberately NOT awaited -- forward() drives the
    // forwarding loop, and awaiting it would block until the tunnel closes. This
    // mirrors the SDK's own TCP example. Errors still surface in the device log.
    listener.forward(NGROK_FORWARD_ADDR).catch((err) => {
      log(`ngrok forwarding task ended: ${err.message}`, "ERROR");
    });

    return { session, listener, url: listener.url() };
  } catch (err) {
    // CRITICAL. If connect() succeeded and the listener then failed, we are holding
    // exactly the tunnel-less session this bug is about. Drop it before rethrowing --
    // otherwise the error path becomes a second source of the leak.
    if (session || listener) {
      await teardownNgrokTunnel({ session, listener }, "failed build");
    }
    throw err;
  }
}

// Flag to track if device ready receipt has been printed (once per power cycle).
//
// Lives in /run/eatabit, a tmpfs directory that systemd creates for this unit
// (RuntimeDirectory=eatabit) and keeps across a restart
// (RuntimeDirectoryPreserve=restart). So it survives a service restart --
// including the Layer 1 watchdog's process.exit(1) below -- and is cleared only
// by a genuine reboot or power cycle, which is exactly the once-per-power-cycle
// semantic this guard needs.
//
// It must NOT live in /tmp: the unit sets PrivateTmp=true, so systemd hands the
// service a fresh private /tmp namespace on every start and the flag is
// destroyed by every restart, reprinting the receipt (BUG-039).
//
// It must NOT live under /usr/local/lib/eatabit/log either: that path is in
// log2ram's LOG_DIRS and is restored from disk at boot, which would leave the
// flag stale-true after a power cycle and suppress the receipt forever -- the
// same bug in the silent direction (BUG-041).
const DEVICE_READY_FLAG = "/run/eatabit/device-ready-printed";
let hasDeviceReadyPrinted = fs.existsSync(DEVICE_READY_FLAG);

// Connection state tracking (Layer 1: Application Connection Watchdog)
const WATCHDOG_INTERVAL_MS = 60_000; // Check every 60 seconds
const MAX_DISCONNECT_DURATION_MS = 150_000; // 2.5 minutes
let isConnected = false;
let lastConnectedAt = null;
let lastDisconnectedAt = null;
let watchdogTriggerCount = 0;

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

// Helper function to publish health data via the health named shadow
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

    // Update the health shadow state with the latest health data
    healthData.connection = {
      isConnected,
      lastConnectedAt: lastConnectedAt
        ? new Date(lastConnectedAt).toISOString()
        : null,
      lastDisconnectedAt: lastDisconnectedAt
        ? new Date(lastDisconnectedAt).toISOString()
        : null,
      watchdogTriggerCount,
      uptimeMs:
        isConnected && lastConnectedAt ? Date.now() - lastConnectedAt : 0,
    };
    SHADOW_CONFIG.health.state = healthData;

    // Publish via the health named shadow
    await updateShadowReportedState("health");
    log("Published health data to health shadow");
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
    execSync(`curl -sf "${jobDownloadUri}" -o "${escposJobPath}"`, {
      shell: "/bin/bash",
    });

    log(`Job ${jobId} downloaded successfully to ${escposJobPath}`);

    return JOB_EVENTS.DOWNLOADED;
  } catch (err) {
    log(`Failed to download document: ${err.message}`, "ERROR");

    if (err.message === JOB_EVENTS.EXPIRED) {
      return JOB_EVENTS.EXPIRED;
    }

    // curl --fail exits with code 22 on HTTP errors (e.g., expired presigned URL)
    return JOB_EVENTS.STALE_URL;
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

    // Delay after status check to let printer flush DLE EOT responses
    execSync("sleep 1");

    // Send raw ESC/POS directly to printer device (bypass CUPS)
    execSync(`cat "${filePathEscPos}" > /dev/usb/lp0`, { shell: "/bin/bash" });

    // Wait for printer to finish processing raster data before querying status
    execSync("sleep 2");

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

  // Build a FRESH connection (with handlers) for each connect attempt. Reusing one
  // connection object across failed connect() retries — e.g. during the offline
  // window after a factory reset, before WiFi is re-provisioned — leaves a
  // degraded/half-open session: the eventual connect succeeds and can publish, but
  // the broker never delivers inbound messages (commands/jobs/shadow deltas), so the
  // device looks connected yet is deaf. A clean connection per attempt avoids that
  // (mirroring the old process-exit-per-failure behavior, which got a fresh process
  // each time). See docs/bugfix/offline-reboot-loop.md
  let connection;
  function createConnection() {
    const connection = client.new_connection(config);

    // Store connection globally for publishing
    mqttConnection = connection;

    // Connection event handlers
    connection.on("connect", async () => {
    isConnected = true;
    lastConnectedAt = Date.now();
    log("Connected to AWS IoT Core");
    setStatusLedConnected();

    // Print device ready receipt on first connection per power cycle
    if (!hasDeviceReadyPrinted) {
      try {
        const printerStatus = checkPrinterStatus();
        if (printerStatus.ready && fs.existsSync(DEVICE_READY_ESCPOS)) {
          // Delay after status check to let printer flush DLE EOT responses
          execSync("sleep 1");
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
      try {
        fs.writeFileSync(DEVICE_READY_FLAG, "");
      } catch (err) {
        // Never swallow this. If the flag cannot be written, the guard is lost on
        // the next restart and the receipt reprints -- indistinguishable from
        // BUG-039 itself, and silent. Log it so the failure is diagnosable.
        log(
          `Failed to persist device ready flag at ${DEVICE_READY_FLAG}: ${err.message} - ready receipt will reprint on the next service restart`,
          "ERROR"
        );
      }
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

    // For "health" shadow: publish current health data (device is source of truth)
    try {
      await publishHealthData();
      log("Pushed health data to AWS health shadow");
    } catch (err) {
      log(`Failed to push health shadow: ${err.message}`, "ERROR");
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
    const connectedDuration = lastConnectedAt
      ? Date.now() - lastConnectedAt
      : 0;
    isConnected = false;
    lastDisconnectedAt = Date.now();
    log(
      `Connection interrupted: ${error} (was connected for ${connectedDuration}ms)`,
      "WARN",
    );
    setStatusLedDisconnected();
  });

  connection.on("resume", async (return_code, session_present) => {
    const disconnectedDuration = lastDisconnectedAt
      ? Date.now() - lastDisconnectedAt
      : 0;
    isConnected = true;
    lastConnectedAt = Date.now();
    log(
      `Connection resumed (was disconnected for ${disconnectedDuration}ms). Return code: ${return_code}, Session present: ${session_present}`,
    );
    setStatusLedConnected();

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
    isConnected = false;
    lastDisconnectedAt = Date.now();
    log("Disconnected from AWS IoT Core");
    setStatusLedDisconnected();
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
        const jobExpiresAt = data.execution?.jobDocument?.expiresAt;

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

          // If the job has expired, terminate it with a status that is legal for
          // its CURRENT execution state. REJECTED is only valid from QUEUED; once
          // the device's own start-next call has advanced the execution to
          // IN_PROGRESS (start-next/accepted), REJECTED is refused as an illegal
          // transition and the execution sticks IN_PROGRESS, blocking notify-next
          // for every later job. In that case mark it FAILED instead.
          if (isJobExpired(jobExpiresAt)) {
            const executionStatus = data.execution?.status;
            const expiredStatus =
              executionStatus === JOB_EXECUTION_STATUSES.IN_PROGRESS
                ? JOB_EXECUTION_STATUSES.FAILED
                : JOB_EXECUTION_STATUSES.REJECTED;

            log(
              `Job ${jobId} has expired; marking ${expiredStatus} (execution was ${executionStatus})`,
            );

            const expiredPayload = JSON.stringify({
              status: expiredStatus,
              statusDetails: {
                event: JOB_EVENTS.EXPIRED,
              },
              expectedVersion: jobVersionNumber,
              includeJobExecutionState: true,
              includeJobDocument: false,
              clientToken: jobId, // Use jobId as clientToken
            });

            await connection.publish(
              `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
              expiredPayload,
              mqtt.QoS.AtLeastOnce,
            );

            log(`Job ${jobId} ${expiredStatus} due to expiration`);

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

          await connection.publish(
            `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
            successPayload,
            mqtt.QoS.AtLeastOnce,
          );

          log(`Published QUEUED event for job ${jobId}`);
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

                  await connection.publish(
                    `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                    downloadedPayload,
                    mqtt.QoS.AtLeastOnce,
                  );

                  // Republish to custom topic for topic rule (reserved $aws/ topics can't trigger rules)
                  const downloadedEventPayload = JSON.stringify({
                    eventType: "JOB_EXECUTION",
                    event: JOB_EVENTS.DOWNLOADED,
                    jobId,
                    thingName: DEVICE_ID,
                    timestamp: Date.now(),
                  });

                  await connection.publish(
                    `eatabit/things/${DEVICE_ID}/jobs/${jobId}/downloaded`,
                    downloadedEventPayload,
                    mqtt.QoS.AtLeastOnce,
                  );

                  log(`Published DOWNLOADED event for job ${jobId}`);
                }

                if (downloadResult === JOB_EVENTS.STALE_URL) {
                  log(
                    `Job ${jobId} has a stale presigned URL, marking as FAILED`,
                  );

                  const staleUrlPayload = JSON.stringify({
                    status: JOB_EXECUTION_STATUSES.FAILED,
                    statusDetails: {
                      event: JOB_EVENTS.STALE_URL,
                      reason: "Presigned URL expired",
                    },
                    expectedVersion: jobVersionNumber,
                    includeJobExecutionState: true,
                    includeJobDocument: false,
                    clientToken: jobId,
                  });

                  await connection.publish(
                    `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                    staleUrlPayload,
                    mqtt.QoS.AtLeastOnce,
                  );

                  await publishEvent(JOB_EVENTS.STALE_URL, { jobId });

                  break;
                }

                if (downloadResult === JOB_EVENTS.EXPIRED) {
                  // Job expired between QUEUED and download. The execution is
                  // already IN_PROGRESS here, so FAILED (not REJECTED) is the legal
                  // terminal status — otherwise the execution sticks IN_PROGRESS
                  // and blocks the queue.
                  log(`Job ${jobId} expired before download; marking FAILED`);

                  const expiredPayload = JSON.stringify({
                    status: JOB_EXECUTION_STATUSES.FAILED,
                    statusDetails: {
                      event: JOB_EVENTS.EXPIRED,
                    },
                    expectedVersion: jobVersionNumber,
                    includeJobExecutionState: true,
                    includeJobDocument: false,
                    clientToken: jobId,
                  });

                  await connection.publish(
                    `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                    expiredPayload,
                    mqtt.QoS.AtLeastOnce,
                  );

                  await publishEvent(JOB_EVENTS.EXPIRED, { jobId });

                  break;
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

                  await connection.publish(
                    `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                    printerOfflinePayload,
                    mqtt.QoS.AtLeastOnce,
                  );

                  log(`Published PRINTER_OFFLINE event for job ${jobId}`);

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

                await connection.publish(
                  `$aws/things/${DEVICE_ID}/jobs/${jobId}/update`,
                  printedPayload,
                  mqtt.QoS.AtLeastOnce,
                );

                log(`Published PRINTED event for job ${jobId}`);

                // Republish to custom topic for topic rule (reserved $aws/ topics can't trigger rules)
                const printedEventPayload = JSON.stringify({
                  eventType: "JOB_EXECUTION",
                  event: JOB_EVENTS.PRINTED,
                  jobId,
                  thingName: DEVICE_ID,
                  timestamp: Date.now(),
                });

                await connection.publish(
                  `eatabit/things/${DEVICE_ID}/jobs/${jobId}/printed`,
                  printedEventPayload,
                  mqtt.QoS.AtLeastOnce,
                );

                log(
                  `Republished PRINTED event to custom topic for job ${jobId}`,
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

          const publishNgrok = (status, reasonCode, reasonDescription, result) =>
            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              JSON.stringify({
                status,
                statusReason: { reasonCode, reasonDescription },
                result,
              }),
              mqtt.QoS.AtLeastOnce,
            );

          if (!authToken) {
            // BUG-049 F1. This used to log and `return`, publishing nothing at all, so
            // the DeviceCommand sat at `sent` until it aged out with no explanation.
            // A guard that refuses the work still owes the caller an answer.
            log("startNgrokTunnel command missing authToken parameter", "ERROR");
            publishNgrok(
              JOB_EXECUTION_STATUSES.FAILED,
              NGROK_REASON.MISSING_AUTHTOKEN,
              "startNgrokTunnel called without an authToken parameter",
              { status: { s: "error" } },
            );
            return;
          }

          log("Starting ngrok SSH forwarding...");

          // Serialised: a concurrent start and stop can no longer interleave, and the
          // tunnel handle is written only in here.
          await runNgrokOp(async () => {
            try {
              // Replace any existing tunnel, reclaiming its session on the way out.
              // The old code closed the listener and dropped the reference, which is
              // what leaked the session and eventually wedged the process.
              if (ngrokTunnel) {
                log("Closing existing ngrok tunnel before opening a new one...");
                const previous = ngrokTunnel;
                ngrokTunnel = null;
                await teardownNgrokTunnel(previous, "restart");
              }

              // Not wrapped in an outer timeout: buildNgrokTunnel() bounds each of
              // its own steps, so a slow build still lands in its catch and tears
              // down whatever it managed to create.
              const tunnel = await buildNgrokTunnel(authToken);
              ngrokTunnel = tunnel;

              log(`ngrok SSH forwarding established: ${tunnel.url}`, "INFO");

              // ngrokUrl travels in reasonDescription because the events topic
              // ($aws/events/commandExecution/+/+) includes statusReason but not
              // result, and only the events topic can trigger IoT Rules. Do not
              // "tidy" this into result -- the cloud reads it from here.
              publishNgrok(
                JOB_EXECUTION_STATUSES.SUCCEEDED,
                NGROK_REASON.OK,
                tunnel.url,
                { ngrokUrl: { s: tunnel.url } },
              );
            } catch (err) {
              // BUG-049 F5. The real error goes to the CLOUD now, not just to a local
              // log file readable only over the SSH tunnel that has just failed to
              // open. Every failure in this record's evidence reads `500 / "Failed to
              // establish tunnel"` -- the hardcoded string that used to live here --
              // which is why the root cause had to be found from the ngrok API and a
              // restart experiment instead of from what the device reported.
              log(
                `Failed to establish ngrok SSH forwarding: ${err.message}`,
                "ERROR",
              );

              // buildNgrokTunnel() tears down anything it created before it
              // rethrows, so there is normally nothing left here. This covers a
              // failure that came from replacing an existing tunnel.
              if (ngrokTunnel) {
                const stranded = ngrokTunnel;
                ngrokTunnel = null;
                await teardownNgrokTunnel(stranded, "failed start");
              }

              publishNgrok(
                JOB_EXECUTION_STATUSES.FAILED,
                ngrokFailureCode(err),
                statusReasonText(err.message, "Failed to establish tunnel"),
                { status: { s: "error" } },
              );
            }
          });
        }

        // Handle stopNgrokTunnel command
        if (commandId === "stopNgrokTunnel") {
          log("Stopping ngrok SSH forwarding...");

          const publishNgrok = (status, reasonCode, reasonDescription, result) =>
            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              JSON.stringify({
                status,
                statusReason: { reasonCode, reasonDescription },
                result,
              }),
              mqtt.QoS.AtLeastOnce,
            );

          await runNgrokOp(async () => {
            try {
              if (!ngrokTunnel) {
                // BUG-049 F1. This branch used to log and publish NOTHING, so the
                // DeviceCommand never left `sent`.
                //
                // It publishes SUCCEEDED, not FAILED, and that is deliberate --
                // a later reader will want to "fix" it back, so: "there was nothing
                // to stop" means THE REQUESTED END STATE ALREADY HOLDS. The caller
                // asked for no tunnel; there is no tunnel. Reporting FAILED for a
                // satisfied post-condition is what invites the retry, and a retry
                // loop against a device that is already in the desired state is
                // exactly how an operator burns the window in which the device is
                // reachable. The distinct reasonCode keeps the diagnostic
                // information ("nothing was there") without lying about the outcome.
                log("No active ngrok SSH forwarding to stop", "WARN");
                publishNgrok(
                  JOB_EXECUTION_STATUSES.SUCCEEDED,
                  NGROK_REASON.NO_TUNNEL_ACTIVE,
                  "No active tunnel to stop; device already has no tunnel",
                  { status: { s: "stopped" } },
                );
                return;
              }

              const tunnel = ngrokTunnel;
              ngrokTunnel = null;
              const problems = await teardownNgrokTunnel(tunnel, "stop");

              if (problems.length) {
                // The listener or the session would not close. Report it rather than
                // claiming a clean stop: a session we failed to close is the leak
                // that wedges the next start, and the operator needs to know.
                publishNgrok(
                  JOB_EXECUTION_STATUSES.FAILED,
                  NGROK_REASON.ERROR,
                  statusReasonText(
                    `Tunnel teardown incomplete: ${problems.join("; ")}`,
                    "Failed to stop tunnel",
                  ),
                  { status: { s: "error" } },
                );
                return;
              }

              log("ngrok SSH forwarding stopped", "INFO");
              publishNgrok(
                JOB_EXECUTION_STATUSES.SUCCEEDED,
                NGROK_REASON.OK,
                "Tunnel stopped successfully",
                { status: { s: "stopped" } },
              );
            } catch (err) {
              // teardownNgrokTunnel() does not throw, so this catches only the
              // unexpected. Publish the real reason anyway (F5).
              log(`Failed to stop ngrok SSH forwarding: ${err.message}`, "ERROR");
              publishNgrok(
                JOB_EXECUTION_STATUSES.FAILED,
                ngrokFailureCode(err),
                statusReasonText(err.message, "Failed to stop tunnel"),
                { status: { s: "error" } },
              );
            }
          });
        }

        /*
        Handle Reset command

        Reset message structure:
          {
            "commandId": "reset",
            "namespace": "AWS-IoT",
            "payloadTemplate": "{\"commandId\": \"${aws:iot:commandexecution::parameter:commandId}\",\"action\": \"${aws:iot:commandexecution::parameter:action}\"}",
            "parameters": [
              {
                "name": "action",
                "type": "STRING",
                "description": "Action to take after reset: 'reboot' or 'shutdown'"
              }
            ]
          }
        */

        if (commandId === "reset") {
          log("Processing reset command...");

          const action = data.action || "reboot";
          const reboot = action === "reboot";
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
                action: { s: action },
              },
            });

            connection.publish(
              `$aws/commands/things/${DEVICE_ID}/executions/${executionId}/response/json`,
              successPayload,
              mqtt.QoS.AtLeastOnce,
            );

            // Execute action after brief delay to ensure response is sent
            if (action === "reboot") {
              log("Rebooting device in 5 seconds...");
              setTimeout(() => {
                try {
                  execSync("shutdown -r now", { shell: "/bin/bash" });
                  log("Reboot command issued");
                } catch (err) {
                  log(`Failed to reboot device: ${err.message}`, "ERROR");
                }
              }, 5000);
            } else if (action === "shutdown") {
              log("Shutting down device in 5 seconds...");
              setTimeout(() => {
                try {
                  execSync("shutdown -h now", { shell: "/bin/bash" });
                  log("Shutdown command issued");
                } catch (err) {
                  log(`Failed to shut down device: ${err.message}`, "ERROR");
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
              result: {
                status: { s: "error" },
              },
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
              result: {
                status: { s: "error" },
              },
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

    return connection;
  }

  try {
    // Notify systemd we're ready as soon as the handlers are registered — BEFORE
    // attempting to connect. The service must count as "started" regardless of
    // network so an unprovisioned/offline device doesn't fail its start and get
    // reboot-looped by StartLimitAction=reboot-force.
    // See docs/bugfix/offline-reboot-loop.md
    SdNotify.ready();
    log("Sent sd_notify READY=1");

    // Watch config files for BLE-initiated changes (independent of connection)
    watchCutterConfigFile();
    watchVolumeConfigFile();

    // Initial connect is non-fatal and retried in the background. We do NOT
    // process.exit(1) on failure: without a network the SDK can't connect (and a
    // fresh process couldn't either), so exiting would only feed the reboot loop.
    // Once connected, the SDK's own interrupt/resume backoff handles later drops,
    // and the Layer 1 watchdog below recovers a post-connect wedge via a restart.
    //
    // The retry loops on a dedicated `subscribed` flag — NOT isConnected — because
    // the "connect" event handler flips isConnected true the instant the socket is
    // up. Gating the loop on isConnected meant a single transient subscribe error
    // would exit the loop (isConnected already true) and leave the device connected
    // but unsubscribed — deaf to jobs and commands.
    let subscribed = false;
    async function attemptInitialConnect() {
      while (!subscribed) {
        // Fresh connection + handlers every attempt — never reuse one whose
        // connect() failed (that's what left the device connected-but-deaf after a
        // factory-reset re-provision). See the createConnection comment above.
        connection = createConnection();
        try {
          log(`Connecting to ${ENDPOINT}...`);
          await connection.connect();

          // Subscribe to all job topics
          for (const topic of SUBSCRIBE_TOPICS) {
            log(`Subscribing to ${topic}`);
            await connection.subscribe(topic, mqtt.QoS.AtLeastOnce);
          }
          log("Successfully subscribed to all topics");
          subscribed = true;
        } catch (err) {
          log(
            `Initial connect/subscribe failed: ${err.message}; retrying in 30s`,
            "WARN",
          );
          // Tear down the failed connection so the next attempt is truly clean.
          try {
            await connection.disconnect();
          } catch (_) {}
          await new Promise((r) => setTimeout(r, 30_000));
        }
      }

      // Best-effort shadow init — kept separate from the loop above so a shadow or
      // health error can never skip or undo the topic subscriptions.
      try {
        log("Initializing shadow reported states...");
        await updateShadowReportedState("public");
        await updateShadowReportedState("private");
        await publishHealthData();
      } catch (err) {
        log(`Shadow init failed (non-fatal): ${err.message}`, "WARN");
      }
    }
    attemptInitialConnect();

    // Layer 1: Application Connection Watchdog
    const watchdogInterval = setInterval(async () => {
      // Layer 2: Send systemd watchdog ping unconditionally (process liveness)
      SdNotify.watchdog();

      if (!isConnected && lastDisconnectedAt) {
        const disconnectedMs = Date.now() - lastDisconnectedAt;
        log(`Watchdog check: disconnected for ${disconnectedMs}ms`, "WARN");

        if (disconnectedMs > MAX_DISCONNECT_DURATION_MS) {
          log(
            `Connection watchdog triggered: disconnected for ${disconnectedMs}ms, exiting to trigger systemd restart`,
            "ERROR",
          );
          watchdogTriggerCount++;

          // The MQTT publish promise can hang forever when the SDK is wedged —
          // awaiting it before process.exit() left devices stuck for 18h in the
          // field. Fire-and-forget, then exit. Belt-and-suspenders setTimeout
          // guarantees exit if any future code above introduces a sync hang.
          setTimeout(() => process.exit(1), 3000).unref();

          publishEvent("connectionWatchdogTriggered", {
            disconnectedForMs: disconnectedMs,
            lastConnectedAt: lastConnectedAt
              ? new Date(lastConnectedAt).toISOString()
              : null,
            triggeredAt: new Date().toISOString(),
          }).catch(() => {});

          process.exit(1);
        }
      }
    }, WATCHDOG_INTERVAL_MS);

    // Update health shadow every 15 minutes (900000 ms)
    const healthInterval = setInterval(async () => {
      await publishHealthData();
    }, 900000); // 15 minutes
    await new Promise((resolve) => {
      process.on("SIGINT", async () => {
        log("Received SIGINT, disconnecting...");
        clearInterval(healthInterval);
        clearInterval(watchdogInterval);

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
        clearInterval(watchdogInterval);

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
