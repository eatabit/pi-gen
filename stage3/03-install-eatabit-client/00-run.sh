#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install Eatabit AWS IoT Client Service
# ------------------------------------------------------------------------------

echo "Installing Eatabit client service..."

# Copy the client service script
install -D -m 0755 files/eatabit-service.js \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/eatabit-service.js"

echo "Client script installed to /usr/local/lib/eatabit/bin/eatabit-service.js"

# Create systemd service unit
cat > "${ROOTFS_DIR}/etc/systemd/system/eatabit-client.service" << 'EOF'
[Unit]
Description=Eatabit AWS IoT Client Service
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/lib/eatabit/cert/device.pem
ConditionPathExists=/usr/local/lib/eatabit/cert/device.key

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib/eatabit
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/eatabit-service.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/lib/eatabit/log
ReadOnlyPaths=/usr/local/lib/eatabit/cert /usr/local/lib/eatabit/conf

[Install]
WantedBy=multi-user.target
EOF

echo "Systemd service unit created at /etc/systemd/system/eatabit-client.service"

# Enable the service
on_chroot << 'EOF'
set -e
systemctl daemon-reload
systemctl enable eatabit-client.service
EOF

echo "Eatabit client service installed and enabled"