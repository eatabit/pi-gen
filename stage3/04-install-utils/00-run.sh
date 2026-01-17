#!/bin/bash -e

# Copy printer-test.js to eatabit bin directory and make it executable
install -m 755 "files/printer-test.js" "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/"
