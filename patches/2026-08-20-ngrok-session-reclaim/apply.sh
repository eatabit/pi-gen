#!/bin/bash
# Patch: 2026-08-20-ngrok-session-reclaim   (BUG-049, folding in BUG-038 and BUG-039)
#
# SELF-CONTAINED ROLLUP. It absorbed and REPLACED 2026-08-19-device-ready-flag-privatetmp,
# which has since been deleted from patches/ (it survives in git history). There is no
# prerequisite patch. Everything that one installed is installed here:
#   * its mqtt-client.service is carried byte-for-byte (same sha, 84aa9272...), and
#   * its mqtt-client.js is the direct ancestor of the one here (d4647dab... + BUG-049).
# A device that already took the 2026-08-19 patch is ACCEPTED and simply gets the newer
# JS; a device that never took it gets BOTH files in ONE run.
#
# WHY A ROLLUP, and not a patch that depends on the earlier one. The first cut of this
# patch shipped only mqtt-client.js and REQUIRED the 2026-08-19 patch as a pre-state,
# because this JS keeps the device-ready flag in /run/eatabit and only the patched unit
# creates that directory. That worked, but it cost a device that had not taken 2026-08-19
# TWO patch runs and therefore TWO mqtt-client restarts -- and every restart DROPS
# IN-FLIGHT PRINT JOBS. Making the maintenance procedure inflict that harm twice is
# exactly what BUG-049 exists to stop, so the two patches are merged.
#
# ---------------------------------------------------------------------------
# BUG-049 -- one connect/disconnect cycle wedges the device
#
# After ONE connect/disconnect cycle, every later startNgrokTunnel failed with
# reasonCode 500 / "Failed to establish tunnel" -- consistently, single attempts
# included -- until mqtt-client restarted. Remote SSH was unavailable for that entire
# window, and since every field patch ships OVER that SSH tunnel, a patch campaign
# degraded to reboot -> connect -> patch -> reboot per device.
#
# ROOT CAUSE (confirmed, not hypothesised): the @ngrok/ngrok agent SESSION is
# process-global and outlives the tunnel it was created for. ngrok.forward() builds an
# implicit default session and returns only a Listener; closing the listener leaves the
# session connected, and the module exposes no way to reach that implicit session --
# ngrok.disconnect() and ngrok.kill() both close LISTENERS, not sessions. Nothing
# reclaimed sessions. Observed directly on the ngrok API: both LAN printers holding
# sessions with NO tunnels attached, and an orphan session alive since 2026-08-17.
#
# BUG-035's reaper does not help: it reclaims ngrok CREDENTIALS, not sessions.
#
#   F1  Publish a terminal status on BOTH previously silent branches -- the missing
#       authToken guard, and "no active forwarding to stop". Both used to return without
#       publishing, leaving the DeviceCommand at `sent` forever.
#   F2  Bound and serialise the ngrok calls, and RECLAIM THE AGENT SESSION: the tunnel is
#       built on a session we own via SessionBuilder, and stop closes listener AND session.
#   F3  Fix the check-then-act race on the ngrokListener global. Production-confirmed:
#       two live tunnels from pid 124474, the loser uncloseable.
#   F5  Publish the REAL err.message instead of the hardcoded "Failed to establish
#       tunnel", sanitized to AWS's documented StatusReason constraints.
#
# F4 (pinning @ngrok/ngrok) is deliberately NOT here -- it needs its own record.
#
# ---------------------------------------------------------------------------
# BUG-039 -- the device-ready receipt reprints on every service restart
#
# Carried in from the 2026-08-19 patch, unchanged. The "device ready" receipt is meant to
# print ONCE PER POWER CYCLE. Its guard flag lived in /tmp -- but mqtt-client.service sets
# PrivateTmp=true, so systemd hands the unit a FRESH private /tmp on every start and
# destroys the flag. Measured in the field: 5 service starts -> 5 ready prints, 1:1, with
# exactly one boot in 21 h 30 m. A flapping device reprints all night.
#
# The fix is two files and BOTH are required:
#   1) mqtt-client.service gains RuntimeDirectory=eatabit and
#      RuntimeDirectoryPreserve=restart, so systemd creates /run/eatabit (tmpfs) and KEEPS
#      it across a restart.
#   2) mqtt-client.js moves the flag to /run/eatabit/device-ready-printed and no longer
#      swallows a failed flag write.
#
# PrivateTmp=true is NOT removed -- it is correct hardening. The flag was misplaced.
# Installing the JS WITHOUT the unit reintroduces the bug silently, which is why the unit
# is gated here even though most devices will already have it.
#
# ---------------------------------------------------------------------------
# Gating is by CHECKSUM per file, not by version string, and each file is gated
# INDEPENDENTLY so a half-applied device can be completed. An unrecognised file is never
# overwritten -- and the refusal PRINTS the observed sha256 so an unsampled field device
# reports its own state instead of merely being rejected.
#
# NOT YET BYTE-IDENTICAL TO THE RELEASE, and do not assume it. ISSUE-065 owns v1.0.11 /
# v1.1.5, and BUG-044 (unit) and BUG-045 (js) also land in that cut, so the shas the
# release finally ships will differ from the FIXED_* values below. Until ISSUE-065
# reconciles the patch set against the built image, a device freshly flashed to v1.0.11 /
# v1.1.5 will NOT no-op here -- it hits the refusal path and prints its observed sha.
# Safe, but not the intended end state.
#
# NOTE: restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside that
# process). Over SSH this script runs the restart+verify DETACHED and logs to apply.log,
# so the dropped tunnel cannot interrupt the verify/rollback. That detection is carried by
# hand from the 2026-08-19 patch -- per BUG-047's audit it is the only shipped patch that
# gets it right, and there is NO shared patch script.
#
# Usage:
#   sudo ./apply.sh             # apply patch
#   sudo ./apply.sh --rollback  # restore the pre-patch files from backup

