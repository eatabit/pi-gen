# iot-pi

## Raspberry Pi Commands

## To build an pi-gen image
- ./build-docker.sh

## SCP command
- scp -i ~/.ssh/id_raspberry -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" /Users/gregoleksiak/repos/eatabit/iot/iot-pi/stage3/09-install-reset/files/reset.escpos eatabit@192.168.1.117:/tmp/reset.escpos
- scp -i ~/.ssh/id_raspberry -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" /Users/gregoleksiak/repos/eatabit/iot/iot-pi/stage3/12-install-boot-print/files/booting.escpos eatabit@192.168.1.80:/tmp/booting.escpos
- scp -i ~/.ssh/id_raspberry -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" /Users/gregoleksiak/repos/eatabit/iot/iot-pi/stage3/10-install-ready-print/files/deviceReady.escpos eatabit@192.168.1.117:/tmp/deviceReady.escpos

## Test print
- echo "Test print" > /dev/usb/lp0
- echo "<md>TEST PRINT</md>" > /dev/usb/lp0
- cat /tmp/reset.escpos > /dev/usb/lp0
- cat /tmp/booting.escpos > /dev/usb/lp0
- cat /tmp/deviceReady.escpos > /dev/usb/lp0

## Tail the mqtt-client service log
- tail -f /usr/local/lib/eatabit/log/mqtt-client.log
- tail -n 500 /usr/local/lib/eatabit/log/mqtt-client.log

## Reload systemctl
- systemctl daemon-reload

## Rebuild mqtt-client
- cd /usr/local/lib/eatabit/bin && systemctl stop mqtt-client && rm ./mqtt-client.js && nano ./mqtt-client.js
- chmod +x ./mqtt-client.js && systemctl daemon-reload && systemctl start mqtt-client && tail -f /usr/local/lib/eatabit/log/mqtt-client.log

## View the log for the device-reset service
- journalctl -u mqtt-client -f
- journalctl -u printer-config -f

## Tail the ble-server log
- tail -f /usr/local/lib/eatabit/log/ble-config.log
- journalctl -u ble-config -b

## This displays detailed information about the Bluetooth adapter(s)
- bluetoothctl show

## Rebuild ble-config
- cd /usr/local/lib/eatabit/bin && systemctl stop ble-config && rm ./ble-config.js && nano ./ble-config.js
- chmod +x ./ble-config.js && systemctl daemon-reload && systemctl start ble-config && tail -f /usr/local/lib/eatabit/log/ble-config.log

## Command to connect to wifi
- nmcli dev wifi connect "ClearPilled" password "9ncx6xwix8jke"

## List wifi networks
- nmcli dev wifi list

## Send a Reset DeviceCommand
- aws dynamodb put-item \
  --table-name DeviceCommand-zuanr4qgbnd7zfoxsjnjkeouxi-NONE \
  --region us-east-2 \
  --item '{
    "id": {"S": "8826dd27-f247-4a26-abf3-417ad4653601"},
    "deviceId": {"S": "aaf300d3-7fd0-460b-9626-3373775f9b6d"},
    "commandId": {"S": "reset"},
    "createdAt": {"S": "'$(date -u +'%Y-%m-%dT%H:%M:%SZ')'"},
    "state": {"S": "sent"},
    "parameters": {"M": {"reboot": {"BOOL": true}}}
  }' \
  --profile iot

## Send a Reboot DeviceCommand
- aws dynamodb put-item \
  --table-name DeviceCommand-zuanr4qgbnd7zfoxsjnjkeouxi-NONE \
  --region us-east-2 \
  --item '{
    "id": {"S": "8826dd27-f243-4a26-abf3-497ad4b5360a"},
    "deviceId": {"S": "aaf300d3-7fd0-460b-9626-3373775f9b6d"},
    "commandId": {"S": "reboot"},
    "createdAt": {"S": "'$(date -u +'%Y-%m-%dT%H:%M:%SZ')'"},
    "state": {"S": "sent"}
  }' \
  --profile iot

## View the log for the device-reset service
- journalctl -u device-reset -f

## Send a startNgrokTunnel DeviceCommand
- aws dynamodb put-item \
  --table-name DeviceCommand-zuanr4qgbnd7zfoxsjnjkeouxi-NONE \
  --region us-east-2 \
  --item '{
    "id": {"S": "88d6dd27-f243-4a26-abf3-497ad4b5360a"},
    "deviceId": {"S": "aaf300d3-7fd0-460b-9626-3373775f9b6d"},
    "commandId": {"S": "startNgrokTunnel"},
    "createdAt": {"S": "'$(date -u +'%Y-%m-%dT%H:%M:%SZ')'"},
    "state": {"S": "sent"}
  }' \
  --profile iot

  ## 