#!/bin/bash -e

# Install log2ram for SD card longevity

on_chroot << EOF
# Clone log2ram repository
echo "Cloning log2ram repository..."
cd /tmp
git clone https://github.com/azlux/log2ram.git
cd log2ram

# Manually install log2ram (bypass install.sh which checks for running service)
echo "Installing log2ram..."
install -Dm 755 log2ram /usr/local/bin/log2ram
install -Dm 644 log2ram.service /etc/systemd/system/log2ram.service
install -Dm 644 log2ram-daily.service /etc/systemd/system/log2ram-daily.service
install -Dm 644 log2ram-daily.timer /etc/systemd/system/log2ram-daily.timer
install -Dm 644 uninstall.sh /usr/local/bin/uninstall-log2ram.sh

# Configure log2ram
echo "Configuring log2ram..."
cat > /etc/log2ram.conf << 'LOG2RAM_CONF'
# Size of the RAM disk
SIZE=64M

# Directories to sync to RAM (space-separated)
LOG_DIRS="/var/log /usr/local/lib/eatabit/log"

# Use rsync for syncing (faster)
USE_RSYNC=true

# Compression for archived logs
COMP=gzip

# Mail run log (disable for this device)
MAIL=false

# Enable log2ram
ENABLED=true
LOG2RAM_CONF

# Enable log2ram at boot (will start on first boot)
echo "Enabling log2ram service..."
systemctl enable log2ram

# Create eatabit log directory if needed
echo "Ensuring eatabit log directory exists..."
mkdir -p /usr/local/lib/eatabit/log
chmod 777 /usr/local/lib/eatabit/log

echo "log2ram installation and configuration complete!"
EOF