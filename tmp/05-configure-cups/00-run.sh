#!/bin/bash -e
# ------------------------------------------------------------------------------
# Configure CUPS for thermal printer
# ------------------------------------------------------------------------------

# Enable CUPS service
on_chroot << 'EOF'
systemctl enable cups
EOF

echo "CUPS configured for thermal printer"