set -euo pipefail

PATCH_ID="2026-08-20-ngrok-session-reclaim"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MQTT_CLIENT_JS="/usr/local/lib/eatabit/bin/mqtt-client.js"
UNIT_FILE="/etc/systemd/system/mqtt-client.service"
VERSION_FILE="/usr/local/lib/eatabit/version"
PATCH_STATE_DIR="/usr/local/lib/eatabit/patches/${PATCH_ID}"
BACKUP_DIR="${PATCH_STATE_DIR}/backup"
MARKER_FILE="${PATCH_STATE_DIR}/applied"
LOG="${PATCH_STATE_DIR}/apply.log"
SERVICE="mqtt-client.service"
RUNTIME_DIR="/run/eatabit"
READY_FLAG="${RUNTIME_DIR}/device-ready-printed"
FORCE_INLINE=0
FORCE_DETACH=0

# --- Desired end state -------------------------------------------------------
FIXED_JS_SHA="1d49a43a401d782bf9d72f69f2c9346c21405a17685185bdbd50f03986d60121"
FIXED_UNIT_SHA="84aa9272b43699c7d337f8b6e63f2b90d38306335d51bb3475e2e2f4201fc25f"

# --- Files we are willing to replace ----------------------------------------
# Deliberately NARROW. This patch installs the v1.0.10 / v1.1.4 generation of
# mqtt-client.js with BUG-039 and BUG-049 on top. Devices on materially older builds
# (v1.0.1/1.0.2-1.0.7, v1.1.1) are NOT accepted: dropping this file on them would also
# apply many unrelated intervening changes, which is a different and much larger change
# than this patch is scoped to make, and their unit is a different variant. Those devices
# get the fix through the v1.0.11 / v1.1.5 image release instead. See README.md -> Coverage.
ACCEPTED_PRIOR_JS_SHAS=(
  "323299afb4d62508be5543d3ecb6c7240f8e05dba7ad566f9eb0644017d026c0" # 2026-08-20 first cut (bounded connect, but stranded its late session)
  "d4647dab55ee858206446c9cc0be5c284ac40554f04a75252cc90abafcbc3376" # output of 2026-08-19-device-ready-flag-privatetmp
  "2f8848db0e8fba8a4ffdc10a517a8b154e181ac0a450d580cae9fca11b459866" # stock v1.0.10 / v1.1.4
  "e80b7a1749672b77e5d67c4e70a418ef30ebb946b9b20580ba4a346402790e20" # stock v1.0.8, v1.0.9, v1.1.2, v1.1.3
  "51a012aef50d802bfcec1ff40cf8d2b4d1ad3839f6c4a0be07d957b7d4d095f3" # field patch 2026-06-25-offline-reboot-loop
  "b30bc9c27f6654f309c3aeb3c9ada35f76a6ec978a50f4bc2ed541e7fedb137f" # field patch, broken first cut of the above
  "607f3d2888fbe9b01b5805da0f64f2267824ff5119e64236a94efd8981905bad" # field patch, combined rollup pre connection-rebuild
)
ACCEPTED_PRIOR_UNIT_SHAS=(
  "e92b2a157f0e9604bc8fed567eda7ae4221920372b8df37c8cb8b3ec0dce6edc" # stock unit, v1.0.8-v1.0.10 / v1.1.2-v1.1.4
)

