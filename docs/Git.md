# Git Workflow

## Remotes

| Remote     | Repository            | Purpose                  |
| ---------- | --------------------- | ------------------------ |
| `origin`   | `eatabit/pi-gen`      | Our fork (push here)     |
| `upstream` | `RPi-Distro/pi-gen`   | Original repo (pull from here) |

## Branches

| Branch | Purpose | Release from? |
| --- | --- | --- |
| `arm64` | Upstream sync point. Tracks `upstream/arm64`. No direct feature work. | No |
| `hw/1.0` | Original hardware production line. All `v1.0.x` releases. | Yes |
| `hw/1.1` | LED hat PCB hardware production line. All `v1.1.x` releases. | Yes |

## Syncing from upstream

The `arm64` branch tracks `upstream/arm64` from [RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen). Upstream changes include base OS build system updates, Debian package changes, and pi-gen stage improvements. These are independent of eatabit-specific stages (`stage2/04-cloud-init`, `stage3/*`), so conflicts are rare.

Sync periodically (before a release, or when upstream has relevant fixes). The process is: rebase `arm64` onto upstream, then merge into each `hw/*` branch.

### 1. Add the upstream remote (one-time)

If `upstream` is not yet configured:

```bash
git remote add upstream https://github.com/RPi-Distro/pi-gen.git
git fetch upstream
```

Verify with `git remote -v` — you should see both `origin` (eatabit fork) and `upstream` (RPi-Distro).

### 2. Update arm64

```bash
git checkout arm64
git fetch upstream
git rebase upstream/arm64
```

This replays eatabit commits on top of the latest upstream. Since `arm64` is not a release branch, rebase keeps the history linear and clean.

If there are conflicts during rebase, resolve them in each file, then:

```bash
git add <resolved-files>
git rebase --continue
```

To abort and return to the pre-rebase state:

```bash
git rebase --abort
```

After a successful rebase, force-push to origin (rebase rewrites history):

```bash
git push origin arm64 --force-with-lease
```

### 3. Propagate to hardware branches

Use **merge** (not rebase) to preserve tags and shared history on the `hw/*` branches:

```bash
git checkout hw/1.0
git merge arm64
git push origin hw/1.0

git checkout hw/1.1
git merge arm64
git push origin hw/1.1
```

Each `hw/*` branch can be updated independently. If one branch isn't ready for upstream changes, skip it.

### 4. Verify

```bash
git log --oneline --graph hw/1.0 hw/1.1 arm64 -10
```

Confirm `arm64` is at the upstream HEAD, and each `hw/*` branch has a merge commit incorporating the upstream changes.

## Shared fixes across hardware lines

Cherry-pick the **fix commit** (not the release/version bump commit) from one `hw/*` branch to the other:

```bash
# Example: fix developed on hw/1.0, apply to hw/1.1
git checkout hw/1.1
git cherry-pick <fix-commit-sha>
```

For larger shared work that touches many files, branch from `arm64` (the common base), develop there, and merge into both `hw/*` branches.

## GitHub setup

Change the default branch in GitHub to `hw/1.0`:

**Settings → General → Default branch → change to `hw/1.0`**
