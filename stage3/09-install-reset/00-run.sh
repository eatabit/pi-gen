#!/bin/bash -e

# Install device reset mechanism
echo "Installing device reset mechanism..."

# Create reset directory with proper permissions
mkdir -p "${ROOTFS_DIR}/usr/local/lib/eatabit/reset"
chmod 777 "${ROOTFS_DIR}/usr/local/lib/eatabit/reset"

# Install pre-generated reset.escpos (regenerate with: node files/png-to-escpos.mjs files/reset.png files/reset.escpos)
install -D -m 0644 files/reset.escpos "${ROOTFS_DIR}/usr/local/lib/eatabit/reset/reset.escpos"

# Create the reset script
echo "Creating reset script..."
cat > "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/device-reset.sh" << 'RESET_SCRIPT_EOF'
#!/bin/bash

RESET_FLAG="/usr/local/lib/eatabit/reset/.reset-flag"
RESET_PRINT="/usr/local/lib/eatabit/reset/reset.escpos"
PRINTER="/dev/usb/lp0"
MAX_WAIT=30
WAIT_INTERVAL=1

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Device reset script started"

# Check if reset flag exists
if [ ! -f "$RESET_FLAG" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Reset flag not found, exiting"
  exit 0
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Reset flag detected, beginning device reset"

# Wait for printer to become available
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Waiting for printer at $PRINTER..."
WAIT_COUNT=0
while [ ! -e "$PRINTER" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  sleep $WAIT_INTERVAL
  WAIT_COUNT=$((WAIT_COUNT + WAIT_INTERVAL))
done

if [ ! -e "$PRINTER" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: Printer not available after ${MAX_WAIT}s, continuing anyway"
fi

# Wait for NetworkManager to be active
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Waiting for NetworkManager..."
NM_WAIT=0
while ! systemctl is-active --quiet NetworkManager && [ $NM_WAIT -lt $MAX_WAIT ]; do
  sleep $WAIT_INTERVAL
  NM_WAIT=$((NM_WAIT + WAIT_INTERVAL))
done

# Remove all WiFi connection profiles
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Removing WiFi connection profiles..."
for conn in $(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless"||$2=="wifi"{print $1}'); do
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Deleting connection: $conn"
  nmcli con delete "$conn" 2>/dev/null || true
done

echo "[$(date +'%Y-%m-%d %H:%M:%S')] WiFi profiles removed"

# Print reset notification if available
if [ -e "$PRINTER" ] && [ -f "$RESET_PRINT" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Printing reset notification..."
  cat "$RESET_PRINT" > "$PRINTER" 2>/dev/null || true
  sleep 1
fi

# Remove reset flag to prevent running again
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Removing reset flag..."
rm -f "$RESET_FLAG"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Device reset complete"
exit 0
RESET_SCRIPT_EOF

# Make script executable
chmod 755 "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/device-reset.sh"

# Create systemd service that runs early and waits for printer
echo "Creating reset systemd service..."
on_chroot << EOF
cat > /etc/systemd/system/device-reset.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit Device Reset
DefaultDependencies=no
After=local-fs.target NetworkManager.service boot-print.service
Wants=NetworkManager.service
Before=networking.service wifi-poweron.service ble-config.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/eatabit/bin/device-reset.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=device-reset

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable the service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/device-reset.service /etc/systemd/system/multi-user.target.wants/device-reset.service

echo "Device reset service installed"
EOF

echo "Device reset mechanism installation complete"
echo ""
echo "Usage:"
echo "  To trigger reset on next boot:"
echo "    touch /usr/local/lib/eatabit/reset/.reset-flag"
echo ""
echo "  The device will:"
echo "    1. Install the eatabit app"
echo "    2. Remove the reset flag"
echo "    3. Print /usr/local/lib/eatabit/print/reset.escpos"
