#!/usr/bin/env node

/**
 * Generate deviceReady.escpos — ready logo rotated 180° for readability
 *
 * Requires: npm install sharp (or run from a dir that has it)
 *
 * Output:
 *   1. Init printer
 *   2. Logo image rotated 180°
 *   3. 10 line feeds
 *   4. Partial cut
 */

import { readFile, writeFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const __dirname = dirname(fileURLToPath(import.meta.url));

const LOGO_PATH = resolve(__dirname, "../../../iot-assets/images/logos/eatabit-ai_1024_1024_black_white_outlined_ready.png");
const OUT_PATH = resolve(__dirname, "files/deviceReady.escpos");

// ESC/POS constants
const ESC = 0x1b;
const GS = 0x1d;

const INIT_PRINTER = Buffer.from([ESC, 0x40]); // ESC @
const CENTER_ALIGN = Buffer.from([ESC, 0x61, 0x01]); // ESC a 1
const PARTIAL_CUT = Buffer.from([GS, 0x56, 0x01]); // GS V 1
const FEED_LINES = (n) => Buffer.from([ESC, 0x64, n]); // ESC d n

// Target width for thermal printer (576px = 80mm @ 203 DPI)
const TARGET_WIDTH = 576;
// Scale logo to 90% of paper width
const LOGO_WIDTH = Math.round(TARGET_WIDTH * 0.9);

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

  const escpos = Buffer.concat([
    INIT_PRINTER,
    CENTER_ALIGN,

    // Logo image (already rotated 180° by sharp)
    raster.header,
    raster.bitmapData,

    // 8 line feeds after the image
    FEED_LINES(8),

    // Partial cut
    PARTIAL_CUT,
  ]);

  await writeFile(OUT_PATH, escpos);
  console.log(`Generated ${OUT_PATH} (${escpos.length} bytes)`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
