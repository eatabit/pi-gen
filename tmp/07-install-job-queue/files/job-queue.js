const fs = require("fs");
const { execSync } = require("child_process");
const chokidar = require("chokidar");
const path = require("path");

const EATABIT_DIR = "/usr/local/lib/eatabit";
const LOG_FILE = `${EATABIT_DIR}/log/job-queue.log`;
const QUEUED_QUEUE_DIR = "/var/spool/eatabit/print-queue/queued";
const DOWNLOADED_QUEUE_DIR = "/var/spool/eatabit/print-queue/downloaded";
const EXPIRED_QUEUE_DIR = "/var/spool/eatabit/print-queue/expired";
const PRINTED_QUEUE_DIR = "/var/spool/eatabit/print-queue/printed";
const ERROR_QUEUE_DIR = "/var/spool/eatabit/print-queue/error";

const watchers = new Map();

const folders = [
  {
    path: QUEUED_QUEUE_DIR,
    handler: downloadDocument,
    name: "queued",
  },
  {
    path: DOWNLOADED_QUEUE_DIR,
    handler: printDocument,
    name: "downloaded",
  },
];

folders.forEach((folder) => {
  const watcher = chokidar.watch(folder.path, {
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 2000, pollInterval: 100 },
  });

  watcher
    .on("add", (filePath) => {
      console.log(`[${folder.name}] New file: ${path.basename(filePath)}`);
      folder.handler(filePath);
    })
    .on("error", (error) => {
      console.error(`[${folder.name}] Error:`, error);
    });

  watchers.set(folder.path, watcher);
});

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

// Initialize logging on startup
initializeLogFile();

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

    if (!onlineStatus || !offlineCause || !paperStatus) {
      return { ready: false, reason: "Printer not responding" };
    }

    const offlineByte = parseInt(offlineCause, 16);
    const paperByte = parseInt(paperStatus, 16);

    if (offlineByte & 0x04) {
      return { ready: false, reason: "Printer cover is open" };
    }

    if (paperByte & 0xc0) {
      return { ready: false, reason: "Printer is out of paper" };
    }

    if (offlineByte & 0x40) {
      return { ready: false, reason: "Printer has a mechanical error" };
    }

    return { ready: true, reason: "Printer is ready" };
  } catch (err) {
    log(`Failed to check printer status: ${err.message}`, "ERROR");
    return { ready: false, reason: `Status check failed: ${err.message}` };
  }
}

// Handler which downloads the document from the provided presigned S3 URI

/* README:
  Files saved to the "queued" directory are JSON metadata files that contain
  the S3 URI of the document to be printed. This handler downloads the actual
  document from S3 and saves it to the "downloaded" directory for printing.

  The schema for the job metadata file is as follows:
  {
    "jobId": "Eatabit Job identifier UUID (not the AWS IoT Job ID)",
    "uri": "https://s3.amazonaws.com/your-bucket/your-object-key?X-Amz-Algorithm=..."
    "expiresAt": "ISO 8601 timestamp indicating when the Eatabit Job expires"
    "contentType": "MIME type of the document, e.g. application/escpos"
  }
*/

function downloadDocument(filePath) {
  try {
    // Read the job metadata file (contains the S3 URI)
    const fileName = path.basename(filePath, ".json");
    const [jobId, versionNumber, expiresAt] = fileName.split("_");
    const jobMetadata = JSON.parse(fs.readFileSync(filePath, "utf8"));

    // If the expiresAt timestamp has been exceeded, move the job to the expired queue
    if (new Date(jobMetadata.expiresAt) < new Date()) {
      log(`Job ${jobId} has expired and will be moved to the expired queue`);
      fs.renameSync(filePath, path.join(EXPIRED_QUEUE_DIR, `${jobId}.json`));
      return;
    }

    log(`Downloading job ${jobId} from URI: ${jobMetadata.uri}`);

    // Download directly to file to preserve binary data
    // The output file is named with jobId and expiresAt to ensure uniqueness
    const outputFile = path.join(
      DOWNLOADED_QUEUE_DIR,
      `${jobId}_${jobMetadata.expiresAt}.escpos`
    );
    execSync(`curl -s "${jobMetadata.uri}" -o "${outputFile}"`, {
      shell: "/bin/bash",
    });

    log(`Job ${jobId} downloaded successfully to ${outputFile}`);

    // Remove the file after successful download
    fs.unlinkSync(filePath);
  } catch (err) {
    log(`Failed to download document: ${err.message}`, "ERROR");
  }
}

function printDocument(filePath) {
  const jobId = path.basename(filePath, ".escpos");

  try {
    log(`Printing job ${jobId} from ${filePath}`);

    // If the expiresAt timestamp has been exceeded, move the job to the expired queue
    const [idPart, expiresAtPart] = jobId.split("_");
    if (new Date(expiresAtPart) < new Date()) {
      log(`Job ${idPart} has expired and will be moved to the expired queue`);
      fs.renameSync(filePath, path.join(EXPIRED_QUEUE_DIR, `${idPart}.escpos`));
      return;
    }

    // Pre-print check
    const preStatus = checkPrinterStatus();
    if (!preStatus.ready) {
      log(`Cannot print job ${jobId}: ${preStatus.reason}`, "ERROR");
      fs.renameSync(filePath, path.join(ERROR_QUEUE_DIR, `${jobId}.escpos`));
      return;
    }

    // Send raw ESC/POS directly to printer device (bypass CUPS)
    execSync(`cat "${filePath}" > /dev/usb/lp0`, { shell: "/bin/bash" });

    // Post-print check
    const postStatus = checkPrinterStatus();
    if (!postStatus.ready) {
      log(
        `Post-print check failed for job ${jobId}: ${postStatus.reason}`,
        "ERROR"
      );
      fs.renameSync(filePath, path.join(ERROR_QUEUE_DIR, `${jobId}.escpos`));
      return;
    }

    log(`Job ${jobId} printed successfully`);
    const printedAt = Math.floor(Date.now() / 1000);
    fs.renameSync(
      filePath,
      path.join(PRINTED_QUEUE_DIR, `${jobId}_${printedAt}.escpos`)
    );
  } catch (err) {
    log(`Failed to print document ${jobId}: ${err.message}`, "ERROR");
    try {
      fs.renameSync(filePath, path.join(ERROR_QUEUE_DIR, `${jobId}.escpos`));
    } catch (_) {
      /* ignore */
    }
  }
}
