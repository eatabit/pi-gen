#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install boot print service
# Prints "BOOTING / please wait" to thermal printer as early as possible in boot
# ------------------------------------------------------------------------------

echo "Installing boot print ESC/POS file..."

# Create escpos directory
mkdir -p "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos"
chmod 755 "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos"

# Install booting.escpos file
install -D -m 0644 files/booting.escpos \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/booting.escpos"

# Install the boot print script (waits for the printer, then prints). It lives in
# files/ rather than a heredoc here so the BUG-094 field patch can ship the same bytes.
# It skips the receipt after a netwatch-initiated reboot (BUG-094 guard 4).
install -D -m 0755 files/boot-print.sh \
  "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/boot-print.sh"

# Create systemd service — runs as early as possible after local filesystems
on_chroot << 'EOF'
cat > /etc/systemd/system/boot-print.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit Boot Print
DefaultDependencies=no
After=local-fs.target
Before=mqtt-client.service ble-config.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/eatabit/bin/boot-print.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=boot-print

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable the service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/boot-print.service /etc/systemd/system/multi-user.target.wants/boot-print.service

echo "Boot print service installed"
EOF

echo "Boot print installation complete"