# --- SUPERSEDED js states this patch must NOT touch (ISSUE-065) ---------------
# A device whose mqtt-client.js is DOWNSTREAM of FIXED_JS_SHA already carries this
# patch's fix plus later ones. Such a sha is NOT a prior: the prior list means
# "install my payload over this", and this payload IS 1d49a43a -- so accepting a
# downstream sha would OVERWRITE newer code with older.
#
# Only the js needs this. The unit does not: FIXED_UNIT_SHA (84aa9272) is still what
# v1.0.11 / v1.1.5 render, so a freshly flashed device already reads as "current" on
# that half and needs no new state.
SUPERSEDED_JS_SHAS=(
  "b009b68c8692314ed8476f3bbb3b1d479c3d97fca67240f7bcf96e44444ed339" # 2026-08-19-mqtt-keepalive-tolerance
  "4cafe4db9f942825c5ced68a83591a3ba9663140e6b7d0b5ca708cf866ba3c09" # ISSUE-068 logrotate/permissions
  "7ecbf0ead594437934e3d0e501689a3bf99a1df77acdefb4369b57fc5655a34a" # ISSUE-068 tmpfs snapshots == image source at v1.0.11 / v1.1.5
)

# Informational only; the checksums above are the authoritative gate.
KNOWN_VERSIONS=("1.0.8" "1.0.9" "1.0.10" "1.1.2" "1.1.3" "1.1.4")

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "must be run as root (use: sudo $0)"
  fi
}

current_version() {
  [[ -f $VERSION_FILE ]] || fail "$VERSION_FILE not found -- is this an eatabit Pi image?"
  tr -d '[:space:]' < "$VERSION_FILE"
}

file_sha() { sha256sum "$1" | awk '{print $1}'; }

# Refusal path. Prints the observed sha and everything it was compared against, so a
# device we have never sampled reports its own state in one run. Changes nothing.
refuse_unrecognized() {
  local path=$1 observed=$2; shift 2
  local candidates=("$@") a
  {
    printf '\n[ERROR] Refusing to overwrite an unrecognized file.\n'
    printf '  file:            %s\n' "$path"
    printf '  observed sha256: %s\n' "$observed"
    printf '  device version:  %s\n' "$(current_version 2>/dev/null || echo unknown)"
    printf '  checked against:\n'
    for a in "${candidates[@]}"; do printf '    %s\n' "$a"; done
    printf '\n  This patch is a SELF-CONTAINED ROLLUP -- there is no earlier patch to run\n'
    printf '  first. An unrecognized file here means this build is outside the patch set;\n'
    printf '  it gets the fix through the v1.0.11 / v1.1.5 image release instead.\n'
    printf '  Report the observed sha256 above (see README.md -> Coverage).\n'
    printf '  Nothing has been modified.\n\n'
  } >&2
  exit 1
}

