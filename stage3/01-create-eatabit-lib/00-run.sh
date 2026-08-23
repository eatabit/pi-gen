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
  # ISSUE-068: 0755, not 0777. logrotate REFUSES to rotate a file whose parent
  # directory is world-writable unless the config carries an `su` directive, so
  # 0777 here silently disabled rotation for mqtt-client.log on every image ever
  # built. Every writer into this directory runs as root (all eight units that
  # touch /usr/local/lib/eatabit), so 0755 costs nothing. Do not widen this back.
  chmod 0755 "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/log"
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

# Install image version file
install -m 0444 "${BASE_DIR}/VERSION" "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/version"
