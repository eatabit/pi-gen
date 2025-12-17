#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install Python packages
# ------------------------------------------------------------------------------

# Install AWS IoT SDK for Python
echo "Installing AWS IoT SDK for Python..."
on_chroot << EOF
set -e
pip3 install awsiotsdk awscrt --break-system-packages
EOF