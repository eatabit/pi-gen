const { execSync } = require("child_process");

// Configuration
const PRINTER_DEVICE = "/dev/usb/lp0";

// Helper function to print formatted output
function printStatus(label, hex, binary, bit_info = "") {
  const padding = 20;
  console.log(
    `  ${label.padEnd(padding)} 0x${hex.padStart(2, "0").toUpperCase()} (${parseInt(hex, 16)
      .toString()
      .padStart(3)})  Binary: ${binary.padStart(8)}  ${bit_info}`
  );
}

// Function to check printer status
function checkPrinterStatus() {
  try {
    console.log("\n=== Printer Status Check ===\n");

    // DLE EOT 1 - Printer status (online/offline)
    console.log("Sending DLE EOT 1 (Printer status)...");
    const onlineStatus = execSync(
      `printf "\\x10\\x04\\x01" > ${PRINTER_DEVICE} && timeout 1s dd if=${PRINTER_DEVICE} bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();
    console.log(`Received: ${onlineStatus}\n`);

    // DLE EOT 2 - Offline cause
    console.log("Sending DLE EOT 2 (Offline cause)...");
    const offlineCause = execSync(
      `printf "\\x10\\x04\\x02" > ${PRINTER_DEVICE} && timeout 1s dd if=${PRINTER_DEVICE} bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();
    console.log(`Received: ${offlineCause}\n`);

    // DLE EOT 4 - Paper sensor status
    console.log("Sending DLE EOT 4 (Paper sensor status)...\n");
    const paperStatus = execSync(
      `printf "\\x10\\x04\\x04" > ${PRINTER_DEVICE} && timeout 1s dd if=${PRINTER_DEVICE} bs=1 count=1 2>/dev/null | xxd -p`,
      { encoding: "utf8", shell: "/bin/bash" }
    ).trim();
    console.log(`Received: ${paperStatus}\n`);

    if (!onlineStatus || !offlineCause || !paperStatus) {
      console.log("ERROR: Printer not responding");
      return {
        ready: false,
        reason: "Printer not responding",
      };
    }

    const onlineByte = parseInt(onlineStatus, 16);
    const offlineByte = parseInt(offlineCause, 16);
    const paperByte = parseInt(paperStatus, 16);

    // Print raw responses
    console.log("Raw Responses:");
    printStatus(
      "Printer Status",
      onlineStatus,
      onlineByte.toString(2),
      "0x16=ready, 0x3e=door open"
    );
    printStatus(
      "Offline Cause",
      offlineCause,
      offlineByte.toString(2),
      "Bit2=cover, Bit4=feed, Bit6=error"
    );
    printStatus(
      "Paper Sensor",
      paperStatus,
      paperByte.toString(2),
      "Bit2-3=near-end, Bit6-7=out"
    );

    console.log("\nStatus Analysis:");

    // Check for cover open (bit 2 of offline cause)
    if (offlineByte & 0x04) {
      console.log("  ❌ Cover is OPEN");
      return {
        ready: false,
        reason: "Printer cover is open",
      };
    }

    // Check for paper end (bits 6-7 of paper status)
    if (paperByte & 0xc0) {
      console.log("  ❌ Paper is OUT");
      return {
        ready: false,
        reason: "Printer is out of paper",
      };
    }

    // Check for paper near end (bits 2-3 of paper status)
    if (paperByte & 0x0c) {
      console.log("  ⚠️  Paper is running LOW");
    }

    // Check for mechanical error (bit 6 of offline cause)
    if (offlineByte & 0x40) {
      console.log("  ❌ Mechanical ERROR detected");
      return {
        ready: false,
        reason: "Printer has a mechanical error",
      };
    }

    // Check for auto-cutter error (varies by model, check bit 3)
    if (offlineByte & 0x08) {
      console.log("  ❌ Cutter ERROR detected");
      return {
        ready: false,
        reason: "Printer cutter error",
      };
    }

    console.log("  ✅ Printer is READY");
    return {
      ready: true,
      reason: "Printer is ready",
    };
  } catch (err) {
    console.error(`ERROR: Failed to check printer status: ${err.message}`);
    return {
      ready: false,
      reason: `Status check failed: ${err.message}`,
    };
  }
}

// Run the check if executed directly
const result = checkPrinterStatus();
console.log(`\n=== Result ===`);
console.log(`Ready: ${result.ready}`);
console.log(`Reason: ${result.reason}\n`);