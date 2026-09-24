#!/usr/bin/env node
// =============================================================================
//  netwatch -- network-recovery watchdog (BUG-094)
// =============================================================================
//  Runs once a minute from netwatch.timer (Type=oneshot). Owns everything BELOW
//  mqtt-client: WiFi association, the radio, the driver, and -- as a last resort --
//  the reboot. It never restarts mqtt-client (Layer 1 in mqtt-client.js covers
//  "network fine, client stuck") and it never prints.
//
//  Offline means BOTH:
//    (a) mqtt-client's status file says disconnected (or is stale/missing), AND
//    (b) our own DNS lookup + TCP connect to the IoT endpoint fail.
//
//  Escalation ladder, by accumulated offline time in the current outage:
//    2 min   snapshot + log
//    3 min   nmcli con down/up on the fingerprinted connection
//    6 min   nmcli radio wifi off/on
//    7 min   brcmfmac driver reload
//    10 min  reboot -- then again at +30 min, +1 h, +2 h, +4 h, then every 6 h
//
//  NO RTC. A Pi Zero 2 W has no hardware clock, so after an offline reboot the wall
//  clock is whatever was last saved. Every duration here is accumulated from
//  /proc/uptime per boot_id and summed across boots in the persisted state. Wall
//  times are logged, but only as approximate labels -- never subtracted.
//
//  Written in Node rather than bash for the JSON state, log and marker handling
//  (there is no jq on the image); health-monitor.js is the precedent for a
//  timer-driven Node oneshot on this device.
// =============================================================================

const fs = require("fs");
const path = require("path");
const net = require("net");
const dns = require("dns");
const { execFile } = require("child_process");

const EATABIT_DIR = "/usr/local/lib/eatabit";
// Card-backed, NOT tmpfs: this state must survive the reboot it describes.
const STATE_DIR = `${EATABIT_DIR}/state`;
const STATE_FILE = `${STATE_DIR}/netwatch.json`;
// Receipt-suppression marker (guard 4). Read by boot-print.sh and mqtt-client.js.
const REBOOT_MARKER = `${STATE_DIR}/netwatch-reboot`;
// Pending reconnect summary for mqtt-client to publish, and the last one (for the
// health shadow).
const RECOVERY_PENDING = `${STATE_DIR}/netwatch-recovery.json`;
const RECOVERY_LAST = `${STATE_DIR}/netwatch-last-recovery.json`;
// /usr/local/lib/eatabit/log was never RAM-buffered (see stage3/05-install-log2ram),
// so this log survives a forced reboot.
const LOG_FILE = `${EATABIT_DIR}/log/netwatch.log`;

// Written by mqtt-client.js on /run/eatabit (tmpfs -- live state only).
const CLIENT_STATUS_FILE = "/run/eatabit/mqtt-status.json";
const RECOVERY_ACK_FILE = "/run/eatabit/netwatch-recovery-ack";
const DEVICE_READY_FLAG = "/run/eatabit/device-ready-printed";
const MQTT_CLIENT_JS = `${EATABIT_DIR}/bin/mqtt-client.js`;
const MQTT_PORT = 8883;
const WIFI_IFACE = "wlan0";

// Ladder thresholds, in accumulated offline seconds.
const SNAPSHOT_AT = 120;
const NMCLI_AT = 180;
const RADIO_AT = 360;
const DRIVER_AT = 420;
const FIRST_REBOOT_AT = 600;
// Offline seconds since the previous reboot before the next one.
const REBOOT_BACKOFF = [1800, 3600, 7200, 14400, 21600];
// Reboot counter resets after this long continuously connected (current boot uptime).
const STABLE_RESET_SECONDS = 1800;
// Never reboot in the first few minutes after boot.
const REBOOT_UPTIME_FLOOR = 300;
// mqtt-client heartbeats every 30 s; older than this and the file is stale.
const CLIENT_STALE_SECONDS = 90;
// printDocument() runs synchronously and blocks the client's event loop, so the
// heartbeat stops during a print. Honour printing=true for this long even when stale.
const PRINT_GUARD_MAX_SECONDS = 600;
// A recovery seen within this many offline seconds of the last step is credited to it.
const FIXED_BY_WINDOW = 240;
const HEALTHY_LOG_EVERY = 900;
// While the client is down but our own probe succeeds, repeat that entry this often.
const SPLIT_LOG_EVERY = 900;
const MAX_STEPS_IN_SUMMARY = 20;
const MAX_STEPS_KEPT = 50;