node_check() {
  local node_bin
  node_bin="$(command -v node || true)"
  [[ -x $node_bin ]] || node_bin="/usr/bin/node"
  [[ -x $node_bin ]] || { log "WARNING: node not found, skipping syntax check"; return 0; }
  "$node_bin" --check "$1"
}

unit_check() {
  local unit=$1 tmp
  command -v systemd-analyze >/dev/null 2>&1 || { log "WARNING: systemd-analyze not found, skipping unit verify"; return 0; }
  tmp="/run/${PATCH_ID}-candidate.service"
  cp "$unit" "$tmp"
  local rc=0
  systemd-analyze verify "$tmp" || rc=$?
  rm -f "$tmp"
  return $rc
}

# Is this an SSH session? The obvious test -- $SSH_CONNECTION -- is NOT sufficient:
# sudo's env_reset strips SSH_CONNECTION/SSH_CLIENT/SSH_TTY, and the documented way to
# run this script is `sudo ./apply.sh`. Checking only the environment therefore reports
# "local console" over SSH, the restart runs inline, and it kills the ngrok tunnel it is
# running over -- the precise failure the detach exists to prevent, and the precise
# failure this patch is about. So fall back to walking the parent process chain for
# sshd, which survives sudo. Carried by hand from the 2026-08-19 patch (BUG-047).
#
# NOTE the glob in the walk below. OpenSSH 9.8+ splits the per-connection process out
# as `sshd-session` and keeps the bare name `sshd` only for the top-level listener. So
# an exact `== sshd` test does NOT match the processes directly above us -- it succeeds
# only by climbing all the way past both sshd-session frames to the listener, which is
# not what this walk is meant to be doing. Under systemd socket activation (ssh.socket)
# sshd-session is spawned by systemd and the chain becomes
#   sudo -> sshd-session -> sshd-session -> systemd(1)
# with no `sshd` anywhere: detection would report "local console", the restart would run
# INLINE, and this exact bug would reappear silently inside a patch that reads as fixed.
# `sshd*` matches sshd-session at the immediate parent. It is a strict superset of the
# old test, so it cannot regress a unit where `sshd` already worked (including
# OpenSSH < 9.8, which has no sshd-session at all), and sshd-session/sshd-auth exist
# only to service a real SSH connection, so it cannot false-positive.
# Measured on Debian 13 / OpenSSH_10.0p2, both hardware lines, 2026-08-22 (BUG-047).
# The socket-activation case above is a reasoned projection from measured process
# topology, NOT an observed failure -- ssh.socket is disabled on both bench devices.
is_remote_session() {
  [[ $FORCE_INLINE -eq 1 ]] && return 1
  [[ $FORCE_DETACH -eq 1 ]] && return 0
  [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] && return 0
  local pid=${PPID:-0} comm guard=0
  while [[ $pid -gt 1 && $guard -lt 32 ]]; do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [[ $comm == sshd* ]] && return 0
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
    [[ -z $pid ]] && pid=0
    guard=$((guard + 1))
  done
  return 1
}

# Run a finalize step (which restarts mqtt-client and thus drops an ngrok SSH tunnel).
# Over SSH, re-exec it detached via setsid so the session drop cannot kill it
# mid-restart; results go to $LOG. On a local console, run inline.
run_detached_if_ssh() {
  local internal_cmd=$1; shift
  if is_remote_session; then
    mkdir -p "$PATCH_STATE_DIR"
    log "Over SSH: restarting $SERVICE will CLOSE this session (ngrok runs inside it)."
    log "Running '$internal_cmd' DETACHED so the tunnel drop cannot interrupt it; logging to:"
    log "  $LOG"
    log "After reconnecting (re-issue the startNgrokTunnel cloud command), check:"
    log "  cat $LOG"
    log "  cat $MARKER_FILE"
    # Re-exec via `bash "$SELF"` rather than executing $SELF directly: if this patch
    # directory were delivered by any route that drops the executable bit (a zip, tar
    # without -p, copy-paste into a new file), a direct exec fails with "Permission
    # denied" INSIDE the detached child -- while the foreground has already logged
    # "running DETACHED" and exited 0. The operator sees success and nothing ran.
    # scp -r preserves the bit and these files are 100755 in git, so this is belt and
    # braces, not a live defect (BUG-047, 2026-08-22).
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    else
      nohup bash "$SELF" "$internal_cmd" "$@" </dev/null >>"$LOG" 2>&1 &
    fi
    disown 2>/dev/null || true
    exit 0
  fi
  "$internal_cmd" "$@"
}

