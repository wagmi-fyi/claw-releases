#!/bin/bash
#
# commonclaw-backup.sh — the off-claw restic rail for a firm VM.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh and invoked there
# by systemd, never by an agent. Its consumer is the journal and the unit exit
# status, so it logs human-readable lines and exits non-zero on trouble.
#
#   commonclaw-backup.sh init              initialize the repository (human, once)
#   commonclaw-backup.sh backup            the scheduled run
#   commonclaw-backup.sh restore <dest>    restore to a scratch path
#   commonclaw-backup.sh snapshots         list snapshots
#
# CREDENTIALS. One credential rests on this claw: the manager's service-account
# token, as a systemd encrypted credential. Everything else resolves from the
# manager at invocation through an env-file of op:// REFERENCES. No secret value
# is ever written to disk here, and reference/backup-rail.md explains why the
# ordering around init matters.
#
# THREE INVARIANTS. Do not remove them. Each cost a real failure to learn.
#   1. Hot sqlite is captured through the online backup API, never file-by-file.
#      A file copy of a live database is torn.
#   2. This script NEVER auto-initializes. `init` is explicit and refuses an
#      existing repository. A read failure does not mean the repository is
#      absent, and initializing over one destroys what is still there.
#   3. Retention applies every run. The expensive reclaim runs once a day. The
#      reclaim is what crosses object-store usage caps.
#      Rate-limit the reclaim by time elapsed, recorded on this claw. Never by
#      wall-clock hour. An hour gate is true only when the timer fires inside
#      that hour, the two values live in different files, and nothing makes them
#      agree. This rail shipped hour 03 against a timer that fires at 00, 06, 12
#      and 18, so the reclaim never ran on any claw.
#
set -uo pipefail

CONF=/etc/commonclaw/provision.conf
ENV_FILE=/etc/commonclaw/backup.env

[ -r "$CONF" ] || { echo "FATAL: $CONF missing"; exit 2; }
# shellcheck disable=SC1090
. "$CONF"

# --- resolve credentials once, then re-exec under the manager ---------------
# op run puts the referenced values in this process's environment and masks
# them in child output. The re-exec keeps every restic call below inside it.
if [ -z "${COMMONCLAW_OP_RESOLVED:-}" ]; then
  : "${CREDENTIALS_DIRECTORY:?FATAL: no systemd credentials. Run under the unit, or wrap with systemd-run --property=LoadCredentialEncrypted=...}"
  [ -r "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing (op:// references, never values)"; exit 2; }
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "${CREDENTIALS_DIRECTORY}/op-service-account")"
  export OP_SERVICE_ACCOUNT_TOKEN
  export COMMONCLAW_OP_RESOLVED=1
  exec op run --env-file="$ENV_FILE" -- "$0" "$@"
fi

: "${RESTIC_PASSWORD:?FATAL: manager did not resolve RESTIC_PASSWORD}"
: "${AWS_ACCESS_KEY_ID:?FATAL: manager did not resolve AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?FATAL: manager did not resolve AWS_SECRET_ACCESS_KEY}"
export RESTIC_REPOSITORY="s3:${S3_ENDPOINT}/${B2_BUCKET}/${BOX_HOSTNAME}"

CONSISTENT=/var/backups/commonclaw/consistent
STATE=/var/lib/commonclaw
PRUNE_STAMP="${STATE}/last-prune"
# Below the tick spacing subtracted from a day. At 24 the stamp is written a
# minute after the tick, the same tick tomorrow measures just under 24 hours and
# skips, and the reclaim walks forward one tick per day. 20 holds it on one tick.
#
# A CONSTANT, and deliberately not read from the environment. A value that can be
# raised from outside is a quiet path to a reclaim that never fires, which is the
# defect this gate replaced. To force a reclaim early, delete the stamp: that is
# one visible act that leaves a trace in the next run's log. To make the interval
# a per-claw setting, put it in provision.conf where it is recorded and read back,
# never in an environment nobody records.
PRUNE_INTERVAL_HOURS=20

log() { logger -t commonclaw-backup -p "user.$1" -- "$2"; printf '[%s] %s\n' "$1" "$2"; }

# --- invariant 1 ------------------------------------------------------------
consistency_pass() {
  rm -rf "$CONSISTENT"
  install -d -m 0700 "$CONSISTENT"
  local db dest n=0 raw=0 failed=0
  while IFS= read -r -d '' db; do
    dest="${CONSISTENT}${db}"
    install -d -m 0700 "$(dirname "$dest")"
    if sqlite3 "$db" ".backup '$dest'" 2>/dev/null; then
      n=$((n+1))
    elif sqlite3 "file:${db}?immutable=1" ".backup '$dest'" 2>/dev/null; then
      n=$((n+1))
    elif cp -p "$db" "$dest" 2>/dev/null; then
      raw=$((raw+1))
      log warning "raw copy fallback for ${db} (un-checkpointed deltas may be missing)"
    else
      failed=$((failed+1))
      log err "could not capture ${db} by any method"
    fi
  done < <(find "$SRV_ROOT" /home -xdev \
             \( -name '*.db' -o -name '*.sqlite' \) -type f -print0 2>/dev/null)

  log info "consistency pass: ${n} clean, ${raw} raw, ${failed} failed"

  # Zero captured is not success. It means the search missed this claw and the
  # databases are unprotected, which reads identically to "no databases yet".
  if [ $((n + raw)) -eq 0 ]; then
    log warning "consistency pass captured NO databases -- confirm this claw genuinely has none"
  fi
  [ "$failed" -eq 0 ]
}

