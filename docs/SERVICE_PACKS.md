# Service Pack Process — Plan

**Status:** Proposed. Replaces the ad-hoc per-patch model in `patches/`.

## Context

Field fixes currently ship as standalone directories under `patches/`, each with its own
`apply.sh`, version predicates, idempotency check, backup, and rollback. This doesn't scale:

- **Version predicates are bespoke and error-prone.** One patch enumerates
  `AFFECTED_VERSIONS=(1.0.2 … 1.1.1)`; another gates on a sha256 of one specific file. Deciding
  "does patch X apply to device Y" is manual and easy to get wrong.
- **Patches overlap and target disjoint ranges.** `2026-05-12-watchdog-exit-hang` covers
  v1.0.2–v1.0.7 / v1.1.0–v1.1.1; `2026-06-25-offline-reboot-loop` covers v1.0.9 / v1.1.3. Neither
  supersedes the other, they fix overlapping files, and an old device may need *several* applied in
  the right order.
- **No fleet view of "patch level."** There's no single answer to "what fixes does this device
  have?" beyond reading scattered marker files.

We want one idempotent thing to deploy that converges any field device to a known-good state,
regardless of where it started — and that stays in sync with the image releases by construction.

## Core idea: desired-state convergence, not version predicates

A **Service Pack (SP)** is a snapshot of the *desired content* of the post-image, image-owned
runtime files (the eatabit scripts, ESC/POS assets, and systemd units), plus a generic idempotent
engine that converges a device to that state:

> For each managed file: if it already matches the desired content → skip. If it matches a known
> prior version → back it up and replace it. If it's unrecognized (locally modified / foreign) →
> skip and warn (never clobber), unless `--force`.

This removes version predicates entirely — the engine reasons about **content (sha256)**, not
version strings. It is **cumulative** (the SP payload is the latest content, so applying the latest
SP brings everything current in one pass — no chaining), **idempotent** (re-running is a no-op),
and **self-describing** (it writes a manifest of what it did).

Because the SP payload is generated from the same `hw/*` source tree that builds the image, the SP
and the next image are consistent by construction: a device that gets the SP ends up byte-identical
to a freshly flashed next-image device for every managed file.

## Goals / non-goals

**Goals**
- One artifact to deploy per hardware line; always deploy the latest.
- No per-fix version math; safe to run on any device, any version, repeatedly.
- Per-file backup + whole-pack rollback.
- Queryable on-device state (`--status`) and fleet visibility (SP level in the health shadow).
- Generated mechanically from source so it never drifts from the image.

**Non-goals**
- Not a full OTA / package manager. It only converges an explicit allowlist of image-owned files.
- Does not touch device-specific or user-mutable state (certs, `deviceid`, `config/*.json`, shadow
  caches, logs).
- Does not replace the image release process (`RELEASES.md`); it's the stopgap between images.

## What the SP manages

An explicit **allowlist** of image-owned, non-device-specific paths, e.g.:

- `/usr/local/lib/eatabit/bin/*.js` and `*.sh` (mqtt-client, ble-config, health-monitor,
  status-led, boot-print, device-reset, printer-config)
- `/usr/local/lib/eatabit/escpos/*.escpos`
- `/etc/systemd/system/*.service` and `*.timer` (eatabit units)

**Never managed:** `cert/*`, `deviceid`, `version`, `config/cutter-type.json|volume.json|light.json`,
`config/shadow-*.json`, `reset/.reset-flag`, logs.

> **Prep refactor (prerequisite).** Some managed scripts are generated inline as heredocs in the
> stage `00-run.sh` files (`boot-print.sh`, `device-reset.sh`). For the SP generator and the image
> build to share one source of truth, extract these into committed files under
> `stage3/*/files/` that both the build's `install` step and the SP generator consume. This is a
> net-positive cleanup independent of service packs.

## Architecture