// ---------------------------------------------------------------------------
//  Small helpers
// ---------------------------------------------------------------------------

function readUptime() {
  return parseFloat(fs.readFileSync("/proc/uptime", "utf8").split(" ")[0]);
}

function readBootId() {
  return fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

// tmp + fsync + rename + fsync(dir): a power cut leaves the old file or the new one,
// never a torn one.
function writeJsonAtomic(file, value) {
  const tmp = `${file}.tmp`;
  const fd = fs.openSync(tmp, "w", 0o644);
  try {
    fs.writeSync(fd, JSON.stringify(value));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
  try {
    const dfd = fs.openSync(path.dirname(file), "r");
    fs.fsyncSync(dfd);
    fs.closeSync(dfd);
  } catch {}
}

function removeFile(file) {
  try {
    fs.unlinkSync(file);
    return true;
  } catch {
    return false;
  }
}

// Run a command with a hard timeout. A wedged SDIO bus can hang `iw` or `modprobe`;
// a timeout is an outcome, never a stall.
function run(cmd, args, timeoutMs = 10_000) {
  return new Promise((resolve) => {
    execFile(
      cmd,
      args,
      { timeout: timeoutMs, killSignal: "SIGKILL", encoding: "utf8" },
      (err, stdout, stderr) => {
        resolve({
          ok: !err,
          timedOut: !!(err && err.killed),
          code: err ? (typeof err.code === "number" ? err.code : null) : 0,
          stdout: stdout || "",
          stderr: stderr || "",
        });
      },
    );
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function withTimeout(promise, ms) {
  let t;
  return Promise.race([
    promise.finally(() => clearTimeout(t)),
    new Promise((_, reject) => {
      t = setTimeout(() => reject(new Error("timeout")), ms);
    }),
  ]);
}

// ---------------------------------------------------------------------------
//  Log -- one JSON line per entry, fsync'd per write, on the card
// ---------------------------------------------------------------------------

let CTX = { bootId: null, uptime: 0, offlineSeconds: 0 };

function logEntry(event, fields = {}) {
  const entry = {
    ts: new Date().toISOString(), // approximate while offline -- no RTC
    bootId: CTX.bootId,
    uptime: Math.round(CTX.uptime),
    offlineSeconds: Math.round(CTX.offlineSeconds),
    event,
    ...fields,
  };
  const line = `${JSON.stringify(entry)}\n`;
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true, mode: 0o755 });
    const fd = fs.openSync(LOG_FILE, "a", 0o644);
    try {
      fs.writeSync(fd, line);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
  } catch (err) {
    console.error(`netwatch: failed to write log: ${err.message}`);
  }
  console.log(line.trim());
}

// ---------------------------------------------------------------------------
//  mqtt-client status
// ---------------------------------------------------------------------------

function readClientStatus(uptime, bootId) {
  const s = readJson(CLIENT_STATUS_FILE);
  if (!s || s.bootId !== bootId || typeof s.uptime !== "number") {
    return { fresh: false, connected: false, printing: false, connectedSinceUptime: null, endpoint: s?.endpoint || null };
  }
  const fresh = uptime - s.uptime <= CLIENT_STALE_SECONDS;
  const printingRecent =
    s.printing === true &&
    typeof s.printingSinceUptime === "number" &&
    uptime - s.printingSinceUptime <= PRINT_GUARD_MAX_SECONDS;
  return {
    fresh,
    // A dead client must neither claim connectivity nor pin the print guard.
    connected: fresh && s.connected === true,
    printing: (fresh && s.printing === true) || printingRecent,
    connectedSinceUptime: typeof s.connectedSinceUptime === "number" ? s.connectedSinceUptime : null,
    endpoint: s.endpoint || null,
  };
}

function endpointFromMqttClient() {
  try {
    const src = fs.readFileSync(MQTT_CLIENT_JS, "utf8");
    const m = src.match(/const ENDPOINT = "([^"]+)"/);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
//  Our own reachability probe: DNS + TCP connect to the IoT endpoint
// ---------------------------------------------------------------------------

async function probeEndpoint(endpoint) {
  if (!endpoint) return { ok: false, stage: "no_endpoint" };
  let address;
  try {
    // Any family, in the resolver's preferred order -- the same address the client
    // would use. Sites with IPv6 reach AWS IoT over it (measured on the bench LAN,
    // 2026-09-23), so an IPv4-only probe can disagree with the client.
    const res = await withTimeout(dns.promises.lookup(endpoint), 8000);
    address = res.address;
  } catch (err) {
    return { ok: false, stage: "dns", error: err.message };
  }
  const connected = await new Promise((resolve) => {
    const sock = net.connect({ host: address, port: MQTT_PORT });
    const done = (ok) => {
      sock.destroy();
      resolve(ok);
    };
    sock.setTimeout(8000, () => done(false));
    sock.once("connect", () => done(true));
    sock.once("error", () => done(false));
  });
  return connected ? { ok: true, address } : { ok: false, stage: "tcp", address };
}

// ---------------------------------------------------------------------------
//  WiFi / NetworkManager
// ---------------------------------------------------------------------------

async function activeWifiConnection() {
  const r = await run("nmcli", ["-t", "-f", "UUID,TYPE,DEVICE", "con", "show", "--active"]);
  if (!r.ok) return null;
  for (const line of r.stdout.split("\n")) {
    const [uuid, type, device] = line.split(":");
    if (type === "802-11-wireless" && device === WIFI_IFACE) {
      const ssid = await connectionSsid(uuid);
      return { uuid, ssid };
    }
  }
  return null;
}

async function connectionSsid(uuid) {
  const r = await run("nmcli", ["-g", "802-11-wireless.ssid", "con", "show", "uuid", uuid]);
  return r.ok ? r.stdout.trim() : null;
}

// Guard 1: act only on a network that has worked. The fingerprint is the NM
// connection UUID + SSID recorded the first time the client reported connected on
// it. A factory reset deletes the profile and a BLE re-provision creates one with a
// new UUID, so neither matches until that network has worked once. ble-config.js
// exposes no reliable "provisioning in progress" signal (it advertises
// continuously), so the fingerprint alone is the guard.
async function fingerprintMatches(fp) {
  if (!fp || !fp.uuid) return { ok: false, reason: "no_fingerprint" };
  const r = await run("nmcli", ["-t", "-f", "UUID,TYPE", "con", "show"]);
  if (!r.ok) return { ok: false, reason: "nmcli_failed" };
  const present = r.stdout
    .split("\n")
    .some((l) => l === `${fp.uuid}:802-11-wireless`);
  if (!present) return { ok: false, reason: "fingerprint_profile_gone" };
  const ssid = await connectionSsid(fp.uuid);
  if (ssid !== fp.ssid) return { ok: false, reason: "fingerprint_ssid_changed" };
  return { ok: true };
}

function parseIwLink(out) {
  if (!out || /Not connected/i.test(out)) return { associated: false };
  const bssid = (out.match(/Connected to ([0-9a-f:]{17})/i) || [])[1] || null;
  const ssid = (out.match(/SSID: (.*)/) || [])[1] || null;
  const sig = out.match(/signal: (-?\d+)/);
  return {
    associated: !!bssid,
    bssid,
    ssid: ssid ? ssid.trim() : null,
    rssi: sig ? parseInt(sig[1], 10) : null,
  };
}

function parseIwScan(out, ssid) {
  const found = [];
  for (const block of out.split(/^BSS /m).slice(1)) {
    const bssid = (block.match(/^([0-9a-f:]{17})/i) || [])[1];
    const s = (block.match(/^\s*SSID: (.*)$/m) || [])[1];
    const sig = block.match(/signal: (-?[\d.]+) dBm/);
    const ch =
      block.match(/DS Parameter set: channel (\d+)/) ||
      block.match(/\* primary channel: (\d+)/);
    if (bssid && s !== undefined && s.trim() === ssid) {
      found.push({
        bssid,
        rssi: sig ? Math.round(parseFloat(sig[1])) : null,
        channel: ch ? parseInt(ch[1], 10) : null,
      });
    }
  }
  return found;
}

async function dnsVia(server, name) {
  if (!server || !name) return null;
  const resolver = new dns.promises.Resolver({ timeout: 3000, tries: 1 });
  resolver.setServers([server]);
  try {
    await withTimeout(resolver.resolve4(name), 5000);
    return true;
  } catch {
    return false;
  }
}

async function ping(host) {
  if (!host) return null;
  const r = await run("ping", ["-c", "2", "-W", "2", host], 8000);
  return r.ok;
}

// ---------------------------------------------------------------------------
//  Snapshot -- taken at step 1 and before every later step
// ---------------------------------------------------------------------------

async function takeSnapshot(state, endpoint) {
  const link = await run("iw", ["dev", WIFI_IFACE, "link"], 8000);
  const wifiLink = parseIwLink(link.ok ? link.stdout : "");
  const nm = await run("nmcli", ["-t", "-f", "GENERAL.STATE,GENERAL.CONNECTION", "dev", "show", WIFI_IFACE]);
  const addr = await run("ip", ["-4", "-o", "addr", "show", WIFI_IFACE]);
  const route = await run("ip", ["route", "show", "default"]);
  const gateway = (route.stdout.match(/default via (\S+)/) || [])[1] || null;
  let resolvConf = [];
  try {
    resolvConf = fs
      .readFileSync("/etc/resolv.conf", "utf8")
      .split("\n")
      .filter((l) => l.startsWith("nameserver"))
      .map((l) => l.split(/\s+/)[1]);
  } catch {}

  const checks = {
    gatewayPing: await ping(gateway),
    publicPing: await ping("1.1.1.1"),
    dnsViaGateway: await dnsVia(gateway, endpoint),
    dnsViaPublic: await dnsVia("1.1.1.1", endpoint),
  };

  const kmsg = await run("journalctl", ["-k", "-n", "300", "--no-pager", "-o", "short-monotonic"], 10_000);
  const brcmf = kmsg.stdout
    .split("\n")
    .filter((l) => /brcmf/i.test(l))
    .slice(-15);

  const ssid = state.fingerprint?.ssid || wifiLink.ssid || null;
  const scan = await run("iw", ["dev", WIFI_IFACE, "scan"], 20_000);
  const bssids = scan.ok && ssid ? parseIwScan(scan.stdout, ssid) : null;

  const strongest =
    bssids && bssids.length
      ? bssids.reduce((a, b) => ((b.rssi ?? -999) > (a.rssi ?? -999) ? b : a))
      : null;
  const ssidVisible = bssids === null ? null : bssids.length > 0;

  let interpretation = "unknown";
  if (wifiLink.associated && checks.gatewayPing && !checks.publicPing) {
    interpretation = "upstream_down";
  } else if (ssidVisible === false) {
    interpretation = "ap_down";
  } else if (ssidVisible && !wifiLink.associated && (strongest?.rssi ?? -999) >= -75) {
    interpretation = "pi_stuck";
  } else if (bssids && bssids.length > 1) {
    interpretation = "roaming";
  }

  const summary = {
    interpretation,
    wifi: {
      ssidVisible,
      associated: wifiLink.associated,
      bssid: wifiLink.bssid || null,
      rssi: wifiLink.rssi ?? strongest?.rssi ?? null,
      bssidCount: bssids ? bssids.length : null,
    },
    checks,
  };

  const full = {
    ...summary,
    iwLink: link.ok ? link.stdout.trim() : `ERR${link.timedOut ? " (timeout)" : ""}: ${link.stderr.trim()}`,
    nm: nm.stdout.trim(),
    ipAddr: addr.stdout.trim(),
    route: route.stdout.trim(),
    gateway,
    resolvConf,
    scanSsid: ssid,
    scan: bssids ?? (scan.timedOut ? "timeout" : scan.stderr.trim() || "unavailable"),
    brcmf,
  };
  return { summary, full };
}

// ---------------------------------------------------------------------------
//  Ladder steps
// ---------------------------------------------------------------------------

async function stepNmcliReconnect(fp) {
  await run("nmcli", ["con", "down", "uuid", fp.uuid], 20_000); // may fail if not active
  const up = await run("nmcli", ["--wait", "30", "con", "up", "uuid", fp.uuid], 45_000);
  return up.timedOut ? "timeout" : up.ok ? "ok" : "failed";
}

async function stepRadioCycle() {
  const off = await run("nmcli", ["radio", "wifi", "off"], 15_000);
  await sleep(3000);
  const on = await run("nmcli", ["radio", "wifi", "on"], 15_000);
  if (off.timedOut || on.timedOut) return "timeout";
  return off.ok && on.ok ? "ok" : "failed";
}

// On current kernels brcmfmac is held by a vendor module (brcmfmac_cyw on 6.18,
// brcmfmac_wcc on others), so `modprobe -r brcmfmac` alone fails with "in use".
// Remove the loaded vendor modules with it. A failure or timeout is an outcome: the
// ladder proceeds to the reboot.
async function stepDriverReload() {
  let vendors = [];
  try {
    vendors = fs
      .readFileSync("/proc/modules", "utf8")
      .split("\n")
      .map((l) => l.split(" ")[0])
      .filter((m) => /^brcmfmac_/.test(m));
  } catch {}
  const rm = await run("modprobe", ["-r", ...vendors, "brcmfmac"], 30_000);
  await sleep(2000);
  const load = await run("modprobe", ["brcmfmac"], 30_000);
  await run("nmcli", ["radio", "wifi", "on"], 15_000);
  if (rm.timedOut || load.timedOut) return "timeout";
  return rm.ok && load.ok ? "ok" : "failed";
}

function rebootDue(state, episode) {
  if (state.rebootCount === 0) return episode.offlineSeconds >= FIRST_REBOOT_AT;
  const wait = REBOOT_BACKOFF[Math.min(state.rebootCount - 1, REBOOT_BACKOFF.length - 1)];
  return state.offlineSinceLastReboot >= wait;
}

// ---------------------------------------------------------------------------
//  Receipt-suppression marker housekeeping
// ---------------------------------------------------------------------------
//  Marker: {"writtenBootId":"<boot that rebooted>","boundBootId":null|"<boot it suppresses>"}
//  boot-print.sh binds it to the boot after the reboot and never deletes it;
//  mqtt-client.js reads it at its ready-print decision. mqtt-client cannot delete it
//  itself -- its unit is ProtectSystem=strict and the state dir is not in its
//  ReadWritePaths -- so the delete happens here, once the client has recorded its
//  decision in DEVICE_READY_FLAG.

function tidyMarker(bootId) {
  if (!fs.existsSync(REBOOT_MARKER)) return;
  const m = readJson(REBOOT_MARKER);
  if (!m || typeof m.writtenBootId !== "string") {
    removeFile(REBOOT_MARKER);
    logEntry("marker_removed", { why: "malformed" });
    return;
  }
  if (m.boundBootId === bootId) {
    if (fs.existsSync(DEVICE_READY_FLAG)) {
      removeFile(REBOOT_MARKER);
      logEntry("marker_removed", { why: "consumed" });
    }
    return;
  }
  if (m.boundBootId) {
    // Bound to an earlier boot: stale. A human power-cycle must always print.
    removeFile(REBOOT_MARKER);
    logEntry("marker_removed", { why: "stale", boundBootId: m.boundBootId });
    return;
  }
  if (m.writtenBootId !== bootId) {
    // Unbound after a reboot: boot-print.sh did not bind it (it failed or did not
    // run). Bind it now so the NEXT boot cannot mistake it for its own.
    writeJsonAtomic(REBOOT_MARKER, { writtenBootId: m.writtenBootId, boundBootId: bootId });
    logEntry("marker_bound", { by: "netwatch" });
  }
}

function tidyRecoveryAck() {
  const pending = readJson(RECOVERY_PENDING);
  if (!pending) return;
  let ack = null;
  try {
    ack = fs.readFileSync(RECOVERY_ACK_FILE, "utf8").trim();
  } catch {}
  if (ack && ack === pending.id) {
    removeFile(RECOVERY_PENDING);
    logEntry("recovery_published", { id: pending.id });
  }
}

// ---------------------------------------------------------------------------
//  Main
// ---------------------------------------------------------------------------

function freshState() {
  return {
    v: 1,
    bootId: null,
    lastUptime: 0,
    online: null,
    onlineSinceUptime: null,
    episode: null,
    rebootCount: 0,
    offlineSinceLastReboot: 0,
    fingerprint: null,
    endpoint: null,
    lastHealthyLogUptime: null,
    split: null,
  };
}

function newEpisode() {
  return {
    startedApprox: new Date().toISOString(),
    offlineSeconds: 0,
    steps: [],
    done: {},
    reboots: 0,
    lastStep: null,
    lastSnapshot: null,
    loggedSkips: {},
  };
}

function fixedBy(episode) {
  const last = episode.lastStep;
  if (!last) return "none";
  return episode.offlineSeconds - last.atOfflineSeconds <= FIXED_BY_WINDOW ? last.step : "none";
}

function recordStep(episode, step, outcome, extra = {}) {
  const entry = { step, atOfflineSeconds: Math.round(episode.offlineSeconds), outcome };
  episode.steps.push(entry);
  if (episode.steps.length > MAX_STEPS_KEPT) episode.steps.splice(0, episode.steps.length - MAX_STEPS_KEPT);
  if (step !== "snapshot" && outcome !== "skipped_guard" && outcome !== "deferred_printing") {
    episode.lastStep = entry;
  }
  logEntry("step", { ...entry, ...extra });
}

async function main() {
  fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o755 });
  const uptime = readUptime();
  const bootId = readBootId();
  const state = { ...freshState(), ...(readJson(STATE_FILE) || {}) };
  const firstRunThisBoot = state.bootId !== bootId;
  const delta = firstRunThisBoot ? uptime : Math.max(0, uptime - state.lastUptime);
  CTX = { bootId, uptime, offlineSeconds: state.episode?.offlineSeconds || 0 };

  tidyMarker(bootId);
  tidyRecoveryAck();

  const client = readClientStatus(uptime, bootId);
  const endpoint = client.endpoint || state.endpoint || endpointFromMqttClient();
  if (endpoint) state.endpoint = endpoint;

  if (client.connected) {
    const active = await activeWifiConnection();
    if (active && (active.uuid !== state.fingerprint?.uuid || active.ssid !== state.fingerprint?.ssid)) {
      state.fingerprint = active;
      logEntry("fingerprint", { uuid: active.uuid, ssid: active.ssid });
    }
  }

  let online = client.connected;
  let probe = null;
  if (!online) {
    probe = await probeEndpoint(endpoint);
    online = probe.ok;
  }

  noteSplit(state, { uptime, firstRunThisBoot, client, probe });

  if (online) {
    await handleOnline(state, { uptime, bootId, firstRunThisBoot, client, delta });
  } else {
    await handleOffline(state, { uptime, bootId, firstRunThisBoot, delta, client, probe, endpoint });
  }

  state.bootId = bootId;
  state.lastUptime = readUptime();
  state.online = online;
  writeJsonAtomic(STATE_FILE, state);
}

// The comparison that tells "DNS / the network is down" apart from "the client
// process is wedged" (BUG-057). Both sides call getaddrinfo() against the same
// resolv.conf; if our probe resolves and connects while the client stays down, the
// fault is local to the client process. Logged when it starts, every 15 min while it
// lasts, and when it ends -- with the resolver state at that moment.
function noteSplit(state, { uptime, firstRunThisBoot, client, probe }) {
  const split = !client.connected && probe !== null && probe.ok;
  if (firstRunThisBoot) state.split = null; // uptime-based; never carried across a boot
  if (split) {
    if (!state.split) {
      state.split = { sinceUptime: uptime, lastLogUptime: null };
    }
    if (state.split.lastLogUptime === null || uptime - state.split.lastLogUptime >= SPLIT_LOG_EVERY) {
      let nameservers = [];
      try {
        nameservers = fs
          .readFileSync("/etc/resolv.conf", "utf8")
          .split("\n")
          .filter((l) => l.startsWith("nameserver"))
          .map((l) => l.split(/\s+/)[1]);
      } catch {}
      logEntry("client_down_probe_ok", {
        forSeconds: Math.round(uptime - state.split.sinceUptime),
        clientStatusFresh: client.fresh,
        probeAddress: probe.address,
        nameservers,
      });
      state.split.lastLogUptime = uptime;
    }
  } else if (state.split) {
    logEntry("client_down_probe_ok_ended", {
      forSeconds: Math.round(uptime - state.split.sinceUptime),
      clientConnected: client.connected,
      probeOk: probe ? probe.ok : null,
    });
    state.split = null;
  }
}

async function handleOnline(state, { uptime, bootId, firstRunThisBoot, client, delta }) {
  const episode = state.episode;
  if (firstRunThisBoot || state.online !== true) state.onlineSinceUptime = uptime;

  if (episode) {
    // Close the outage at the moment the client reconnected -- which, after a
    // reboot, includes the reboot itself. Without the client's timestamp (it came
    // back via our probe, or the file is stale) count nothing rather than guess.
    const windowStart = firstRunThisBoot ? 0 : state.lastUptime;
    if (client.connected && client.connectedSinceUptime !== null) {
      const stillOffline = Math.min(delta, Math.max(0, client.connectedSinceUptime - windowStart));
      episode.offlineSeconds += stillOffline;
      state.offlineSinceLastReboot += stillOffline;
    }
    CTX.offlineSeconds = episode.offlineSeconds;
    const by = fixedBy(episode);
    if (firstRunThisBoot) logEntry("startup", { result: `recovered after: ${by}` });
    const tookStep = episode.steps.length > 0;
    logEntry("recovered", { fixedBy: by, steps: episode.steps.length, clientConnected: client.connected });
    if (tookStep) {
      const data = {
        schemaVersion: 1,
        bootId,
        offlineSeconds: Math.round(episode.offlineSeconds),
        offlineSinceApprox: episode.startedApprox || null,
        recoveredAt: new Date().toISOString(),
        fixedBy: by,
        rebootCount: episode.reboots,
        stepsTaken: episode.steps.slice(-MAX_STEPS_IN_SUMMARY),
        interpretation: episode.lastSnapshot?.interpretation || "unknown",
        wifi: episode.lastSnapshot?.wifi || null,
        checks: episode.lastSnapshot?.checks || null,
      };
      const id = `${bootId}:${Math.round(uptime)}`;
      writeJsonAtomic(RECOVERY_PENDING, { id, data });
      writeJsonAtomic(RECOVERY_LAST, { id, data });
    }
    state.episode = null;
  } else if (firstRunThisBoot) {
    logEntry("startup", { result: "online" });
  }

  if (state.rebootCount > 0 && uptime - state.onlineSinceUptime >= STABLE_RESET_SECONDS) {
    logEntry("backoff_reset", { rebootCount: state.rebootCount });
    state.rebootCount = 0;
    state.offlineSinceLastReboot = 0;
  }

  if (state.lastHealthyLogUptime === null || firstRunThisBoot || uptime - state.lastHealthyLogUptime >= HEALTHY_LOG_EVERY) {
    const link = await run("iw", ["dev", WIFI_IFACE, "link"], 8000);
    const w = parseIwLink(link.ok ? link.stdout : "");
    logEntry("healthy", { ssid: w.ssid, bssid: w.bssid, rssi: w.rssi });
    state.lastHealthyLogUptime = uptime;
  }
}

async function handleOffline(state, { uptime, bootId, firstRunThisBoot, delta, client, probe, endpoint }) {
  let episode = state.episode;
  if (!episode) {
    episode = state.episode = newEpisode();
    logEntry("offline", { probe });
  } else {
    // Continuing outage -- including across a reboot, where delta is this boot's
    // uptime. Never a wall-clock subtraction.
    episode.offlineSeconds += delta;
    state.offlineSinceLastReboot += delta;
  }
  CTX.offlineSeconds = episode.offlineSeconds;
  if (firstRunThisBoot) {
    logEntry("startup", { result: "still offline", previousStep: episode.lastStep?.step || null, probe });
  }

  const acc = episode.offlineSeconds;

  if (acc >= SNAPSHOT_AT && !episode.done.snapshot) {
    const snap = await takeSnapshot(state, endpoint);
    episode.lastSnapshot = snap.summary;
    episode.done.snapshot = true;
    recordStep(episode, "snapshot", "ok", { snapshot: snap.full });
    return;
  }

  let next = null;
  if (acc >= NMCLI_AT && !episode.done.nmcli_reconnect) next = "nmcli_reconnect";
  else if (acc >= RADIO_AT && !episode.done.radio_cycle) next = "radio_cycle";
  else if (acc >= DRIVER_AT && !episode.done.driver_reload) next = "driver_reload";
  else if (acc >= FIRST_REBOOT_AT && rebootDue(state, episode)) next = "reboot";
  if (!next) return;

  // Guard 1 -- act only on a network that has worked.
  const fp = await fingerprintMatches(state.fingerprint);
  if (!fp.ok) {
    if (!episode.loggedSkips[next]) {
      episode.loggedSkips[next] = true;
      recordStep(episode, next, "skipped_guard", { guard: fp.reason });
    }
    if (next !== "reboot") episode.done[next] = true;
    return;
  }

  // Guard 2 -- never interrupt a print.
  if (client.printing) {
    recordStep(episode, next, "deferred_printing");
    return;
  }

  // Guard 3 -- uptime floor on the reboot.
  if (next === "reboot" && uptime < REBOOT_UPTIME_FLOOR) {
    if (!episode.loggedSkips.uptime_floor) {
      episode.loggedSkips.uptime_floor = true;
      recordStep(episode, next, "skipped_guard", { guard: "uptime_floor" });
    }
    return;
  }

  const snap = await takeSnapshot(state, endpoint);
  episode.lastSnapshot = snap.summary;
  logEntry("snapshot", { before: next, snapshot: snap.full });

  if (next === "reboot") {
    await doReboot(state, episode, bootId);
    return;
  }

  let outcome;
  if (next === "nmcli_reconnect") outcome = await stepNmcliReconnect(state.fingerprint);
  else if (next === "radio_cycle") outcome = await stepRadioCycle();
  else outcome = await stepDriverReload();
  episode.done[next] = true;
  recordStep(episode, next, outcome);
}

async function doReboot(state, episode, bootId) {
  // Guard 4 -- the marker must be on the card BEFORE the reboot: it tells boot-print.sh
  // and mqtt-client.js not to print on the boot this causes.
  writeJsonAtomic(REBOOT_MARKER, { writtenBootId: bootId, boundBootId: null });
  episode.reboots += 1;
  state.rebootCount += 1;
  state.offlineSinceLastReboot = 0;
  recordStep(episode, "reboot", "ok", { rebootCount: state.rebootCount });
  state.bootId = bootId;
  state.lastUptime = readUptime();
  state.online = false;
  writeJsonAtomic(STATE_FILE, state);
  await run("sync", [], 30_000);
  const r = await run("systemctl", ["reboot"], 30_000);
  if (!r.ok) {
    logEntry("reboot_failed", { stderr: r.stderr.trim(), timedOut: r.timedOut });
    await run("systemctl", ["reboot", "--force"], 30_000);
  }
}

// Exit explicitly: a getaddrinfo() abandoned by a timeout would otherwise hold the
// event loop open until systemd's TimeoutStartSec kills us.
main()
  .then(() => process.exit(0))
  .catch((err) => {
    logEntry("error", { error: err.message, stack: err.stack });
    process.exit(1);
  });
