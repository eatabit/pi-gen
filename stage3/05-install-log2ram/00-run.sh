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

# BUG-041: install the hourly sync override.
#
# The stock upstream timer is OnCalendar=*-*-* 23:55:00 -- a fixed daily wall-clock
# instant, not a rolling 24h -- so worst-case loss is ~23h55m pegged to one moment
# rather than an evenly-spread day. Hourly costs a derived ceiling of ~1 MB/day of
# extra card writes, because log2ram syncs with
#   rsync -aAXv --sparse --inplace --no-whole-file --delete-after
# Only CHANGED BLOCKS are written, so the same appended bytes reach the card either
# way; raising the frequency multiplies only the partial-tail-block amplification,
# not the log volume. See BUG-041 planning.md -> F1, F2, D2.
echo "Installing hourly sync override for log2ram-daily.timer..."
mkdir -p /etc/systemd/system/log2ram-daily.timer.d
cat > /etc/systemd/system/log2ram-daily.timer.d/hourly.conf << 'HOURLY_CONF'
[Timer]
# OnCalendar= is a LIST in systemd. The empty assignment CLEARS the inherited
# 23:55 entry -- without it this timer fires hourly AND at 23:55. Do not delete it.
# systemd-analyze verify cannot catch that case: an additive list is legal.
# Assert with: systemctl show log2ram-daily.timer -p TimersCalendar  (exactly one entry)
OnCalendar=
OnCalendar=hourly
Persistent=true
HOURLY_CONF

# Enable log2ram at boot (will start on first boot)
echo "Enabling log2ram service..."
systemctl enable log2ram

# BUG-041: log2ram-daily.timer is installed above (see the install -Dm 644 line) but
# was never enabled, so /var/log -- a 64M tmpfs -- was written through to the card
# ONLY by log2ram.service's stop action, i.e. only on a clean shutdown.
# StartLimitAction=reboot-force (BUG-044) skips that stop action entirely, destroying
# exactly the logs needed to explain the reboot that destroyed them.
echo "Enabling log2ram-daily.timer..."
systemctl enable log2ram-daily.timer

# Create eatabit log directory if needed
echo "Ensuring eatabit log directory exists..."
mkdir -p /usr/local/lib/eatabit/log
# ISSUE-068: 0755, not 0777 -- see stage3/01-create-eatabit-lib/00-run.sh. A
# world-writable parent makes logrotate skip every file in it, which is why
# mqtt-client.log had never once been rotated on any release of either line.
chmod 0755 /usr/local/lib/eatabit/log

echo "log2ram installation and configuration complete!"
EOF