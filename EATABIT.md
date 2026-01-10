## Eatabit info

# Branches other than master are synced to the original RPi-Distro/pi-gen repo

# use the amd64 branch

# To update the amd64 branch from ORIGINAL repo
- git checkout amd64
- git branch -u upstream/amd64 amd64
- git pull

# To push changes on amd64 to eatabit fork
- git push origin

# To build an image
- ./build-docker.sh

# SCP command
- scp -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" stage3/03-install-eatabit-client/files/eatabit-service.js eatabit@192.168.1.78:/usr/local/lib/eatabit/bin/eatabit-service.js

# Check printer in CUPS
- lpstat -p thermal_printer

# Test print
- echo "Test print" | lp -d thermal_printer

# Check printer status
- lpstat -p thermal_printer

# Check print queue
- lpstat -o thermal_printer

# Check all jobs
- lpstat -W all

# Detailed printer info
- lpstat -l -p thermal_printer

# Tail the mqtt-client service log
- tail -f /usr/local/lib/eatabit/log/mqtt-client.log

# Reload systemctl
- systemctl daemon-reload