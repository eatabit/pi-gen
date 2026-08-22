# `_template` — starting point for a new field patch. **Not a patch.**

> **Do not `scp` this directory to a device.** It is a skeleton with empty gates; it
> would refuse to do anything useful and only confuse whoever ran it. It is
> deliberately not listed in the *Patches* table in [`../README.md`](../README.md).

## Use

```bash
cp -r patches/_template patches/YYYY-MM-DD-short-slug
```

Then set `PATCH_ID` to the new directory name, fill the gates, and write the
`TODO` sections in `do_apply` / `do_rollback` / `do_check`.

`PATCH_ID` **must** equal the directory name: it is the on-device state path
`/usr/local/lib/eatabit/patches/<PATCH_ID>/`, holding that device's `backup/` and
`applied` marker. See [`../README.md`](../README.md) → *Adding a patch*.

## What you are copying, and why it is not yours to redesign

Everything above the `PATCH-SPECIFIC` divider is machinery every patch needs and that
this repo has got wrong more than once. Copy it verbatim.

**`is_remote_session()` — the part people break.** Restarting `mqtt-client.service`
kills the ngrok tunnel an operator is patching over, because ngrok runs *inside* that
process. So the restart+verify re-execs **detached**. Detecting "am I over SSH" has
two traps, and every field patch written before 2026-08-22 fell into one:

1. **`$SSH_CONNECTION` alone is not enough.** `sudo`'s `env_reset` strips
   `SSH_CONNECTION`, `SSH_CLIENT` and `SSH_TTY`, and the documented invocation is
   `sudo ./apply.sh`. An environment-only test reports "local console" over SSH, runs
   the restart inline, and is killed by the tunnel drop it just caused — taking the
   verify step and the automatic rollback with it.
2. **Matching `sshd` exactly is not enough.** OpenSSH 9.8+ splits the per-connection
   process out as `sshd-session`, keeping the bare name `sshd` only for the listener.
   An exact match succeeds only by climbing past both `sshd-session` frames to the
   listener, and under socket activation (`ssh.socket`) matches nothing at all.
   **Match `sshd*`.**

**`bash "$SELF"` in the re-exec — also not cosmetic.** Executing `$SELF` directly
requires the executable bit. Without it the foreground logs *"running DETACHED"* and
exits 0 while the detached child dies with `Permission denied` — success on screen,
nothing applied.

Both are `BUG-047`. The reference implementation, if you want a filled-in example
rather than a skeleton, is
[`../2026-08-20-ngrok-session-reclaim/apply.sh`](../2026-08-20-ngrok-session-reclaim/apply.sh).

## Conventions worth keeping

- **Checksums are the gate; version strings are informational.** Refuse an
  unrecognised state and **print the observed sha** — that is what makes a patch safe
  to hand to an operator who cannot inspect the device first.
- **Back up before touching anything**, into `$BACKUP_DIR`, so `--rollback` works.
- **`__finalize_*` run in a separate process.** They cannot see locals from
  `do_apply` / `do_rollback`; pass what they need as arguments.
- **Be idempotent.** Re-running a patch on an already-patched device should
  short-circuit, not re-apply.
- **Ship a `--check`.** A no-root dry run is the cheapest thing an operator can do
  over a fragile tunnel before committing to a real run.
