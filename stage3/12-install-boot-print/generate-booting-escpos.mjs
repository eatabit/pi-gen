#!/usr/bin/env node

/**
 * Generate booting.escpos — logo + "Booting..." rotated 180° for readability
 *
 * Requires: npm install sharp (or run from a dir that has it)
 *
 * Output order (printed top-to-bottom, read bottom-to-top when rotated):
 *   1. Init printer
 *   2. 6 line feeds (will be at the "top" when read upside-down)
 *   3. "Booting..." text in upside-down mode
 *   4. Logo image rotated 180°
 *   5. Partial cut
 */

import { readFile, writeFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const __dirname = dirname(fileURLToPath(import.meta.url));

const LOGO_PATH = resolve(__dirname, "../../assets/png/booting.png");
const OUT_PATH = resolve(__dirname, "files/booting.escpos");

// ESC/POS constants
const ESC = 0x1b;
const GS = 0x1d;
const LF = 0x0a;

const INIT_PRINTER = Buffer.from([ESC, 0x40]); // ESC @
const CENTER_ALIGN = Buffer.from([ESC, 0x61, 0x01]); // ESC a 1
const UPSIDE_DOWN_ON = Buffer.from([ESC, 0x7b, 0x01]); // ESC { 1
const UPSIDE_DOWN_OFF = Buffer.from([ESC, 0x7b, 0x00]); // ESC { 0
const BOLD_ON = Buffer.from([ESC, 0x45, 0x01]); // ESC E 1
const BOLD_OFF = Buffer.from([ESC, 0x45, 0x00]); // ESC E 0
const DOUBLE_SIZE = Buffer.from([GS, 0x21, 0x11]); // GS ! 0x11 (double width+height)
const NORMAL_SIZE = Buffer.from([GS, 0x21, 0x00]); // GS ! 0x00
const PARTIAL_CUT = Buffer.from([GS, 0x56, 0x01]); // GS V 1
const FEED_LINES = (n) => Buffer.from([ESC, 0x64, n]); // ESC d n

// Target width for thermal printer (576px = 80mm @ 203 DPI)
const TARGET_WIDTH = 576;
// Scale logo to full paper width
const LOGO_WIDTH = TARGET_WIDTH;

async function pngToRasterData(pngBuf, targetWidth) {
  const image = sharp(pngBuf);
  const metadata = await image.metadata();

  if (!metadata.width || !metadata.height) {
    throw new Error("Could not determine image dimensions");
  }

  const aspectRatio = metadata.height / metadata.width;
  const newWidth = targetWidth;
  const newHeight = Math.round(targetWidth * aspectRatio);

  const { data, info } = await image
    .resize(newWidth, newHeight, { fit: "fill", kernel: "lanczos3" })
    .rotate(180) // Rotate 180 degrees
    .flatten({ background: { r: 255, g: 255, b: 255 } }) // White background for transparency
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
  return { header, bitmapData };
}

async function main() {
  const logoPng = await readFile(LOGO_PATH);
  console.log(`Read logo: ${LOGO_PATH}`);

  const raster = await pngToRasterData(logoPng, LOGO_WIDTH);
  console.log(`Rasterized logo: ${raster.bitmapData.length} bytes`);

  // Build ESC/POS output
  // Order is reversed for 180° readability:
  // Printed: feeds → text → image → cut
  // Read upside-down: image → text → feeds (natural top-to-bottom)
  const escpos = Buffer.concat([
    INIT_PRINTER,
    CENTER_ALIGN,

    // Logo image (already rotated 180° by sharp)
    raster.header,
    raster.bitmapData,

    // 8 line feeds after the image
    FEED_LINES(8),
  ]);

  await writeFile(OUT_PATH, escpos);
  console.log(`Generated ${OUT_PATH} (${escpos.length} bytes)`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
