#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install health monitor service
# Collects system health data every 15 minutes
# ------------------------------------------------------------------------------

# Install health monitor script
echo "Installing health monitor script..."
install -D -m 0755 files/health-monitor.js "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/health-monitor.js"

on_chroot << EOF
# Create systemd service for health monitor
echo "Creating health monitor systemd service..."
cat > /etc/systemd/system/health-monitor.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit Health Monitor
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/health-monitor.js
StandardOutput=journal
StandardError=journal
SyslogIdentifier=health-monitor

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Create systemd timer to run health monitor every 15 minutes
echo "Creating health monitor systemd timer..."
cat > /etc/systemd/system/health-monitor.timer << 'TIMER_EOF'
[Unit]
Description=Eatabit Health Monitor Timer
Requires=health-monitor.service

[Timer]
# Run at boot, then every 15 minutes
OnBootSec=1min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

# Reload systemd daemon
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable health monitor timer
echo "Enabling health monitor timer..."
systemctl enable health-monitor.timer

echo "Health monitor installation complete!"
EOF
