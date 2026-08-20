"use strict";

// Unit tests for applyWiFiConfig() in ../files/ble-config.js.
//
// The module shells out to nmcli via child_process.execSync. We stub
// cp.execSync with a fake nmcli that records the commands it is asked to run
// and simulates a clean connect, then assert on the profile-creation command.

const { test, beforeEach, afterEach, mock } = require("node:test");
const assert = require("node:assert/strict");
const os = require("node:os");
const path = require("node:path");
const cp = require("child_process");

// EATABIT_DIR is read at module load, so redirect logging to a temp dir before
// requiring the module under test.
process.env.EATABIT_DIR = path.join(os.tmpdir(), "eatabit-ble-test");

const ble = require("../files/ble-config.js");

// A fake nmcli. Records every command, reports "not currently connected" and
// "no existing profile", and reports a successful connect on verification.
function makeFakeNmcli({ existingProfiles = "" } = {}) {
  const commands = [];
  const execSync = (command) => {
    commands.push(command);

    // "Already connected?" probe — grep matches nothing => non-zero exit.
    if (command.includes("con show --active")) {
      throw new Error("grep: no match (exit 1)");
    }
    // List existing profiles to delete.
    if (command.includes("-f NAME con show")) {
      return existingProfiles;
    }
    // Create the connection profile.
    if (command.includes("con add")) {
      return "Connection successfully added.";
    }
    // Bring the connection up.
    if (command.includes("con up")) {
      return "Connection successfully activated.";
    }
    // Verify the device is connected.
    if (command.includes("dev") && command.includes("connected")) {
      return "wlan0:connected";
    }
    return "";
  };
  return { execSync, commands };
}

beforeEach(() => {
  ble.__setWifiState({ ssid: "", password: "" });
});

afterEach(() => {
  mock.restoreAll();
});

test("open network (empty password) creates an unsecured profile and connects", () => {
  const nmcli = makeFakeNmcli();
  mock.method(cp, "execSync", nmcli.execSync);

  ble.__setWifiState({ ssid: "OpenNet", password: "" });
  const result = ble.applyWiFiConfig();

  assert.equal(result, true, "open network should connect successfully");
  assert.equal(
    ble.__getConnectionStatus(),
    "0|1|0",
    "status should be wifi/success/connected",
  );

  const addCmd = nmcli.commands.find((c) => c.includes("con add"));
  assert.ok(addCmd, "a connection profile should have been created");
  assert.ok(addCmd.includes('ssid "OpenNet"'), "profile should target the SSID");
  assert.ok(
    !addCmd.includes("wifi-sec"),
    "open network must not set any wifi-sec parameters",
  );
});

test("secured network (with password) creates a WPA-PSK profile", () => {
  const nmcli = makeFakeNmcli();
  mock.method(cp, "execSync", nmcli.execSync);

  ble.__setWifiState({ ssid: "SecureNet", password: "hunter2!" });
  const result = ble.applyWiFiConfig();

  assert.equal(result, true);
  const addCmd = nmcli.commands.find((c) => c.includes("con add"));
  assert.ok(addCmd, "a connection profile should have been created");
  assert.ok(
    addCmd.includes("wifi-sec.key-mgmt wpa-psk"),
    "secured network should use wpa-psk",
  );
  assert.ok(
    addCmd.includes('wifi-sec.psk "hunter2!"'),
    "secured network should pass the password",
  );
});

test("missing SSID is still rejected", () => {
  const nmcli = makeFakeNmcli();
  mock.method(cp, "execSync", nmcli.execSync);

  ble.__setWifiState({ ssid: "", password: "whatever" });
  const result = ble.applyWiFiConfig();

  assert.equal(result, false, "no SSID should fail");
  assert.equal(
    ble.__getConnectionStatus(),
    "0|0|1",
    "status should be wifi/fail/missing",
  );
  assert.ok(
    !nmcli.commands.some((c) => c.includes("con add")),
    "no profile should be created without an SSID",
  );
});

// ---------------------------------------------------------------------------
// BUG-040 — the Bluetooth radio configuration this stage writes.
//
// These assert on what 00-run.sh EMITS rather than on ble-config.js, because
// BUG-040's fix is entirely in the systemd unit and /etc/bluetooth/main.conf:
// the device was page- and inquiry-scanning 24/7 on a radio front-end it shares
// with WiFi, which cost ~8x the first-hop jitter (ISSUE-064 finding 10).
// Provisioning is LE-only, so classic scanning bought nothing.
//
// The byte-identity assertions are load-bearing, not tidiness. The field patch
// gates on a sha256 of exactly these blocks; if the image drifts from the patch
// payload by even one byte, a freshly flashed device stops no-opping the patch
// and hits its refusal path instead (ISSUE-065 reconciliation).
// ---------------------------------------------------------------------------

const fs = require("node:fs");
const crypto = require("node:crypto");

const RUN_SH = path.join(__dirname, "..", "00-run.sh");
const PATCH_DIR = path.join(
  __dirname,
  "..", "..", "..",
  "patches",
  "2026-08-20-ble-classic-scan-off",
);

// Pull a quoted-heredoc body out of 00-run.sh exactly as the chroot shell
// would receive it.
function heredocBody(delimiter) {
  const lines = fs.readFileSync(RUN_SH, "utf8").split("\n");
  const start = lines.findIndex((l) => new RegExp(`<< '?${delimiter}'?$`).test(l));
  assert.ok(start !== -1, `heredoc ${delimiter} not found in 00-run.sh`);
  const end = lines.indexOf(delimiter, start + 1);
  assert.ok(end !== -1, `heredoc ${delimiter} is not terminated`);
  return lines.slice(start + 1, end).join("\n") + "\n";
}

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");

