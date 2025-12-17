#!/bin/bash -e

# ------------------------------------------------------------------------------
# Copy mosquitto AWS config
# ------------------------------------------------------------------------------

# Copy config file to mosquitto conf.d directory
echo "Copying mosquitto AWS config..."
if cp files/mosquitto-aws.conf "${ROOTFS_DIR}/etc/mosquitto/conf.d/"; then
  echo "Successfully copied mosquitto-aws.conf to /etc/mosquitto/conf.d/."
else
  echo "Failed to copy mosquitto-aws.conf."
  exit 1
fi
