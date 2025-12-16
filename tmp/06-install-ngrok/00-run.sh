#!/bin/bash -e

# ------------------------------------------------------------------------------
# Install ngrok
# ------------------------------------------------------------------------------

echo "Installing ngrok..."

# Extract ngrok to /usr/local/bin
tar -xvzf "files/ngrok-v3-stable-linux-arm64.tgz" -C /usr/local/bin

# Ensure executable permissions
chmod +x /usr/local/bin/ngrok

echo "ngrok installed successfully"