test("main.conf block is byte-identical to the field patch payload", () => {
  assert.equal(
    heredocBody("BT_EOF"),
    fs.readFileSync(path.join(PATCH_DIR, "main.conf.eatabit"), "utf8"),
    "the image and the patch must install the same bytes, or a reflashed " +
      "device will not no-op the patch",
  );
});

test("bluetooth-poweron.service is byte-identical to the field patch payload", () => {
  assert.equal(
    heredocBody("BTSVC_EOF"),
    fs.readFileSync(path.join(PATCH_DIR, "bluetooth-poweron.service"), "utf8"),
  );
});

test("apply.sh's FIXED_* constants match the payloads it ships", () => {
  const applySh = fs.readFileSync(path.join(PATCH_DIR, "apply.sh"), "utf8");
  const constant = (name) => {
    const m = applySh.match(new RegExp(`^${name}="([0-9a-f]{64})"`, "m"));
    assert.ok(m, `${name} not found in apply.sh`);
    return m[1];
  };
  assert.equal(
    constant("FIXED_CONF_BLOCK_SHA"),
    sha256(fs.readFileSync(path.join(PATCH_DIR, "main.conf.eatabit"))),
  );
  assert.equal(
    constant("FIXED_POWERON_SHA"),
    sha256(fs.readFileSync(path.join(PATCH_DIR, "bluetooth-poweron.service"))),
  );
});

// This is the one that actually bit during development. on_chroot's heredoc in
// 00-run.sh is UNQUOTED, so the build host expands the body before the chroot
// ever sees it: a backtick in a comment runs that command on the build machine
// and substitutes an empty string into the shipped file. It fails silently —
// the image builds, the service starts, and only a sha comparison reveals that
// the deployed file is not the file in the repo.
for (const delimiter of ["SERVICE_EOF", "BT_EOF", "BTSVC_EOF"]) {
  test(`${delimiter} contains no shell-expandable characters`, () => {
    const body = heredocBody(delimiter);
    assert.ok(
      !body.includes("`"),
      `${delimiter} contains a backtick; the build host would execute it`,
    );
    assert.ok(
      !/\$/.test(body),
      `${delimiter} contains a '$'; the build host would expand it`,
    );
  });
}

test("classic BR/EDR scanning is off: no inquiry scan, no fast page scan", () => {
  const conf = heredocBody("BT_EOF");
  const unit = heredocBody("BTSVC_EOF");

  // Restricting the controller to LE is what drops PSCAN and ISCAN. The
  // provisioning path is LE advertising, which this does not touch.
  assert.match(conf, /^ControllerMode = le$/m);

  // true made the kernel use INTERLACED page scan on a 160 ms interval against
  // the 1.28 s default — an order of magnitude more radio-on time, permanently.
  assert.match(conf, /^FastConnectable = false$/m);
  assert.doesNotMatch(conf, /^FastConnectable = true$/m);

  // This ExecStart is what actually turned inquiry scan on at every boot, and
  // DiscoverableTimeout = 0 meant it never expired.
  assert.doesNotMatch(unit, /ExecStart=.*discoverable on/);

  // But the adapter must still be unblocked and powered, or there is no LE
  // advertising and therefore no way back into a device that has lost WiFi.
  assert.match(unit, /ExecStart=.*rfkill unblock bluetooth/);
  assert.match(unit, /ExecStart=.*bluetoothctl power on/);
});

test("main.conf block drops the keys BlueZ has never had", () => {
  const conf = heredocBody("BT_EOF");
  // Verified against bluez 5.79 src/main.conf; trixie ships 5.79+. None of
  // these are real options — keeping them implied a mechanism the file did not
  // have, and in particular implied that Discoverable = true was what held
  // ISCAN on. It was not; the power-on unit was.
  for (const dead of ["InitiallyPowered", "Discoverable =", "Pairable =", "Autoconnect ="]) {
    assert.ok(
      !conf.includes(dead),
      `${dead} is not a BlueZ option and should not be in the block`,
    );
  }
  // Real options that must survive.
  assert.match(conf, /^DiscoverableTimeout = 0$/m);
  assert.match(conf, /^PairableTimeout = 0$/m);
  assert.match(conf, /^Privacy = device$/m);
});

test("the LE provisioning path is left permanently enabled", () => {
  // BUG-040's whole shape rests on this: nothing gates BLE on WiFi state, on
  // NetworkManager, on a dispatcher hook or on a timer, so the device is never
  // less discoverable after the fix than before it. BLE is the last-resort way
  // into a Pi Zero 2 W — there is no Ethernet and SSH rides the WiFi — so a
  // conditional BLE path would be a new way to strand a device in the field.
  const runSh = fs.readFileSync(RUN_SH, "utf8");
  assert.doesNotMatch(runSh, /dispatcher\.d/);
  assert.doesNotMatch(runSh, /ConditionPathExists=.*wpa|ConditionACPower/);

  // ble-config.service must remain a plain always-on unit.
  const svc = heredocBody("SERVICE_EOF");
  assert.match(svc, /^Restart=always$/m);
  assert.match(svc, /^WantedBy=multi-user\.target$/m);
  assert.doesNotMatch(svc, /^Condition/m);
});
