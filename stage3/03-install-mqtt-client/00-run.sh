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

# Install default config files (readable/writable by mqtt-client and ble-config services)
echo "Installing default config files..."
install -D -m 0666 files/cutter-type.json \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/config/cutter-type.json"
install -D -m 0666 files/volume.json \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/config/volume.json"
install -D -m 0666 files/light.json \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/config/light.json"

echo "Default config files installed to /usr/local/lib/eatabit/config/"

# Create systemd service unit
cat > "${ROOTFS_DIR}/etc/systemd/system/mqtt-client.service" << 'EOF'
[Unit]
Description=Eatabit AWS IoT Client Service
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/lib/eatabit/cert/device.pem
ConditionPathExists=/usr/local/lib/eatabit/cert/device.key
StartLimitIntervalSec=600
StartLimitBurst=5
StartLimitAction=reboot-force

[Service]
Type=notify
User=root
WorkingDirectory=/usr/local/lib/eatabit
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/mqtt-client.js
# /run/eatabit (tmpfs) holds the device-ready guard flag. RuntimeDirectoryPreserve
# keeps it across a service restart; a reboot or power cycle clears it. That is the
# once-per-power-cycle semantic the ready receipt needs. The flag must not live in
# /tmp -- PrivateTmp=true below hands this unit a fresh namespace on every start,
# which destroys the flag and reprints the receipt (BUG-039).
RuntimeDirectory=eatabit
RuntimeDirectoryPreserve=restart
Restart=always
RestartSec=10
TimeoutStopSec=15
KillMode=mixed
StandardOutput=journal
StandardError=journal
WatchdogSec=180
NotifyAccess=all

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/lib/eatabit/log /tmp /usr/local/lib/eatabit/reset /usr/local/lib/eatabit/config
ReadOnlyPaths=/usr/local/lib/eatabit/cert /usr/local/lib/eatabit/escpos
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