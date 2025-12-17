#!/bin/bash -e

# ------------------------------------------------------------------------------
# Build and install AWS IoT Device Client (with Secure Tunneling)
# ------------------------------------------------------------------------------

# Build and install AWS IoT Device Client with Secure Tunneling enabled
on_chroot <<'EOF'
set -e
cd /tmp
git clone --depth 1 https://github.com/awslabs/aws-iot-device-client.git
cd aws-iot-device-client
cmake -B build -DSECURE_TUNNELING=ON -DJOBS=ON -DPUBSUB=ON -DDIAGNOSTICS=OFF -DCOMPONENT_TESTS=OFF
cmake --build build --target aws-iot-device-client -- -j"$(nproc)"
cmake --install build --prefix /usr/local
EOF

# Install systemd unit and default config for AWS IoT Device Client

# Copy service unit
install -D -m 0644 "files/aws-iot-device-client.service" \
  "${ROOTFS_DIR}/etc/systemd/system/aws-iot-device-client.service"

# Install config (create dir if needed)
install -d -m 0755 "${ROOTFS_DIR}/etc/aws-iot-device-client"
install -D -m 0644 "files/config.json" \
  "${ROOTFS_DIR}/etc/aws-iot-device-client/config.json"

# Enable service
on_chroot << 'EOF'
set -e
systemctl daemon-reload
systemctl enable aws-iot-device-client.service
EOF