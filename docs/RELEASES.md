# Releases

## Version source of truth

The file `VERSION` in the repo root is the single source of truth for the image version. It contains a semver string (e.g. `1.2.0`).

During the build, the VERSION file is installed to `/usr/local/lib/eatabit/version` on the image. Both `iot-provision.js` and `mqtt-client.js` read it at runtime — no hardcoded versions anywhere.

## Versioning scheme

Follow [Semantic Versioning](https://semver.org/):

| Bump  | When                                                       | Example       |
| ----- | ---------------------------------------------------------- | ------------- |
| MAJOR | Breaking changes (new provisioning flow, cert rotation)    | 1.0.0 → 2.0.0 |
| MINOR | New features, new services, new stage scripts              | 1.0.0 → 1.1.0 |
| PATCH | Bug fixes, config tweaks, dependency updates               | 1.0.0 → 1.0.1 |

## Release workflow

### 1. Create a release branch

Branch from `arm64`:

```bash
git checkout arm64
git pull origin arm64
git checkout -b release/1.1.0
```

### 2. Make changes

Develop and commit on the release branch.

### 3. Update VERSION

```bash
echo "1.1.0" > VERSION
```

### 4. Update CHANGELOG.md

Move items from `[Unreleased]` into a new version section:

```markdown
## [1.1.0] — 2026-04-15

### Added
- ...

### Changed
- ...
```

### 5. Commit the release

```bash
git add VERSION CHANGELOG.md
git commit -m "release: 1.1.0"
```

### 6. Merge to arm64

```bash
git checkout arm64
git merge release/1.1.0
git push origin arm64
```

### 7. Tag the release

```bash
git tag -a v1.1.0 -m "v1.1.0"
git push origin v1.1.0
```

### 8. Clean up

```bash
git branch -d release/1.1.0
git push origin --delete release/1.1.0
```

## Build verification

After merging, build the image and confirm the version is correct:

```bash
./build-docker.sh
```

The output image filename includes the build date: `YYYY-MM-DD-raspios-trixie-armh64.img`

To verify the version baked into the image, mount it and check:

```bash
cat /usr/local/lib/eatabit/version
```

## Changelog format

Use [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) categories:

- **Added** — new features
- **Changed** — changes to existing functionality
- **Deprecated** — features that will be removed
- **Removed** — features that were removed
- **Fixed** — bug fixes
- **Security** — vulnerability fixes
