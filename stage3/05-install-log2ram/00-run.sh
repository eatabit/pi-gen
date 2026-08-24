#!/bin/bash -e

# Install log2ram for SD card longevity

on_chroot << EOF
# Clone log2ram repository -- PINNED. ISSUE-068 Task 10.
#
# This used to be a bare 'git clone' with no ref, so every image build installed
# whatever upstream HEAD happened to be that day, and nothing recorded which version
# an image shipped. log2ram exposes NO version string -- not in the file, not via a
# flag -- so on a device the sha is the only identity available, and without a pin
# there was nothing to compare it against.
#
# The pin is the commit ALREADY RUNNING ON THE FLEET, identified by hashing the
# deployed /usr/local/bin/log2ram and matching it against upstream history: every
# device measured carries sha256 c2f9d53c..., which is upstream d3583ad exactly.
# Pinning to it makes builds reproducible while changing NOTHING about what is
# installed. Deliberately not pinned to a newer or "stable" tag: that would silently
# upgrade log2ram inside a permissions/config change, which is how an unrelated
# regression gets attributed to the wrong commit.
#
# d3583ad is 'git describe' 1.7.2b2-2-gd3583ad -- two commits past a BETA tag. That is
# what the fleet has always run. Moving to a released tag is a separate, deliberate
# decision with its own testing; see ISSUE-068 -> Phase 3.
echo "Cloning log2ram repository (pinned)..."
cd /tmp
git clone https://github.com/azlux/log2ram.git
cd log2ram
git checkout --quiet d3583ad10d0a710bc6c8bd27086515baee36529e
git --no-pager log -1 --format="log2ram pinned at %H (%ad)" --date=short

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
# log2ram configuration.
#
# ONLY THE TWO KEYS BELOW ARE LIVE. log2ram reads SIZE and USE_RSYNC. Four further
# keys used to be set here and NONE of them was ever read (ISSUE-068, verified against
# the installed /usr/local/bin/log2ram on three devices across both hardware lines):
#
#   LOG_DIRS  not a log2ram variable at all -- it reads PATH_DISK. So
#             /usr/local/lib/eatabit/log was NEVER RAM-buffered, and log2ram only ever
#             managed its own built-in default, /var/log.
#   COMP      log2ram reads COMP_ALG
#   MAIL      no such variable
#   ENABLED   no such variable; the service is enabled with systemctl, below
#
# DO NOT "repair" LOG_DIRS by renaming it to PATH_DISK. Three independent reasons:
#
#   1. It would move /usr/local/lib/eatabit/log into a RAM disk, so mqtt-client.log --
#      durable today precisely BECAUSE it sits on the real card -- would vanish on every
#      forced reboot. That is the failure BUG-041 exists to close.
#   2. PATH_DISK is SEMICOLON-separated (the loops run under IFS=';') while this value
#      was space-separated, so a bare rename yields one bogus path, not two good ones.
#   3. The card-wear case for doing it anyway does not survive measurement. ISSUE-068
#      measured ~70-77 MB/day of real writes (ext4 lifetime-writes over 55 days, two
#      devices) against industrial cards with thousands of years of endurance headroom.
#      There is no wear problem to trade log durability for.
#
# Diagnosability wins. See ISSUE-068 -> Phase 3 for the full reasoning.

# Size of the RAM disk backing /var/log
SIZE=64M

# Use rsync rather than cp for the sync
USE_RSYNC=true
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