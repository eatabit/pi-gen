# Eatabit IoT Pi-Gen Build Instructions

## Project Overview

This is a **customized fork of pi-gen** (Raspberry Pi OS image builder) that creates Raspberry Pi images for **Eatabit IoT devices**. The images include AWS IoT provisioning, MQTT client services, and thermal printer support. Built images deploy to `/deploy/` with datestamp naming.

**Critical**: Work on the `amd64` branch (not master). The amd64 branch is synced with the upstream RPi-Distro/pi-gen repo.

## Build Process

### Primary Build Command
```bash
./build-docker.sh
```
This is the **only** way to build images (uses Docker with debian:trixie base, handles cross-compilation).

### Configuration ([config](config))
- `IMG_NAME`: Base image name (default: `raspios-trixie-armh64`)
- `PI_GEN_RELEASE`: Release identifier (`eatabitv001`)
- `STAGE_LIST`: `"stage0 stage1 stage2 stage3"` (stage3 is our custom layer)
- `EATABIT_ROOT_DIR`: `/usr/local/lib/eatabit` (exported to all stages)

**Never run** `./build.sh` directly - it requires native Linux; use Docker wrapper.

## Stage Architecture

Images are built through numbered stages (0-3), each with subdirectories numbered `00-99`:
- `stageN/XX-package-name/00-packages`: Apt packages to install
- `stageN/XX-package-name/00-run.sh`: Bash scripts executed during build
- `stageN/XX-package-name/files/`: Files copied to image

**Stage execution order**: Stages run 0→3, subdirectories run 00→99, within each:
1. `00-debconf` - Debconf preseeding
2. `00-packages-nr` - Packages without recommends
3. `00-packages` - Standard packages
4. `XX-patches` - Quilt patches
5. `XX-run.sh` - Custom scripts
6. `XX-run-chroot.sh` - Scripts executed inside chroot

### Stage 3: Eatabit Custom Layer ([stage3/](stage3))

**Only stage3 creates the final image** (has `EXPORT_IMAGE` marker). Our custom components:

1. **01-create-eatabit-lib**: Creates `/usr/local/lib/eatabit/{bin,cert,conf,log}` directory structure
2. **02-build-provisioning**: Copies AWS IoT claim certificates and `iot-provision.js` script
3. **03-install-mqtt-client**: Installs `mqtt-client.js` systemd service for AWS IoT communication
4. **04-install-utils**: Adds `printer-test.js` utility
5. **05-install-log2ram**: Configures log2ram for `/var/log` and eatabit logs (SD card protection)

## Key Files & Services

### AWS IoT Provisioning ([stage3/02-build-provisioning/files/](stage3/02-build-provisioning/files))
- **iot-provision.js**: Fleet provisioning script using claim certificates
- Runs on first boot to register device with AWS IoT Core
- Creates permanent device certificates at `/usr/local/lib/eatabit/cert/device.{pem,key}`
- Uses Raspberry Pi serial number as device ID

### MQTT Client Service ([stage3/03-install-mqtt-client/files/mqtt-client.js](stage3/03-install-mqtt-client/files/mqtt-client.js))
- Main application: connects to AWS IoT Core endpoint
- Handles IoT Jobs for print queue management
- Integrates with ESC/POS thermal printers via `/dev/usb/lp0`
- Systemd service: `mqtt-client.service` (waits for device certs to exist)
- Logs to `/usr/local/lib/eatabit/log/mqtt-client.log` (uses log2ram)

### Printer Integration
- Uses ESC/POS protocol (see [docs/status_commands.md](docs/status_commands.md))
- Test command: `echo "<md>TEST PRINT</md>" > /dev/usb/lp0`
- Printer status monitoring via DLE EOT commands

## Development Workflow

### Stage Scripts Pattern
All `00-run.sh` scripts use these environment variables (from build.sh):
- `${ROOTFS_DIR}`: Path to target rootfs being built
- `${EATABIT_ROOT_DIR}`: `/usr/local/lib/eatabit` (from config)
- `${STAGE_WORK_DIR}`: Current stage work directory

**File installation pattern**:
```bash
install -D -m 0755 files/script.js "${ROOTFS_DIR}/usr/local/lib/eatabit/bin/script.js"
```

### Testing on Deployed Devices

**Deploy via SCP**:
```bash
scp -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
  stage3/03-install-mqtt-client/files/mqtt-client.js \
  eatabit@192.168.1.78:/usr/local/lib/eatabit/bin/mqtt-client.js
```

**Service management**:
```bash
systemctl daemon-reload
systemctl restart mqtt-client
tail -f /usr/local/lib/eatabit/log/mqtt-client.log
```

### Branch Sync (Upstream Updates)
```bash
git checkout amd64
git branch -u upstream/amd64 amd64
git pull
git push origin
```

## Common Pitfalls

1. **Don't modify stage0-2** unless syncing with upstream - our changes live in stage3
2. **ROOTFS_DIR is required** in all stage scripts - never hardcode paths
3. **Scripts must be executable**: Use `install -m 0755` or `chmod +x`
4. **Systemd services** need `on_chroot << EOF ... systemctl enable ... EOF`
5. **Log directory permissions**: Must be 0777 for log2ram to work
6. **Build path cannot contain spaces** (debootstrap limitation)

## Project-Specific Conventions

- **Node.js scripts** use `#!/usr/bin/env node` shebang
- **AWS credentials** are claim certs (bootstrap) → permanent device certs (post-provision)
- **Image naming**: Builds appear as `YYYY-MM-DD-raspios-trixie-armh64-lite.{img,info}` in deploy/
- **No desktop environment**: This is a `-lite` image (stage3/EXPORT_IMAGE sets `IMG_SUFFIX="-lite"`)

## External Dependencies

- **AWS IoT Device SDK v2**: Used in both provisioning and mqtt-client
- **ngrok**: For remote SSH tunneling (imported in mqtt-client.js)
- **log2ram**: Azlux project, cloned from GitHub during stage3/05 build
