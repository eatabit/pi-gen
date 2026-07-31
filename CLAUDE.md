# CLAUDE.md — iot-pi

Raspberry Pi gateway OS image, built with pi-gen (a fork of the upstream project).
Bash + Docker; does **not** consume `@eatabit/iot-constants`.

> Workspace-level context (repo map, cross-repo deploy order, skills) lives in the
> parent `CLAUDE.md` at the workspace root.

## Branches — there are two production lines

**Read `docs/Git.md` before committing anything here.** This repo does not have a
single default branch, and that is the easiest thing to get wrong:

| Branch | Purpose | Release from? |
| --- | --- | --- |
| `hw/1.0` | Original hardware production line — all `v1.0.x` releases | Yes |
| `hw/1.1` | LED hat PCB hardware line — all `v1.1.x` releases | Yes |
| `arm64` | Upstream sync point, tracks `upstream/arm64`. **No direct feature work.** | No |

Consequences:

- **A fix that applies to both lines is not done when one branch has it.** Commit on
  one `hw/*` branch, then **cherry-pick the fix commit** (never the release/version-bump
  commit) to the other. For larger shared work touching many files, branch from
  `arm64` and merge into both.
- **Upstream syncs rebase `arm64`, then merge into each `hw/*`** — merge, not rebase,
  to preserve tags and shared history on the release branches.
- `origin` is `eatabit/pi-gen` (our fork); `upstream` is `RPi-Distro/pi-gen`.
- The workspace-root `CLAUDE.md` lists this repo's default as `hw/1.0`. That is the
  GitHub default, not the whole story — `hw/1.1` is equally a release branch.

## Build

```bash
./build-docker.sh            # Docker-based build
CONTINUE=1 ./build-docker.sh # Resume an interrupted build
```

## Stage directory structure

Image builds run numbered stage directories in order:

```
stage3/
├── 00-install-packages/    # Apt packages and Node.js
├── 01-create-eatabit-lib/  # Create /usr/local/lib/eatabit dirs
├── 02-build-provisioning/  # AWS certs and provisioning script
├── 03-install-mqtt-client/ # MQTT client service
├── 04-install-utils/       # Utility scripts
...
```

Each stage directory may contain:

- `00-run.sh` — main script executed on the host
- `00-run-chroot.sh` — script executed inside the chroot
- `00-packages` — apt packages to install
- `files/` — files copied into the image

Rules:

- The **number prefix determines execution order**.
- A stage that depends on an earlier stage must have a higher number.
- One logical component per stage directory.

## Script conventions

```bash
#!/bin/bash -e

# ROOTFS_DIR        - path to the root filesystem being built
# EATABIT_ROOT_DIR  - /usr/local/lib/eatabit (defined in config)

install -D -m 0755 files/script.js "${ROOTFS_DIR}${EATABIT_ROOT_DIR}/bin/script.js"

on_chroot << 'EOF'
systemctl daemon-reload
systemctl enable myservice.service
EOF
```

- Always `#!/bin/bash -e` — fail fast; a half-built image is worse than no image.
- Use `${ROOTFS_DIR}${EATABIT_ROOT_DIR}` for in-image paths.
- Use `on_chroot` for anything that must run inside the image.
- Quote heredocs as `'EOF'` to prevent host-side variable expansion.

## Systemd services

Internet-facing services include security hardening:

```ini
[Unit]
Description=Eatabit Service Name
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib/eatabit
ExecStart=/usr/bin/node /usr/local/lib/eatabit/bin/service.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening (for internet-facing services)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/lib/eatabit/log
ReadOnlyPaths=/usr/local/lib/eatabit/cert

[Install]
WantedBy=multi-user.target
```

- Enable the service in its install script: `systemctl enable service.service`.
- Add a logrotate config for `/usr/local/lib/eatabit/log/*.log`.
- Use `on_chroot` for `systemctl` commands in build scripts.
