#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install Device Ready ESC/POS Print File
# ------------------------------------------------------------------------------

echo "Installing device ready ESC/POS file..."

# Create escpos directory
mkdir -p "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos"
chmod 755 "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos"

# Install deviceReady.escpos file (readable by mqtt-client service)
install -D -m 0644 files/deviceReady.escpos \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/deviceReady.escpos"

echo "Device ready ESC/POS file installed to /usr/local/lib/eatabit/escpos/deviceReady.escpos"
