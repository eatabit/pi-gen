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
- scp -i ~/.ssh/id_raspberry -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" stage3/09-print-image/files/connected.txt eatabit@192.168.1.78:/tmp/connected.txt

# Test print
- echo "Test print" > /dev/usb/lp0
- echo "<md>TEST PRINT</md>" > /dev/usb/lp0
- 

# Tail the mqtt-client service log
- tail -f /usr/local/lib/eatabit/log/mqtt-client.log
- tail -n 200 /usr/local/lib/eatabit/log/mqtt-client.log

# Reload systemctl
- systemctl daemon-reload

# Rebuild mqtt-client
- cd /usr/local/lib/eatabit/bin && systemctl stop mqtt-client && rm ./mqtt-client.js && nano ./mqtt-client.js
- chmod +x ./mqtt-client.js && systemctl daemon-reload && systemctl start mqtt-client && tail -f /usr/local/lib/eatabit/log/mqtt-client.log

# local SSH 
- ssh -i ~/.ssh/id_raspberry eatabit@192.168.1.78 

# Tail the ble-server log
- tail -f /usr/local/lib/eatabit/log/ble-config.log
- journalctl -u ble-config -b

# This displays detailed information about the Bluetooth adapter(s)
- bluetoothctl show

# Rebuild ble-config
- cd /usr/local/lib/eatabit/bin && systemctl stop ble-config && rm ./ble-config.js && nano ./ble-config.js
- chmod +x ./ble-config.js && systemctl daemon-reload && systemctl start ble-config && tail -f /usr/local/lib/eatabit/log/ble-config.log

# Command to connect to wifi
- nmcli dev wifi connect "ClearPilled" password "9ncx6xwix8jke"

# List wifi networks
- nmcli dev wifi list

# Send a Reset DeviceCommand
- aws dynamodb put-item \
  --table-name DeviceCommand-zuanr4qgbnd7zfoxsjnjkeouxi-NONE \
  --region us-east-2 \
  --item '{
    "id": {"S": "8826dd27-f247-4a26-abf3-417ad4b53601"},
    "deviceId": {"S": "a06fe35f-bd76-49dc-af57-db843a189164"},
    "commandId": {"S": "reset"},
    "createdAt": {"S": "'$(date -u +'%Y-%m-%dT%H:%M:%SZ')'"},
    "state": {"S": "sent"},
    "parameters": {"M": {"reboot": {"BOOL": true}}}
  }' \
  --profile iot

# Send a Reboot DeviceCommand
- aws dynamodb put-item \
  --table-name DeviceCommand-zuanr4qgbnd7zfoxsjnjkeouxi-NONE \
  --region us-east-2 \
  --item '{
    "id": {"S": "8826dd27-f243-4a26-abf3-497ad4b53601"},
    "deviceId": {"S": "a06fe35f-bd76-49dc-af57-db843a189164"},
    "commandId": {"S": "reboot"},
    "createdAt": {"S": "'$(date -u +'%Y-%m-%dT%H:%M:%SZ')'"},
    "state": {"S": "sent"}
  }' \
  --profile iot

# View the log for the device-reset service
- journalctl -u device-reset -f