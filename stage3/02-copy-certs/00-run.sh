#!/bin/bash -e

# ------------------------------------------------------------------------------
# Copy AWS certificates and keys
# ------------------------------------------------------------------------------

# Create AWS cert directory
echo "Creating AWS cert directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_LIB_DIR}/cert"; then
  echo "Successfully created ${EATABIT_LIB_DIR}/cert"
else
  echo "Failed to create ${EATABIT_LIB_DIR}/cert"
  exit 1
fi

# Copy AWS root certificate
echo "Copying AWS IoT root certificate..."
if cp -r files/AmazonRootCA1.pem "${ROOTFS_DIR}${EATABIT_LIB_DIR}/cert"; then
  echo "Successfully copied AmazonRootCA1.pem to ${EATABIT_LIB_DIR}/cert"
else
  echo "Failed to copy AmazonRootCA1.pem."
  exit 1
fi

# Copy claim certificate
echo "Copying claim certificate..."
if cp -r files/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt "${ROOTFS_DIR}${EATABIT_LIB_DIR}/cert"; then
  echo "Successfully copied 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt to ${EATABIT_LIB_DIR}/cert"
else
  echo "Failed to copy 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-certificate.pem.crt to ${EATABIT_LIB_DIR}/cert"
  exit 1
fi

# Copy claim private key
echo "Copying claim private key..."
if cp -r files/71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key "${ROOTFS_DIR}${EATABIT_LIB_DIR}/cert"; then
  echo "Successfully copied 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key to ${EATABIT_LIB_DIR}/cert"
else
  echo "Failed to copy 71cc32e68839f91c3d1f96f5ad42e27bf3450c735b8eb928ebb9a0bfb9fb7235-private.pem.key to ${EATABIT_LIB_DIR}/cert"
  exit 1
fi
