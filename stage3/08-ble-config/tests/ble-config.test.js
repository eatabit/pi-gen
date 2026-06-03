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
