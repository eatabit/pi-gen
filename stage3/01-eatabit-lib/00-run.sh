#!/bin/bash -e

: "${EATABIT_LIB_DIR:?EATABIT_LIB_DIR is not set}"

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
