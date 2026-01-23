#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install Eatabit AWS IoT Client Service
# ------------------------------------------------------------------------------

echo "Installing Eatabit MQTT client service..."

# Copy the client service script
install -D -m 0755 files/mqtt-client.js \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/mqtt-client.js"

echo "Client script installed to /usr/local/lib/eatabit/bin/mqtt-client.js"

# Create config directory for shadow state persistence
echo "Creating config directory for shadow persistence..."
mkdir -p "${ROOTFS_DIR}/usr/local/lib/eatabit/config"
chmod 777 "${ROOTFS_DIR}/usr/local/lib/eatabit/config"

# Create systemd service unit
cat > "${ROOTFS_DIR}/etc/systemd/system/mqtt-client.service" << 'EOF'
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
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/mqtt-client.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/lib/eatabit/log /tmp /usr/local/lib/eatabit/reset /usr/local/lib/eatabit/config
ReadOnlyPaths=/usr/local/lib/eatabit/cert /usr/local/lib/eatabit/conf
CPUAccounting=true
MemoryAccounting=true
TasksAccounting=true

[Install]
WantedBy=multi-user.target
EOF

echo "Systemd service unit created at /etc/systemd/system/mqtt-client.service"

# Enable the service
on_chroot << 'EOF'
set -e
systemctl daemon-reload
systemctl enable mqtt-client.service
EOF

echo "Eatabit MQTT client service installed and enabled"

# ------------------------------------------------------------------------------
# Configure log rotation for MQTT Client service
# ------------------------------------------------------------------------------

cat > "${ROOTFS_DIR}/etc/logrotate.d/eatabit-mqtt-client" << 'EOF'
/usr/local/lib/eatabit/log/mqtt-client.log {
  daily
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
  create 0666 root root
}
EOF

echo "MQTT client service installed and log rotation configured"