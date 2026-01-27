#!/bin/bash -e

# ------------------------------------------------------------------------------
# Setup eatabit lib
# ------------------------------------------------------------------------------

# Create eatabit lib directory
echo "Creating eatabit lib directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_ROOT_DIR}"; then
  echo "Successfully created ${EATABIT_ROOT_DIR}"
else
  echo "Failed to create ${EATABIT_ROOT_DIR}"
  exit 1
fi

# Create eatabit lib log directory
echo "Creating eatabit lib log directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/log"; then
  echo "Successfully created ${EATABIT_ROOT_DIR}/log"
  # Ensure log directory has permissive mode
  chmod 0777 "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/log"
else
  echo "Failed to create ${EATABIT_ROOT_DIR}/log"
  exit 1
fi

# Create eatabit lib bin directory
echo "Creating eatabit lib bin directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/bin"; then
  echo "Successfully created ${EATABIT_ROOT_DIR}/bin"
else
  echo "Failed to create ${EATABIT_ROOT_DIR}/bin"
  exit 1
fi

# Create eatabit lib cert directory
echo "Creating eatabit lib cert directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/cert"; then
  echo "Successfully created ${EATABIT_ROOT_DIR}/cert"
else
  echo "Failed to create ${EATABIT_ROOT_DIR}/cert"
  exit 1
fi

# Create eatabit lib config directory
echo "Creating eatabit lib config directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/config"; then
  echo "Successfully created ${EATABIT_ROOT_DIR}/config"
else
  echo "Failed to create ${EATABIT_ROOT_DIR}/config"
  exit 1
fi
