#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install BLE WiFi Configuration Service
# Allows devices to configure WiFi via Bluetooth Low Energy
# ------------------------------------------------------------------------------

# Copy BLE server script
echo "Installing BLE configuration server..."
install -D -m 0755 files/ble-config.js "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/ble-config.js"

on_chroot << EOF
# Create systemd service for BLE server
echo "Creating BLE server systemd service..."
cat > /etc/systemd/system/ble-config.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit BLE WiFi Configuration Server
After=bluetooth.target network.target
Requires=bluetooth.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/ble-config.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ble-config

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable bluetooth service
echo "Enabling Bluetooth service..."
# Create enablement symlink without invoking systemd
ln -sf /lib/systemd/system/bluetooth.service /etc/systemd/system/multi-user.target.wants/bluetooth.service

# Create bluetooth configuration
echo "Configuring Bluetooth..."
cat >> /etc/bluetooth/main.conf << 'BT_EOF'

# Eatabit BLE Configuration
[General]
InitiallyPowered = true
Discoverable = true
DiscoverableTimeout = 0
PairableTimeout = 0
Pairable = false
FastConnectable = true
Privacy = device

[LE]
MinConnectionInterval = 7
MaxConnectionInterval = 9
ConnectionLatency = 0
ConnectionSupervisionTimeout = 100
Autoconnect = true
BT_EOF

# Create systemd service to ensure Bluetooth is powered on at boot
echo "Creating Bluetooth power-on service..."
cat > /etc/systemd/system/bluetooth-poweron.service << 'BTSVC_EOF'
[Unit]
Description=Ensure Bluetooth is powered on at startup
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 2 && rfkill unblock bluetooth || true'
ExecStart=/bin/bash -c 'bluetoothctl power on || true'
ExecStart=/bin/bash -c 'bluetoothctl discoverable on || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BTSVC_EOF

# Enable Bluetooth power-on service
echo "Enabling Bluetooth power-on service..."
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/bluetooth-poweron.service /etc/systemd/system/multi-user.target.wants/bluetooth-poweron.service

# Enable and start BLE service
echo "Enabling BLE configuration service..."

# Enable service without systemctl during image build
ln -sf /etc/systemd/system/ble-config.service /etc/systemd/system/multi-user.target.wants/ble-config.service

echo "BLE WiFi configuration server installation complete!"
EOF