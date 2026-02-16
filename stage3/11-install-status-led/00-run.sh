#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install status LED services
# RGB LED indicates state:
#   solid blue = early boot (config.txt), flashing blue = OS booted / IoT disconnected,
#   green = AWS IoT connected, red = boot failure
# ------------------------------------------------------------------------------

# Install status LED control script
echo "Installing status LED script..."
install -D -m 0755 files/status-led.sh "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/bin/status-led.sh"

on_chroot << 'EOF'
# Service for successful boot - flashing blue
cat > /etc/systemd/system/status-led-ok.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit Status LED - Boot OK (Flashing Blue)

[Service]
Type=simple
ExecStart=/usr/local/lib/eatabit/bin/status-led.sh flash-blue
ExecStopPost=/usr/local/lib/eatabit/bin/status-led.sh off
StandardOutput=journal
StandardError=journal
SyslogIdentifier=status-led

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Service for AWS IoT connected - stops flashing, sets solid green
# BindsTo ensures this service stops when mqtt-client stops, resuming flash-blue
cat > /etc/systemd/system/status-led-iot.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit Status LED - AWS IoT Connected
After=status-led-ok.service mqtt-client.service
BindsTo=mqtt-client.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'systemctl stop status-led-ok.service; /usr/local/lib/eatabit/bin/status-led.sh green'
ExecStopPost=/bin/sh -c 'systemctl start status-led-ok.service'
StandardOutput=journal
StandardError=journal
SyslogIdentifier=status-led

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Service for boot failure - sets red
cat > /etc/systemd/system/status-led-fail.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit Status LED - Boot Failed
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'systemctl stop status-led-ok.service 2>/dev/null; /usr/local/lib/eatabit/bin/status-led.sh red'
StandardOutput=journal
StandardError=journal
SyslogIdentifier=status-led

[Install]
WantedBy=emergency.target rescue.target
SERVICE_EOF

# Enable services
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/status-led-ok.service /etc/systemd/system/multi-user.target.wants/status-led-ok.service
ln -sf /etc/systemd/system/status-led-iot.service /etc/systemd/system/multi-user.target.wants/status-led-iot.service

mkdir -p /etc/systemd/system/emergency.target.wants
ln -sf /etc/systemd/system/status-led-fail.service /etc/systemd/system/emergency.target.wants/status-led-fail.service

mkdir -p /etc/systemd/system/rescue.target.wants
ln -sf /etc/systemd/system/status-led-fail.service /etc/systemd/system/rescue.target.wants/status-led-fail.service

echo "Status LED services installed"
EOF
