#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install Eatabit Job Queue Service
# ------------------------------------------------------------------------------

echo "Installing Eatabit Job Queue service..."

# Copy the client service script
install -D -m 0755 files/job-queue.js \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/job-queue.js"
echo "Client script installed to /usr/local/lib/eatabit/bin/job-queue.js"

# Create systemd service unit
cat > "${ROOTFS_DIR}/etc/systemd/system/job-queue.service" << 'EOF'
[Unit]
Description=Eatabit Job Queue Service
After=network-online.target mqtt-client.service
Wants=network-online.target
Requires=mqtt-client.service

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib/eatabit
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/job-queue.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/lib/eatabit/log /var/spool/eatabit/print-queue/queued /var/spool/eatabit/print-queue/downloaded /var/spool/eatabit/print-queue/printed /var/spool/eatabit/print-queue/error /var/spool/eatabit/print-queue/expired

[Install]
WantedBy=multi-user.target
EOF

echo "Systemd service unit created at /etc/systemd/system/job-queue.service"

# Enable the service
on_chroot << 'EOF'
set -e
systemctl daemon-reload
systemctl enable job-queue.service
EOF

echo "Eatabit Job Queue service installed and enabled"

# ------------------------------------------------------------------------------
# Configure log rotation for Job Queue service
# ------------------------------------------------------------------------------

cat > "${ROOTFS_DIR}/etc/logrotate.d/eatabit-job-queue" << 'EOF'
/usr/local/lib/eatabit/log/job-queue.log {
  daily
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
  create 0666 root root
}
EOF

echo "Log rotation configured"