restore_backup() {
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]]      && install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  [[ -f "$BACKUP_DIR/mqtt-client.service" ]] && install -m 0644 "$BACKUP_DIR/mqtt-client.service" "$UNIT_FILE"
  systemctl daemon-reload || true
  return 0
}

# -----------------------------------------------------------------------------
# Finalize steps (restart + verify). Invoked inline or re-exec'd detached.
# -----------------------------------------------------------------------------
__finalize_apply() {
  require_root
  local v=$1
  mkdir -p "$PATCH_STATE_DIR"

  systemctl daemon-reload

  # NOTE: on a device that did NOT already have the BUG-039 unit, this restart starts the
  # service into a freshly-created /run/eatabit, so the ready receipt prints exactly ONCE
  # here. That is expected and unavoidable: systemd recreates RuntimeDirectory= on start
  # and discards anything placed there by hand, so the flag cannot be pre-seeded.
  # Subsequent restarts are silent, which is the whole point of the BUG-039 half.
  log "Restarting $SERVICE (may print one ready receipt -- expected, see README)..."
  systemctl restart "$SERVICE"

  sleep 8
  local state
  state="$(systemctl is-active "$SERVICE" || true)"
  if [[ $state != active ]]; then
    log "WARNING: service is in state '$state'. Recent journal:"
    journalctl -u "$SERVICE" -n 30 --no-pager || true
    log "Restoring backup and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "$SERVICE did not return to active; originals restored. Rollback (if needed): $0 --rollback"
  fi

  # The BUG-039 half: the runtime dir must exist and be writable by the unit. If it is
  # not, the flag write fails and that bug is unchanged (but now logged).
  if [[ ! -d $RUNTIME_DIR ]]; then
    log "WARNING: $RUNTIME_DIR does not exist after restart -- RuntimeDirectory= did not take effect."
    log "Restoring backup and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "$RUNTIME_DIR missing; originals restored."
  fi

  if journalctl -u "$SERVICE" -b --no-pager 2>/dev/null | grep -q 'Failed to persist device ready flag'; then
    log "WARNING: the service logged a failed flag write -- the BUG-039 guard is NOT working."
    log "Recent journal:"
    journalctl -u "$SERVICE" -n 30 --no-pager || true
    log "Restoring backup and restarting..."
    restore_backup
    systemctl restart "$SERVICE" || true
    printf 'applied_at=%s\nfrom_version=%s\nresult=failed-rolledback\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE" || true
    fail "flag write failed under ProtectSystem=strict; originals restored."
  fi

  printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
  log "Patch applied successfully. Service: $state"
  log "Runtime dir: $(ls -ld "$RUNTIME_DIR")"
  log "Originals backed up at: $BACKUP_DIR"
  log "Rollback command: sudo $0 --rollback"
  log ""
  log "VERIFY BUG-049 -- the SECOND start of a process lifetime is the assertion:"
  log "  1) startNgrokTunnel  -> expect success"
  log "  2) stopNgrokTunnel   -> expect SUCCEEDED (reasonCode 200)"
  log "  3) startNgrokTunnel  -> MUST succeed. Before this patch it failed 500."
  log "  Repeat 1-3 at least three times. Also confirm on the ngrok API that no"
  log "  tunnel-less agent session remains after step 2."
  log ""
  log "VERIFY BUG-039 -- a restart must NOT reprint the ready receipt:"
  log "  sudo systemctl restart $SERVICE   # detached if over SSH"
  log "  systemctl show $SERVICE -p ExecMainStartTimestamp"
  log "  ls -l --time-style=full-iso $READY_FLAG   # mtime OLDER than the start above"
}

