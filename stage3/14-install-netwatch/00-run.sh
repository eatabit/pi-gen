#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install netwatch -- network-recovery watchdog (BUG-094)
#
# A oneshot + 60 s timer, independent of mqtt-client. It escalates through an
# nmcli reconnect, a radio cycle, a driver reload and finally a reboot (with
# backoff) when the device has lost the network, and logs every step to a
# card-backed log. See files/netwatch.js for the ladder and its guards.
# ------------------------------------------------------------------------------

echo "Installing netwatch..."

install -D -m 0755 files/netwatch.js \
  "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/bin/netwatch.js"

# Card-backed state: the offline accumulator, the reboot backoff, the network
# fingerprint and the receipt-suppression marker must all survive the reboot they
# describe -- so NOT tmpfs.
mkdir -p "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/state"
chmod 0755 "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/state"

install -D -m 0644 files/netwatch.service "${ROOTFS_DIR}/etc/systemd/system/netwatch.service"
install -D -m 0644 files/netwatch.timer "${ROOTFS_DIR}/etc/systemd/system/netwatch.timer"
install -D -m 0644 files/eatabit-netwatch "${ROOTFS_DIR}/etc/logrotate.d/eatabit-netwatch"

on_chroot << 'CHROOT_EOF'
set -e
systemctl daemon-reload
systemctl enable netwatch.timer
CHROOT_EOF

echo "netwatch installed and its timer enabled"
