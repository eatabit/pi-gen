#!/bin/bash -e

# Add NodeSource repository for Node.js 24
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

# The nodejs package will now install version 24