__finalize_rollback() {
  require_root
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  rm -f "$MARKER_FILE"
  sleep 5
  log "Rollback complete. Service is: $(systemctl is-active "$SERVICE" || true)"
}

# -----------------------------------------------------------------------------
# Rollback
# -----------------------------------------------------------------------------
do_rollback() {
  require_root
  log "Rolling back patch ${PATCH_ID}..."

  [[ -d $BACKUP_DIR ]] || fail "no backup directory at $BACKUP_DIR -- nothing to roll back"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]]      || fail "no backup of mqtt-client.js in $BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.service" ]] || fail "no backup of mqtt-client.service in $BACKUP_DIR"

  install -m 0755 "$BACKUP_DIR/mqtt-client.js" "$MQTT_CLIENT_JS"
  install -m 0644 "$BACKUP_DIR/mqtt-client.service" "$UNIT_FILE"
  log "Restored $MQTT_CLIENT_JS and $UNIT_FILE"

  # If we are rolling back TO a pre-BUG-039 build, it reads its flag from /tmp and
  # /run/eatabit is dead weight. (It is tmpfs, so it would vanish at the next boot anyway.)
  if [[ "$(file_sha "$BACKUP_DIR/mqtt-client.service")" != "$FIXED_UNIT_SHA" ]]; then
    rm -f "$READY_FLAG"
    rmdir "$RUNTIME_DIR" 2>/dev/null || true
  fi

  run_detached_if_ssh __finalize_rollback
}

