#!/bin/bash -e

# ------------------------------------------------------------------------------
# Setup eatabit lib
# ------------------------------------------------------------------------------

# Create eatabit lib directory
echo "Creating eatabit lib directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_LIB_DIR}"; then
  echo "Successfully created ${EATABIT_LIB_DIR}"
else
  echo "Failed to create ${EATABIT_LIB_DIR}"
  exit 1
fi

# Create eatabit lib log directory
echo "Creating eatabit lib log directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_LIB_DIR}/log"; then
  echo "Successfully created ${EATABIT_LIB_DIR}/log"
  # Ensure log directory has permissive mode
  chmod 0777 "${ROOTFS_DIR}${EATABIT_LIB_DIR}/log"
else
  echo "Failed to create ${EATABIT_LIB_DIR}/log"
  exit 1
fi

# Create eatabit lib bin directory
echo "Creating eatabit lib bin directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_LIB_DIR}/bin"; then
  echo "Successfully created ${EATABIT_LIB_DIR}/bin"
else
  echo "Failed to create ${EATABIT_LIB_DIR}/bin"
  exit 1
fi

# Create eatabit lib cert directory
echo "Creating eatabit lib cert directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_LIB_DIR}/cert"; then
  echo "Successfully created ${EATABIT_LIB_DIR}/cert"
else
  echo "Failed to create ${EATABIT_LIB_DIR}/cert"
  exit 1
fi

# Create eatabit lib conf directory
echo "Creating eatabit lib conf directory..."
if mkdir -p "${ROOTFS_DIR}${EATABIT_LIB_DIR}/conf"; then
  echo "Successfully created ${EATABIT_LIB_DIR}/conf"
else
  echo "Failed to create ${EATABIT_LIB_DIR}/conf"
  exit 1
fi