```
service-packs/
  engine/
    apply.sh                # generic, identical across all SPs
    lib.sh                  # sha/backup/restart helpers
  1.0/
    sp-1.0-1/
      manifest.json         # generated
      payload/              # the managed files at their desired content
        usr/local/lib/eatabit/bin/mqtt-client.js
        etc/systemd/system/mqtt-client.service
        ...
  1.1/
    sp-1.1-1/
      manifest.json
      payload/...
  README.md                 # index: latest SP per line, baseline, changelog
```

- **Per hardware line.** Payloads differ between `hw/1.0` and `hw/1.1` (LED hat etc.), so SPs are
  built per line. The engine asserts the device's line (from `VERSION` major.minor or a hw marker)
  and refuses a mismatched pack.
- **Engine is generic.** The same `apply.sh`/`lib.sh` ship in every SP; only `manifest.json` +
  `payload/` change.
- **Cumulative numbering.** `sp-<line>-N` increments per line. Always deploy the highest N. Each SP
  records `baseline` (image version it was cut from) and `supersedes`.

### Manifest schema (generated)

```json
{
  "id": "sp-1.0-1",
  "line": "1.0",
  "baseline": "1.0.9",
  "supersedes": null,
  "generated_at": "2026-06-25T00:00:00Z",
  "files": [
    {
      "target": "/usr/local/lib/eatabit/bin/mqtt-client.js",
      "payload": "payload/usr/local/lib/eatabit/bin/mqtt-client.js",
      "mode": "0755",
      "desired_sha256": "b30bc9c2…",
      "known_prior_sha256": ["e80b7a17…", "177e10b8…"],
      "verify": "node --check",
      "on_change": { "reload_systemd": false, "restart": ["mqtt-client.service"] }
    },
    {
      "target": "/etc/systemd/system/mqtt-client.service",
      "payload": "payload/etc/systemd/system/mqtt-client.service",
      "mode": "0644",
      "desired_sha256": "…",
      "known_prior_sha256": ["…"],
      "verify": "systemd-analyze verify",
      "on_change": { "reload_systemd": true, "restart": ["mqtt-client.service"] }
    }
  ]
}
```

- `known_prior_sha256` is **auto-generated** by walking the file's content across released git tags
  for that line — no hand-maintained predicates. A device whose file matches `desired` → skip; a
  prior → replace; neither → skip+warn (or `--force`).
- `verify` is an optional per-file syntax/validity gate run on the staged file before it goes live.
- `on_change` lets the engine batch a single `daemon-reload` + one restart per affected service.

### Engine behavior (`apply.sh`)

```
apply.sh            # converge to this SP (default)
apply.sh --status   # print desired-vs-current sha per file + recorded SP level
apply.sh --dry-run  # show planned actions, change nothing
apply.sh --rollback # restore the backup set from the last apply
apply.sh --force    # replace files whose current sha is unrecognized
```

Apply flow:
1. `require_root`; assert hardware line matches the pack; read `manifest.json`.
2. For each file, classify: `ok` (== desired) / `update` (∈ known_prior) / `unknown` / `missing`.
3. If all `ok` → print summary, exit 0 (idempotent no-op).
4. Back up every file that will change to `…/service-packs/<id>/backup/`.
5. Stage each new file to a temp path, run its `verify`, then atomically `install`/`mv` into place.
6. If any `on_change.reload_systemd` → one `systemctl daemon-reload`. Restart the **union** of
   `on_change.restart` services once; `sleep` + verify each is `active`.
7. On any verify/restart failure → restore the whole backup set, reload/restart, exit non-zero.
8. Write `…/service-packs/<id>/applied` manifest (per-file from→to, timestamp, baseline) and
   update the device's recorded SP level.

Safety properties: atomic per file, pre-flight validity checks, never clobbers unknown content
without `--force`, all-or-nothing rollback, and a re-run is always a no-op.

### Fleet visibility

Record the applied SP level (e.g. `sp-1.0-1`) in the manifest and surface it in the **health
shadow** (a `servicePack` field alongside `imageVersion`) so the dashboard shows, per device, both
the flashed image version and the converged SP level — replacing scattered marker files.

