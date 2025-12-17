#!/bin/bash -e

# ------------------------------------------------------------------------------
# Copy AWS certificates and keys
# ------------------------------------------------------------------------------

# Copy AWS root certificates
echo "Copying AWS IoT root certificate..."
if cp -r files/AmazonRootCA1.pem "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/cert"; then
  echo "Successfully copied AmazonRootCA1.pem to ${EATABIT_ROOT_DIR}/cert"
else
  echo "Failed to copy AmazonRootCA1.pem."
  exit 1
fi
if cp -r files/AmazonRootCA3.pem "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/cert"; then
  echo "Successfully copied AmazonRootCA3.pem to ${EATABIT_ROOT_DIR}/cert"
else
  echo "Failed to copy AmazonRootCA3.pem."
  exit 1
fi

# Copy claim certificate
echo "Copying claim certificate..."
if cp -r files/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/cert"; then
  echo "Successfully copied 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt to ${EATABIT_ROOT_DIR}/cert"
else
  echo "Failed to copy 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt to ${EATABIT_ROOT_DIR}/cert"
  exit 1
fi

# Copy claim private key
echo "Copying claim private key..."
if cp -r files/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/cert"; then
  echo "Successfully copied 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key to ${EATABIT_ROOT_DIR}/cert"
else
  echo "Failed to copy 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key to ${EATABIT_ROOT_DIR}/cert"
  exit 1
fi

# ------------------------------------------------------------------------------
# Install provisioning script
# ------------------------------------------------------------------------------

# Copy provisioning script to Eatabit lib bin directory
echo "Installing provisioning script..."
if cp files/iot-provision.js "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/bin/iot-provision.js"; then
  echo "Successfully installed provisioning script to ${EATABIT_ROOT_DIR}/bin"
  chmod +x "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/bin/iot-provision.js"
else
  echo "Failed to install provisioning script to ${EATABIT_ROOT_DIR}/bin"
  exit 1
fi