write_excludes() {
  cat > "$1" <<'EXEOF'
**/.venv
**/__pycache__
**/.cache
**/.local/share/claude/versions
**/node_modules
*-wal
*-shm
EXEOF
}

repo_exists() { restic cat config >/dev/null 2>&1; }

# --- invariant 3 ------------------------------------------------------------
# Seconds since the last reclaim that SUCCEEDED. -1 means no usable stamp.
# Absent, unreadable, not a number, and dated in the future all give -1, and -1
# reclaims. That direction is deliberate. A missing stamp costs one extra
# reclaim. A stamp trusted wrongly costs the usage cap this invariant protects.
prune_age() {
  local now="$1" last
  [ -r "$PRUNE_STAMP" ] || { echo -1; return; }
  last="$(cat "$PRUNE_STAMP" 2>/dev/null)"
  case "$last" in
    ''|*[!0-9]*) echo -1; return ;;
  esac
  [ "$last" -gt "$now" ] && { echo -1; return; }
  echo $(( now - last ))
}

reclaim() {
  local now age interval
  now="$(date +%s)"
  age="$(prune_age "$now")"
  interval=$(( PRUNE_INTERVAL_HOURS * 3600 ))

  # Both branches log. A gate that is silent when it skips cannot be seen to be
  # wrong, which is how the hour gate survived on five claws.
  if [ "$age" -ge 0 ] && [ "$age" -lt "$interval" ]; then
    log info "reclaim not due: ${age}s since the last one, interval ${PRUNE_INTERVAL_HOURS}h"
    return 0
  fi
  if [ "$age" -lt 0 ]; then
    log info "reclaim due: no usable stamp at ${PRUNE_STAMP}"
  else
    log info "reclaim due: ${age}s since the last one, interval ${PRUNE_INTERVAL_HOURS}h"
  fi

  if restic prune --retry-lock 5m; then
    if install -d -m 0700 "$STATE" && printf '%s\n' "$now" > "$PRUNE_STAMP"; then
      log info "reclaim complete"
    else
      log err "reclaim complete but the stamp at ${PRUNE_STAMP} did not write; the next run reclaims again"
    fi
  else
    # No stamp is written, so the next run finds the reclaim due and tries again.
    # The retry is chosen. A reclaim that keeps failing must keep asking, because
    # nothing else on this claw reports it.
    log err "reclaim FAILED; the stamp is unchanged, so the next run retries"
  fi
}

cmd_init() {
  if repo_exists; then
    log err "a repository already exists at this prefix. REFUSING to init."
    exit 1
  fi
  log info "initializing (the password must already be escrowed in the manager)"
  if restic init; then
    log info "repository initialized"
  else
    log err "restic init failed"
    exit 1
  fi
}

cmd_backup() {
  # invariant 2: never initialize here
  if ! repo_exists; then
    log err "repository not readable. NOT initializing. Run init by hand, or investigate the access error -- a crossed usage cap presents exactly like this."
    exit 1
  fi

  consistency_pass || log warning "consistency pass had failures; continuing so the rest is captured"

  local ex rc
  ex="$(mktemp)"
  write_excludes "$ex"
  restic backup --retry-lock 5m --exclude-file "$ex" --tag commonclaw \
         "$SRV_ROOT" /home /etc/commonclaw "$CONSISTENT"
  rc=$?
  rm -f "$ex"
  if [ "$rc" -ne 0 ]; then log err "restic backup exited ${rc}"; exit "$rc"; fi
  log info "backup complete"

  if restic forget --retry-lock 5m \
         --keep-daily 7 --keep-weekly 4 --keep-monthly 3; then
    log info "retention applied"
  else
    log warning "forget failed"
  fi

  # invariant 3: retention every run, above. The reclaim is rate-limited by the
  # stamp, and it says which branch it took.
  reclaim

  rm -rf "$CONSISTENT"
}

cmd_restore() {
  local dest="${1:-}"
  [ -n "$dest" ] || { echo "usage: $0 restore <scratch-dest>"; exit 2; }
  # never over live data
  case "$dest" in
    /|/srv/*|/home/*|/etc/*|/var/lib/*)
      log err "restore destination must be scratch, never live data"; exit 1 ;;
  esac
  install -d -m 0700 "$dest"
  if restic restore latest --retry-lock 5m --target "$dest"; then
    log info "restored the latest snapshot to ${dest}"
  else
    log err "restore failed"; exit 1
  fi
}

case "${1:-backup}" in
  init)      cmd_init ;;
  backup)    cmd_backup ;;
  restore)   shift; cmd_restore "${1:-}" ;;
  snapshots) restic snapshots ;;
  # Derived, never a line number. The header grew by five lines when the reclaim
  # gate was fixed and the hardcoded range then cut the help mid-sentence.
  -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ;;
  *) echo "usage: $0 {init|backup|restore <dest>|snapshots}"; exit 2 ;;
esac