# -----------------------------------------------------------------------------
# Check (dry run)
# -----------------------------------------------------------------------------
# Reports exactly what `apply` would do and CHANGES NOTHING. Deliberately does not
# require root: it only reads. Use it to survey a fleet before a campaign -- a device's
# VERSION STRING does not determine the outcome, the file checksums do, and a device can
# carry a version whose files were altered by an earlier field patch.
#
# Exit codes:  0 = already patched (no-op)   1 = would refuse   2 = would apply
do_check() {
  local v js_sha unit_sha js_state unit_state prior rc
  v="$(current_version 2>/dev/null || echo unknown)"

  [[ -f $MQTT_CLIENT_JS ]] || fail "$MQTT_CLIENT_JS not found."
  [[ -f $UNIT_FILE ]]      || fail "$UNIT_FILE not found."
  js_sha="$(file_sha "$MQTT_CLIENT_JS")"
  unit_sha="$(file_sha "$UNIT_FILE")"

  js_state=refuse
  if [[ $js_sha == "$FIXED_JS_SHA" ]]; then
    js_state=current
  else
    for s in "${SUPERSEDED_JS_SHAS[@]}"; do [[ $js_sha == "$s" ]] && js_state=superseded; done
    [[ $js_state == superseded ]] ||
    for prior in "${ACCEPTED_PRIOR_JS_SHAS[@]}"; do [[ $js_sha == "$prior" ]] && js_state=upgrade; done
  fi

  unit_state=refuse
  if [[ $unit_sha == "$FIXED_UNIT_SHA" ]]; then
    unit_state=current
  else
    for prior in "${ACCEPTED_PRIOR_UNIT_SHAS[@]}"; do [[ $unit_sha == "$prior" ]] && unit_state=upgrade; done
  fi

  printf 'patch          %s\n' "$PATCH_ID"
  printf 'version        %s\n' "$v"
  printf 'js    sha256   %s  [%s]\n' "$js_sha" "$js_state"
  printf 'unit  sha256   %s  [%s]\n' "$unit_sha" "$unit_state"

  if [[ $js_state == refuse || $unit_state == refuse ]]; then
    printf 'RESULT         WOULD REFUSE -- unrecognized %s; nothing would be modified\n' \
      "$( [[ $js_state == refuse && $unit_state == refuse ]] && echo 'js and unit' \
          || { [[ $js_state == refuse ]] && echo js || echo unit; } )"
    rc=1
  elif [[ $js_state == superseded && ( $unit_state == current || $unit_state == superseded ) ]]; then
    printf 'RESULT         NO-OP -- device is AHEAD of this patch; its mqtt-client.js is\n'
    printf '               downstream of %s. Applying would DOWNGRADE it.\n' "${FIXED_JS_SHA:0:16}"
    rc=0
  elif [[ $js_state == current && $unit_state == current ]]; then
    printf 'RESULT         NO-OP -- already fully patched\n'
    rc=0
  else
    local what=""
    [[ $js_state == upgrade ]]   && what="js"
    [[ $unit_state == upgrade ]] && what="${what:+$what and }unit"
    printf 'RESULT         WOULD APPLY -- installs %s, then ONE mqtt-client restart\n' "$what"
    rc=2
  fi
  return $rc
}

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------
do_apply() {
  require_root

  local v js_sha unit_sha
  v="$(current_version)"
  log "Detected device version: $v"

  [[ -f $MQTT_CLIENT_JS ]] || fail "$MQTT_CLIENT_JS not found."
  [[ -f $UNIT_FILE ]]      || fail "$UNIT_FILE not found."

  js_sha="$(file_sha "$MQTT_CLIENT_JS")"
  unit_sha="$(file_sha "$UNIT_FILE")"

  # Idempotency: both files already carry the fix.
  if [[ $js_sha == "$FIXED_JS_SHA" && $unit_sha == "$FIXED_UNIT_SHA" ]]; then
    log "mqtt-client.js and mqtt-client.service already contain the fix. Nothing to do."
    mkdir -p "$PATCH_STATE_DIR"
    [[ -f $MARKER_FILE ]] || printf 'applied_at=%s\nfrom_version=%s\nresult=success\n' "$(date -Iseconds)" "$v" > "$MARKER_FILE"
    exit 0
  fi

  # Gate each file independently. A half-applied device -- including one that took the
  # superseded 2026-08-19 patch, whose unit is already correct -- is completed rather
  # than refused.
  local need_js=0 need_unit=0 is_accepted prior

  local sup js_superseded=0
  for sup in "${SUPERSEDED_JS_SHAS[@]}"; do [[ $js_sha == "$sup" ]] && js_superseded=1; done

  if (( js_superseded )); then
    # ISSUE-065: the device is ahead of us. Leave the js alone -- installing the payload
    # would downgrade it -- and let the unit gate below decide independently.
    log "mqtt-client.js (sha $js_sha) is DOWNSTREAM of this patch; leaving it untouched."
    log "The device already carries this fix and later ones -- applying would DOWNGRADE it."
  elif [[ $js_sha != "$FIXED_JS_SHA" ]]; then
    is_accepted=0
    for prior in "${ACCEPTED_PRIOR_JS_SHAS[@]}"; do [[ $js_sha == "$prior" ]] && is_accepted=1; done
    (( is_accepted )) || refuse_unrecognized "$MQTT_CLIENT_JS" "$js_sha" "${ACCEPTED_PRIOR_JS_SHAS[@]}" "$FIXED_JS_SHA"
    need_js=1
  else
    log "mqtt-client.js already at the fixed sha."
  fi

  if [[ $unit_sha != "$FIXED_UNIT_SHA" ]]; then
    is_accepted=0
    for prior in "${ACCEPTED_PRIOR_UNIT_SHAS[@]}"; do [[ $unit_sha == "$prior" ]] && is_accepted=1; done
    (( is_accepted )) || refuse_unrecognized "$UNIT_FILE" "$unit_sha" "${ACCEPTED_PRIOR_UNIT_SHAS[@]}" "$FIXED_UNIT_SHA"
    need_unit=1
  else
    log "mqtt-client.service already at the fixed sha (2026-08-19 patch or later)."
  fi

  # ISSUE-065: a superseded js with an already-correct unit leaves nothing to install.
  if (( ! need_js && ! need_unit )); then
    log "Nothing to do -- neither file needs changing."
    exit 0
  fi

  local known=0 kv
  for kv in "${KNOWN_VERSIONS[@]}"; do [[ $v == "$kv" ]] && known=1; done
  (( known )) || log "NOTE: version $v not in ${KNOWN_VERSIONS[*]}, but its files match recognized checksums -- proceeding."

  local src_js="$SCRIPT_DIR/mqtt-client.js"
  local src_unit="$SCRIPT_DIR/mqtt-client.service"
  [[ -f $src_js ]]   || fail "missing $src_js -- patch directory is incomplete"
  [[ -f $src_unit ]] || fail "missing $src_unit -- patch directory is incomplete"
  [[ "$(file_sha "$src_js")" == "$FIXED_JS_SHA" ]]     || fail "bundled mqtt-client.js sha mismatch -- patch directory is corrupt."
  [[ "$(file_sha "$src_unit")" == "$FIXED_UNIT_SHA" ]] || fail "bundled mqtt-client.service sha mismatch -- patch directory is corrupt."

  # Verify BOTH candidates BEFORE installing either. A bad unit or an unparseable JS means
  # a service that will not start, on a device we may not be able to reach again.
  if ! node_check "$src_js"; then
    fail "bundled mqtt-client.js failed node --check -- refusing to install it."
  fi
  log "node --check: bundled mqtt-client.js is clean."

  if (( need_unit )) && ! unit_check "$src_unit"; then
    fail "systemd-analyze verify rejected the bundled unit -- refusing to install it."
  fi
  (( need_unit )) && log "systemd-analyze verify: bundled unit is clean."

  log "Backing up originals to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$BACKUP_DIR/mqtt-client.js" ]]      || cp -p "$MQTT_CLIENT_JS" "$BACKUP_DIR/mqtt-client.js"
  [[ -f "$BACKUP_DIR/mqtt-client.service" ]] || cp -p "$UNIT_FILE" "$BACKUP_DIR/mqtt-client.service"

  if (( need_js )); then
    log "Installing fixed mqtt-client.js"
    install -m 0755 "$src_js" "$MQTT_CLIENT_JS"
    if ! node_check "$MQTT_CLIENT_JS"; then
      log "Installed mqtt-client.js failed syntax check -- restoring backup."
      restore_backup
      fail "syntax check failed; originals restored."
    fi
  fi

  if (( need_unit )); then
    log "Installing fixed mqtt-client.service (BUG-039)"
    install -m 0644 "$src_unit" "$UNIT_FILE"
  fi

  # Restart + verify. This drops the ngrok SSH tunnel, so run it detached over SSH.
  run_detached_if_ssh __finalize_apply "$v"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inline) FORCE_INLINE=1; shift ;;
    --detach) FORCE_DETACH=1; shift ;;
    *) break ;;
  esac
