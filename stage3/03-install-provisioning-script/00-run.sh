#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install provisioning script
# ------------------------------------------------------------------------------

# Copy provisioning script to Eatabit lib bin directory
echo "Installing provisioning script..."
if cp files/iot-provision.js "${ROOTFS_DIR}${EATABIT_LIB_DIR}/bin/iot-provision.js"; then
  echo "Successfully installed provisioning script to ${EATABIT_LIB_DIR}/bin"
  chmod +x "${ROOTFS_DIR}${EATABIT_LIB_DIR}/bin/iot-provision.js"
else
  echo "Failed to install provisioning script to ${EATABIT_LIB_DIR}/bin"
  exit 1
fi

# 