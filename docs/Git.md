# Git Workflow

## Remotes

| Remote     | Repository            | Purpose                  |
| ---------- | --------------------- | ------------------------ |
| `origin`   | `eatabit/pi-gen`      | Our fork (push here)     |
| `upstream` | `RPi-Distro/pi-gen`   | Original repo (pull from here) |

## Branches

- **`arm64`** — production branch, tracks `upstream/arm64`
- **`arm64-development`** — development branch, branched from `arm64`

## Syncing from upstream

Rebase (not merge) to keep a clean history on top of upstream:

```bash
git checkout arm64
git fetch upstream
git rebase upstream/arm64
```

If there are conflicts, resolve them and continue:

```bash
git rebase --continue
```

After rebasing, force-push to origin (since rebase rewrites history):

```bash
git push origin arm64 --force-with-lease
```

## Pushing changes to origin

For new commits (no rebase), a normal push is fine:

```bash
git push origin arm64
```

## One-time GitHub setup

Change the default branch in GitHub from `master` to `arm64`:

**Settings → General → Default branch → change to `arm64`**
