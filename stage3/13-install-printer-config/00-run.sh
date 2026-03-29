#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install printer configuration service
# Sends ESC/POS configuration commands to the printer on first boot
# Uses per-command .configured markers — delete individual markers to re-run specific commands
# Handles printer reboots between commands (e.g., buzzer.bin triggers reset_printer)
# Currently configures: buzzer (disable human voice, enable buzzer), wifi (disable wifi radio)
# ------------------------------------------------------------------------------

echo "Installing printer configuration service..."

# Create printer config directory for .bin files
mkdir -p "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config"
chmod 755 "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config"

# Generate buzzer configuration binary from documented hex sequence
# Source: iot-pi/docs/ESCPOS/Custom Setup Commands.md
printf '\x1b\x1c\x26\x20\x56\x31\x20\x64\x6f\x20\x22\x75\x6e\x6c\x6f\x63\x6b\x5f\x70\x61\x72\x61\x22\x0d\x0a' > "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin"
printf '\x1b\x1c\x26\x20\x56\x31\x20\x73\x65\x74\x6b\x65\x79\x0d\x0a\x00\x93\x01\x01\x01' >> "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin"
printf '\x1b\x1c\x26\x20\x56\x31\x20\x73\x65\x74\x6b\x65\x79\x0d\x0a\x00\xdb\x00\x04\x00\x01\x01\x01' >> "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin"
printf '\x1b\x1c\x26\x20\x56\x31\x20\x64\x6f\x20\x22\x73\x61\x76\x65\x5f\x70\x61\x72\x61\x6d\x5f\x7a\x6f\x6e\x65\x22\x0d\x0a' >> "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin"
printf '\x1b\x1c\x26\x20\x56\x31\x20\x64\x6f\x20\x22\x72\x65\x73\x65\x74\x5f\x70\x72\x69\x6e\x74\x65\x72\x22\x0d\x0a' >> "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin"

chmod 644 "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/buzzer.bin"

# Generate wifi-disable configuration binary — turns off printer wifi radio
# Source: iot-pi/docs/ESCPOS/Custom Setup Commands.md
printf '\x1b\x1c\x26\x20\x56\x31\x20\x73\x65\x74\x6b\x65\x79\x0d\x0a\x01\x84\x00\x01\x00' > "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/wifi-disable.bin"
printf '\x1b\x1c\x26\x20\x56\x31\x20\x64\x6f\x20\x22\x73\x61\x76\x65\x5f\x70\x61\x72\x61\x6d\x5f\x7a\x6f\x6e\x65\x22\x0d\x0a' >> "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/wifi-disable.bin"

chmod 644 "${ROOTFS_DIR}/usr/local/lib/eatabit/escpos/printer-config/wifi-disable.bin"

# Create printer config script that sends all .bin files to the printer
cat > "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/printer-config.sh" << 'SCRIPT_EOF'
#!/bin/bash
PRINTER="/dev/usb/lp0"
CONFIG_DIR="/usr/local/lib/eatabit/escpos/printer-config"
MAX_WAIT=30

# Wait for printer to appear, up to MAX_WAIT seconds
# Returns 0 if printer found, 1 if timeout
wait_for_printer() {
  local waited=0
  while [ ! -e "$PRINTER" ] && [ $waited -lt $MAX_WAIT ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -e "$PRINTER" ]
}

# Track if any commands were sent
commands_sent=0
commands_skipped=0

for config_file in "$CONFIG_DIR"/*.bin; do
  [ -f "$config_file" ] || continue

  # Skip if this command was already applied
  if [ -f "$config_file.configured" ]; then
    echo "Already configured: $(basename "$config_file"), skipping"
    commands_skipped=$((commands_skipped + 1))
    continue
  fi

  # Wait for printer (handles previous command rebooting it)
  if ! wait_for_printer; then
    echo "Printer not found after ${MAX_WAIT}s, deferring remaining commands to next boot"
    exit 0
  fi

  # Send command
  echo "Sending printer config: $(basename "$config_file")"
  cat "$config_file" > "$PRINTER" 2>/dev/null || true
  commands_sent=$((commands_sent + 1))

  # Check if printer reboots (disappears within 5s)
  printer_rebooted=false
  for i in $(seq 1 5); do
    if [ ! -e "$PRINTER" ]; then
      printer_rebooted=true
      break
    fi
    sleep 1
  done

  if [ "$printer_rebooted" = true ]; then
    echo "Printer rebooted after $(basename "$config_file"), waiting for recovery..."
    if ! wait_for_printer; then
      echo "Printer did not recover after ${MAX_WAIT}s, deferring remaining commands to next boot"
      # Don't mark this command — it may not have completed
      exit 0
    fi
    sleep 2  # firmware init
  else
    sleep 2  # normal delay between commands
  fi

  # Mark this command as configured
  touch "$config_file.configured"
  echo "Configured: $(basename "$config_file")"
done

echo "Printer configuration complete (sent=$commands_sent, skipped=$commands_skipped)"
SCRIPT_EOF

chmod 755 "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/printer-config.sh"

# Create systemd service — runs after boot print, before operational services
on_chroot << 'EOF'
cat > /etc/systemd/system/printer-config.service << 'SERVICE_EOF'
[Unit]
Description=Eatabit Printer Configuration
DefaultDependencies=no
After=boot-print.service
Before=mqtt-client.service ble-config.service device-reset.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/eatabit/bin/printer-config.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=printer-config

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable the service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/printer-config.service /etc/systemd/system/multi-user.target.wants/printer-config.service

echo "Printer configuration service installed"
EOF

echo "Printer configuration installation complete"