> **Decision to confirm:** whether to also reflect the SP in the reported version string
> (e.g. `1.0.9+sp1`) or keep `version` = flashed image and report SP separately. Recommended:
> keep `version` as the image, report `servicePack` separately to avoid confusing semver.

## Generation tooling

A `make service-pack` target / script that, run on a checked-out `hw/*` branch:
1. Reads a committed **allowlist** (`service-packs/managed-paths.txt`: source-path → target-path,
   mode, verify, on_change).
2. Copies each source file into `service-packs/<line>/sp-<line>-N/payload/<target>` and computes
   `desired_sha256`.
3. Computes `known_prior_sha256` per file by walking that file across the line's release tags.
4. Writes `manifest.json` (baseline = current `VERSION`, supersedes = previous SP).
5. Copies the shared `engine/` in.
6. Updates `service-packs/README.md` index.

Because step 1 reads the same files the image installs, the SP is guaranteed consistent with the
image cut from the same commit. Recommended cadence: regenerate the SP whenever a managed file
changes on a `hw/*` branch (and at each release), so "latest SP" always equals "latest image
content."

## Migration from `patches/`

1. Land the prep refactor (extract heredoc scripts to committed files).
2. Build the engine + generator; generate `sp-1.0-1` and `sp-1.1-1` from current `hw/1.0` / `hw/1.1`.
   Their payloads already contain the watchdog fix (baked since 1.0.8/1.1.2) and the offline-reboot
   fix (once baked in), so the SP subsumes both existing patches.
3. Validate the SP on bench devices spanning several field versions (see Verification).
4. Mark `patches/*` legacy: keep the existing dirs for audit/history, add a note in `patches/README.md`
   pointing to `service-packs/`, and stop authoring new standalone patches.
5. Future fixes = a source change on `hw/*` + regenerate the SP (one workflow), then bake into the
   next image release as usual.

## Risks / edge cases

- **Converging an old file to latest assumes the file is self-contained.** Mitigated by converging
  the *whole* managed set together (consistent combination) and by per-file `verify`. Keep the
  allowlist to genuinely self-contained, image-owned files.
- **Inline-generated scripts** must be extracted first (prep refactor) or the SP can't manage them.
- **Unknown/locally-modified files** are skipped by default (good), which means a tampered device
  won't be fully converged without `--force`; `--status` surfaces these.
- **Hardware-line misdetection** → wrong payload. Engine must hard-assert the line and refuse on
  mismatch.
- **Offline devices** still can't be reached over SSH — same constraint as today; SPs help reachable
  fleet devices and become the partial-OTA payload if/when a pull-based OTA channel is added.
- **`known_prior_sha256` completeness** — if a field variant's sha isn't in the set, the engine
  skips it (safe, not destructive); add the sha and regenerate, or use `--force` after manual review.

## Verification

- **Generator:** run on `hw/1.0` and `hw/1.1`; confirm payload shas match the source files and that
  `known_prior_sha256` includes every released tag's content for each managed file.
- **Engine unit-level:** dry-run/status/apply/rollback against a sandboxed fake root with stubbed
  `systemctl`; assert classification (ok/update/unknown/missing), no-op on already-converged, and
  full restore on a simulated restart failure.
- **On-device matrix:** apply the latest SP to bench units imaged at several versions (e.g. v1.0.6,
  v1.0.8, v1.0.9) → confirm each converges to identical managed-file shas, services come back
  `active`, re-running is a no-op, `--rollback` restores, and the health shadow reports the SP level.
- **Consistency:** diff a converged device's managed files against a freshly flashed next-image
  device → expect zero differences.

## Incremental adoption (smallest first step)

If a full engine is too big to start: generalize the proven `2026-06-25-offline-reboot-loop`
checksum-gated whole-file pattern into the generic `engine/apply.sh` driven by a `manifest.json`,
seed it with just `mqtt-client.js`, and grow the allowlist file-by-file. Each step is independently
useful and keeps the desired-state model from day one.