done

case "${1:-apply}" in
  apply)                do_apply ;;
  --check|check)        do_check ;;
  --rollback)           do_rollback ;;
  __finalize_apply)     __finalize_apply "${2:?missing version}" ;;
  __finalize_rollback)  __finalize_rollback ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--inline|--detach] [apply|--check|--rollback]
  apply       (default) apply the patch
  --check     DRY RUN -- report what apply would do and change nothing. Needs no
              root. Exit 0 = already patched, 1 = would refuse, 2 = would apply.
              Use this to survey a fleet: the VERSION STRING does not determine
              the outcome, the file checksums do.
  --rollback  restore the pre-patch mqtt-client.js and mqtt-client.service from backup
  --inline    force the restart+verify to run inline (local console / testing)
  --detach    force the restart+verify to run detached

SELF-CONTAINED ROLLUP. There is no prerequisite patch: it replaced
2026-08-19-device-ready-flag-privatetmp, which has been deleted. Both files are
installed here, gated independently by sha256, so a device that already took
that patch is accepted and simply gets the newer JS.

Remote-session detection does NOT rely on \$SSH_CONNECTION alone -- sudo strips it --
it also walks the parent process chain for sshd.

An unrecognized file is never overwritten, and the refusal prints the observed
sha256 so an unsampled device reports its own state.

Restarting mqtt-client.service drops the ngrok SSH tunnel (ngrok runs inside it),
so over SSH the restart+verify runs detached and logs to:
  $LOG
EOF
    ;;
  *) fail "unknown argument: $1 (use --help)" ;;
esac
