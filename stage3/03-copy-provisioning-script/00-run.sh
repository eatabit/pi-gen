#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install provisioning script
# ------------------------------------------------------------------------------

# Create Eatabit lib bin directory
echo "Creating Eatabit lib bin directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_LIB_DIR}/bin"; then
  echo "Successfully created ${EATABIT_LIB_DIR}/bin"
else
  echo "Failed to create ${EATABIT_LIB_DIR}/bin"
  exit 1
fi

# Copy provisioning script to Eatabit lib bin directory
echo "Installing provisioning script..."
if cp files/iot-provision.sh "${ROOTFS_DIR}${EATABIT_LIB_DIR}/bin/iot-provision.sh"; then
  echo "Successfully installed provisioning script to ${EATABIT_LIB_DIR}/bin"
else
  echo "Failed to install provisioning script to ${EATABIT_LIB_DIR}/bin"
  exit 1
fi

# Make provisioning script executable
echo "Making provisioning script executable..."
if chmod +x "${ROOTFS_DIR}${EATABIT_LIB_DIR}/bin/iot-provision.sh"; then
  echo "Successfully made provisioning script executable."
else
  echo "Failed to make provisioning script executable."
  exit 1
fi