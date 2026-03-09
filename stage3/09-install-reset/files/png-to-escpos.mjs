#!/usr/bin/env node

/**
 * Convert reset.png to ESC/POS raster print data.
 *
 * Usage: node png-to-escpos.mjs
 */

import { readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

// Resolve sharp from iot-backend which has it installed
const __dirname = dirname(fileURLToPath(import.meta.url));
const iotBackendDir = resolve(__dirname, "../../../../iot-backend");
const require = createRequire(iotBackendDir + "/");
const sharp = require("sharp");

const inputPath = resolve(__dirname, "../../../assets/png/reset.png");
const outputPath = resolve(__dirname, "reset.escpos");

const GS = 0x1d;
const ESC = 0x1b;
const LF = 0x0a;
const INIT_PRINTER = Buffer.from([ESC, 0x40]);
const PARTIAL_CUT = Buffer.from([GS, 0x56, 0x01]);
const TARGET_WIDTH = 576; // 80mm thermal paper @ 203 DPI
const IMAGE_WIDTH = Math.round(TARGET_WIDTH * 0.9); // Scale to 90% of paper width

const pngBuf = await readFile(inputPath);
const image = sharp(pngBuf);
const metadata = await image.metadata();

if (!metadata.width || !metadata.height) {
  throw new Error("Could not determine image dimensions");
}

const aspectRatio = metadata.height / metadata.width;
const newWidth = IMAGE_WIDTH;
const newHeight = Math.round(IMAGE_WIDTH * aspectRatio);

const { data, info } = await image
  .resize(newWidth, newHeight, { fit: "fill", kernel: "lanczos3" })
  .flatten({ background: { r: 255, g: 255, b: 255 } })
  .grayscale()
  .raw()
  .toBuffer({ resolveWithObject: true });

// Pad to full printer width (centered)
const printerWidthBytes = Math.ceil(TARGET_WIDTH / 8);
const imageWidthBytes = Math.ceil(info.width / 8);
const offsetBytes = Math.floor((printerWidthBytes - imageWidthBytes) / 2);

const bitmapData = Buffer.alloc(printerWidthBytes * info.height);

for (let y = 0; y < info.height; y++) {
  for (let x = 0; x < info.width; x++) {
    const pixelIndex = y * info.width + x;
    const grayValue = data[pixelIndex];

    if (grayValue < 128) {
      const byteIndex = y * printerWidthBytes + offsetBytes + Math.floor(x / 8);
      const bitIndex = 7 - (x % 8);
      bitmapData[byteIndex] |= 1 << bitIndex;
    }
  }
}

const xL = printerWidthBytes & 0xff;
const xH = (printerWidthBytes >> 8) & 0xff;
const yL = info.height & 0xff;
const yH = (info.height >> 8) & 0xff;

const header = Buffer.from([GS, 0x76, 0x30, 0x00, xL, xH, yL, yH]);
const lineFeeds = Buffer.alloc(10, LF);

const escpos = Buffer.concat([
  INIT_PRINTER,
  header,
  bitmapData,
  lineFeeds,
  PARTIAL_CUT,
]);

await writeFile(outputPath, escpos);
console.log(`${inputPath} → ${outputPath} (${escpos.length} bytes)`);
