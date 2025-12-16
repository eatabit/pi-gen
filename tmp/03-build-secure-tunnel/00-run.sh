#!/bin/bash -e

# ------------------------------------------------------------------------------
# Configure Docker for building AWS IoT Device Client with Secure Tunneling
# ------------------------------------------------------------------------------

DOCKER_IMAGE="public.ecr.aws/aws-iot-device-client/build-image/ubuntu:20.04-arm64-latest"

# Create systemd service to run the secure tunnel container
cat > "${ROOTFS_DIR}/etc/systemd/system/eatabit-secure-tunnel.service" << EOF
[Unit]
Description=Eatabit AWS IoT Secure Tunneling Local Proxy
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStartPre=/usr/bin/docker pull ${DOCKER_IMAGE}
ExecStart=/usr/bin/docker run --rm --name eatabit-localproxy \
  -v /usr/local/lib/eatabit/cert:/certs:ro \
  -v /etc/eatabit/conf:/conf:ro \
  -p 8033:8033 \
  ${DOCKER_IMAGE}
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
on_chroot << 'EOF'
set -e
systemctl daemon-reload
systemctl enable eatabit-secure-tunnel.service
EOF

echo "Secure tunnel container service installed"