#!/bin/bash -e

# ------------------------------------------------------------------------------
# Configure UFW firewall for Eatabit device security
# ------------------------------------------------------------------------------

on_chroot << EOF
# Default policies: deny incoming, allow outgoing
ufw --force default deny incoming
ufw --force default allow outgoing

# Allow SSH only from local network (adjust subnet as needed)
# This only affects direct SSH, not ngrok tunnels
ufw allow from 192.168.0.0/16 to any port 22 proto tcp

# Enable UFW on boot
systemctl enable ufw

# Start UFW
ufw --force enable

echo "Firewall configured successfully"
EOF