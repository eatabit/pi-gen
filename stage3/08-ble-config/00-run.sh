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
#
# BUG-040. This used to be a bare `cat >> /etc/bluetooth/main.conf`, which
# appended a second [General] section to the stock file with no end marker. That
# shape is impossible to edit safely later: a field patch cannot tell our block
# from the stock content, and re-running the append leaves a THIRD [General]
# section. The block is now delimited by markers and any earlier copy -- marked
# or legacy -- is removed first, so writing it is idempotent.
#
# NO BACKTICKS OR $ IN THE BLOCK BELOW. on_chroot's heredoc above is UNQUOTED,
# so the BUILD HOST expands the body before the chroot sees it: a `foo` in a
# comment runs foo on the build machine and lands an empty string in the file.
# That silently breaks the byte-identity this stage depends on.
#
# The block below must stay BYTE-IDENTICAL to
# patches/2026-08-20-ble-classic-scan-off/main.conf.eatabit. That is what makes a
# freshly flashed device land on the patch's FIXED_CONF_BLOCK_SHA so the patch
# no-ops instead of hitting its refusal path (ISSUE-065 reconciliation).
echo "Configuring Bluetooth..."
BEGIN_MARK="# >>> eatabit BLE configuration -- managed block, do not edit by hand >>>"
END_MARK="# <<< eatabit BLE configuration -- managed block, do not edit by hand <<<"
if grep -qF "\$BEGIN_MARK" /etc/bluetooth/main.conf 2>/dev/null; then
  awk -v b="\$BEGIN_MARK" -v e="\$END_MARK" \
    'index(\$0,b){f=1} !f{print} f && index(\$0,e){f=0; next}' \
    /etc/bluetooth/main.conf > /tmp/main.conf.new
  mv /tmp/main.conf.new /etc/bluetooth/main.conf
elif grep -qxF "# Eatabit BLE Configuration" /etc/bluetooth/main.conf 2>/dev/null; then
  awk '\$0=="# Eatabit BLE Configuration"{exit} {print}' \
    /etc/bluetooth/main.conf > /tmp/main.conf.new
  mv /tmp/main.conf.new /etc/bluetooth/main.conf
fi
printf '\\n' >> /etc/bluetooth/main.conf
cat >> /etc/bluetooth/main.conf << 'BT_EOF'
# >>> eatabit BLE configuration -- managed block, do not edit by hand >>>
# BUG-040. The CYW43438 shares ONE 2.4 GHz front-end and ONE antenna between WiFi
# and Bluetooth, arbitrated by time-division coexistence. Every millisecond the
# Bluetooth side spends scanning is a millisecond stolen from WiFi.
#
# Provisioning on this product is Bluetooth LOW ENERGY only: ble-config.js
# advertises a GATT service through @abandonware/bleno (LE advertising, LE GATT),
# and the mobile app finds it with react-native-ble-plx startDeviceScan, which is
# LE-only and matches on the LE advertisement's local name. No part of the pairing
# flow uses a classic BR/EDR inquiry or page scan. Those scans therefore buy this
# product nothing and cost it airtime continuously.
[General]
# Restrict the controller to LE. This is what removes BR/EDR page scan and inquiry
# scan -- the PSCAN and ISCAN flags in 'hciconfig -a' -- and it does so WITHOUT
# touching the LE advertising that provisioning actually depends on. The device is
# never less reachable than it was before this change.
ControllerMode = le

# Was 'true'. The kernel implements fast connectable as INTERLACED page scan on a
# 160 ms interval (hci_write_fast_connectable_sync: cp.interval = 0x0100) against
# the 1.28 s standard default (hci_alloc_dev_priv: def_page_scan_int = 0x0800),
# with an unchanged 11.25 ms window (def_page_scan_window = 0x0012). That is an 8x
# nominal -- ~16x once interlacing doubles radio-on time within the window -- rise
# in page-scan duty cycle, permanently, on a shared antenna. BlueZ's own manual
# calls the tradeoff "increased power consumption"; on this hardware it is also
# increased WiFi latency.
#
# Moot while ControllerMode = le, and set explicitly so it stays correct if
# ControllerMode is ever relaxed back to dual.
FastConnectable = false

DiscoverableTimeout = 0
PairableTimeout = 0
Privacy = device

[LE]
MinConnectionInterval = 7
MaxConnectionInterval = 9
ConnectionLatency = 0
ConnectionSupervisionTimeout = 100
# <<< eatabit BLE configuration -- managed block, do not edit by hand <<<
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
# BUG-040: 'bluetoothctl discoverable on' used to be the third ExecStart here. It
# turned on BR/EDR inquiry scan (the ISCAN flag) and, because DiscoverableTimeout
# is 0, it never expired -- so a device provisioned a month ago was still inquiry
# scanning 24/7. Classic discoverability is not used by this product: the mobile
# app discovers the printer by its LE advertisement, never by a classic inquiry.
# The line only ever cost airtime on a shared antenna. Do not restore it.
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

# ------------------------------------------------------------------------------
# ISSUE-068: rotate ble-config.log.
#
# Before this, /etc/logrotate.d/eatabit-mqtt-client was the ONLY logrotate config
# the image wrote, so ble-config.log grew unbounded with nothing configured to
# rotate it. Its measured steady-state growth is 0 B/h -- it is event-driven, not
# periodic, and only grows on BLE pairing activity -- so the risk it carries is a
# burst during a pairing storm, not a steady climb. That is why this stanza pairs
# a time trigger with maxsize: daily rotation keeps the file bounded in normal
# operation, and maxsize forces an out-of-band rotation if a burst outruns it.
#
# create 0644 (not 0666) and a 0755 parent directory are load-bearing: logrotate
# refuses to act on a world-writable parent unless the config carries `su`.
# ------------------------------------------------------------------------------
echo "Configuring log rotation for ble-config..."
cat > /etc/logrotate.d/eatabit-ble-config << 'LOGROTATE_EOF'
/usr/local/lib/eatabit/log/ble-config.log {
  daily
  rotate 7
  maxsize 5M
  compress
  delaycompress
  missingok
  notifempty
  create 0644 root root
}
LOGROTATE_EOF

echo "BLE WiFi configuration server installation complete!"
EOF