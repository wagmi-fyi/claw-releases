#!/bin/bash
#
# commonclaw-update.sh — take a validated release, or say why nOt.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh and invoked there
# by a systemd timer, never by an agent. Its consumers are the timer's exit
# status, the journal, and the two files it writes under /etc/commonclaw.
#
#   commonclaw-update.sh            the scheduled run
#   commonclaw-update.sh --now      ignore the quiet window, still honour the mode
#   commonclaw-update.sh --check    report what is on offer and change nothing
#
# WHAT THIS IS FOR. Updates move to a PULL rail. This claw reaches out for its own
# releases, so no machine holds a key to this one. `reference/release-rail.md` is
# the contract and this script implements it; read that first.
#
# THE HONEST LIMIT, stated here rather than discovered. THIS SCRIPT CANNOT UPDATE
# A BROKEN COPY OF ITSELF. A release that breaks it leaves a timer running broken
# code and nothing on the claw heals that. That is what the operator's SSH access
# is for. The one cheap guard is that a fetched copy must parse before it can
# become the live one, which catches a syntax break and says nothing about a
# logic break.
#
# TRANSPORT AND AUTH ARE PLUGGABLE ON PURPOSE. How a claw proves it may read the
# release repository is not settled, and the answer does not change anything else
# here. Both live behind `fetch_raw` and `FETCH_TOKEN_CMD` below. An empty token
# command means an unauthenticated fetch, which is what a public repository
# needs and costs this claw no resting credential at all.
#
set -euo pipefail

CONF=/etc/commonclaw/provision.conf
UPDATER_CONF=/etc/commonclaw/updater.conf
STATE=/etc/commonclaw/release.json
RUN_LOG_DIR=/var/log/commonclaw/updater
PLANE=/opt/commonclaw/provision-claw
# THE RULED STAGE PREFIX. The same on every claw and kept afterwards, because the
# claw records the absolute source its skills resolved from, and a prefix named
# after the run that made it leaves that record pointing at nothing.
# reference/claw-conventions.md states this; an earlier cut of this script
# applied straight out of its own temporary directory and put a path that no
# longer existed into /etc/commonclaw/skills.yaml, differently on every run.
FLEET_STAGE=/root/fleet-stage

MODE_NOW=0; CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --now)   MODE_NOW=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

STAGE=""; VERDICT="did not start"; OFFERED=""; CARRIED=""; STEP="startup"
log() { logger -t commonclaw-update -p "user.$1" -- "$2" 2>/dev/null || true; printf '[%s] %s\n' "$1" "$2" >&2; }

# EVERY RUN LEAVES A RECORD, including one that dies on a path nobody planned.
# The same lesson provisioning learned: a run that writes nothing is
# indistinguishable from a run that never happened, and a timer has no operator
# watching the progress stream.
RECORDED=0
record_run() {
  local rc=$?
  [ "$RECORDED" -eq 1 ] && return 0
  RECORDED=1
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf "$STAGE"
  mkdir -p "$RUN_LOG_DIR" 2>/dev/null || true
  local when stamp f
  when="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  f="${RUN_LOG_DIR}/${stamp}.json"
  {
    printf '{\n'
    printf '  "when": "%s",\n' "$when"
    printf '  "verdict": "%s",\n' "$VERDICT"
    printf '  "stopped_at": "%s",\n' "$STEP"
    printf '  "exit": %s,\n' "$rc"
    printf '  "carried": "%s",\n' "$CARRIED"
    printf '  "offered": "%s"\n' "$OFFERED"
    printf '}\n'
  } > "$f" 2>/dev/null || true
  log info "verdict=${VERDICT} at=${STEP} exit=${rc} carried=${CARRIED:-none} offered=${OFFERED:-none}"
}
trap record_run EXIT

die() { VERDICT="$1"; log err "$2"; exit 1; }

# ---------------------------------------------------------------- siblings
for s in version-compare.sh tree-digest.sh; do
  [ -r "${PLANE}/scripts/${s}" ] || die "plane incomplete" "missing ${PLANE}/scripts/${s}: the provisioning plane is incomplete, so this claw cannot verify a release"
done
# shellcheck source=version-compare.sh
. "${PLANE}/scripts/version-compare.sh"
# shellcheck source=tree-digest.sh
. "${PLANE}/scripts/tree-digest.sh"

# ---------------------------------------------------------------- config
STEP="config"
[ "$(id -u)" -eq 0 ] || die "not root" "run this as root: applying a release writes root-owned paths"
[ -r "$CONF" ]         || die "no claw config" "missing ${CONF}: this machine has not been provisioned"
[ -r "$UPDATER_CONF" ] || die "no updater config" "missing ${UPDATER_CONF}: provisioning seeds it, and its absence means somebody removed it"

# What the FIRM decides, so the conf may set it. Defaults exist so a conf missing
# an optional key does not abort under set -u.
MODE="auto"; CHANNEL="tenants"; RELEASE_REPO=""; FETCH_TOKEN_CMD=""
OUTSIDE_WINDOW=0
DEFER_DIR=/var/lib/commonclaw/updater
# shellcheck disable=SC1090
. "$UPDATER_CONF"

# WHAT THE FIRM DOES NOT DECIDE. Assigned AFTER the conf is sourced, so a value
# set there is overwritten rather than honoured. These are constants for the same
# reason the core floors are: a bound a claw can stretch is not a bound.
#
# The window is a RANGE and the wait is BOUNDED, and both halves exist to stop
# this becoming the wall-clock gate the backup rail carried. Making either one
# conf-settable would put the two values back in different files with nothing
# making them agree, which is the shape the fleet removed on 2026-08-13. A firm
# that wants a release sooner has the granted door, which is a person deciding.
WINDOW_START="04"; WINDOW_END="06"; MAX_DEFER_HOURS="26"

case "$MODE" in auto|manual) : ;; *) die "bad mode" "MODE in ${UPDATER_CONF} must be auto or manual, not '${MODE}'" ;; esac
[ -n "$RELEASE_REPO" ] || die "no repo" "RELEASE_REPO is unset in ${UPDATER_CONF}: there is nowhere to pull from"

# ---------------------------------------------------------------- what we carry
STEP="read carried version"
# NO STATE MEANS NOTHING HAS BEEN TAKEN YET, which compares below every release.
# It does NOT mean refuse: a claw provisioned before this rail existed carries no
# state file and must still be able to take its first release.
CARRIED="0.0.0"
if [ -r "$STATE" ]; then
  CARRIED="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE" | head -1)"
  [ -n "$CARRIED" ] || CARRIED="0.0.0"
fi

# ---------------------------------------------------------------- fetch
# ONE SEAM FOR TRANSPORT AND AUTH. Everything above and below is indifferent to
# which answer the credential question gets.
fetch_raw() {  # <remote path> <destination file>
  local what="$1" dest="$2" token=""
  if [ -n "$FETCH_TOKEN_CMD" ]; then
    # Resolved at invocation and never written to disk. The command is whatever
    # this claw's credential plane needs: a manager read, or nothing at all.
    token="$(eval "$FETCH_TOKEN_CMD" 2>/dev/null || true)"
    [ -n "$token" ] || return 3
    curl -fsSL --max-time 120 -H "Authorization: Bearer ${token}" -o "$dest" "$what"
  else
    curl -fsSL --max-time 120 -o "$dest" "$what"
  fi
}

STEP="fetch channel pointer"
STAGE="$(mktemp -d /tmp/commonclaw-update.XXXXXX)"

# THE POINTER FETCH DEFEATS THE CACHE, and it is not superstition.
#
# Measured 2026-08-13: the raw host serves a channel pointer with max-age 300 and
# answered a claw with a HIT carrying the PREVIOUS release five seconds after a
# new one was published. On an hourly timer five minutes of staleness is noise.
# It is not noise on the granted door's --now path, which is a person acting the
# moment they are told a release exists, and being told nothing is available is
# the one answer that reads as broken rather than slow.
#
# The tarball carries the same parameter for a different reason: a cached one
# that no longer matches the digest would be REFUSED, and a spurious refusal
# reads as tampering, which is the most alarming way for a cache to surface.
CB="$(date +%s)"
POINTER_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/channels/${CHANNEL}.json?cb=${CB}"
fetch_raw "$POINTER_URL" "${STAGE}/pointer.json" \
  || die "pointer unreachable" "could not read the ${CHANNEL} channel pointer; this claw is unchanged"

jqv() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${STAGE}/pointer.json" | head -1; }

# THE POINTER MUST SAY WHAT IT IS, and this is not ceremony.
#
# Without a positive marker, a fetch that returned an error page, a login
# redirect or a truncated file parses to empty fields, and "empty" would then be
# read as the channel declaring no release. Two different worlds would wear one
# verdict, and the wrong one is the reassuring one: a timer reporting a clean
# no-op while it is actually unable to read anything. That is the same shape as a
# sweep reporting clean because it measured nothing.
#
# So absence of the marker is UNREADABLE, and only a pointer that parses and
# explicitly declares no release is the quiet no-op.
[ "$(jqv pointer_schema)" = "commonclaw-channel-v1" ] \
  || die "pointer unreadable" "what came back for the ${CHANNEL} channel is not a channel pointer: no pointer_schema marker. This claw is unchanged, and a fetch that returns something else must never read as nothing to do"

OFFERED="$(jqv version)"; OFFERED_TAG="$(jqv tag)"; OFFERED_DIGEST="$(jqv tree_digest)"

# A CHANNEL WITH NO RELEASE IS A DEFINED STATE, not an error. It is what every
# channel reads as before the first publish, and a timer must not go red on it.
# Reached only through the marker above, so it means what it says.
if grep -q '"version"[[:space:]]*:[[:space:]]*null' "${STAGE}/pointer.json"; then
  VERDICT="no release on this channel"
  log info "the ${CHANNEL} channel names no release; nothing to do"
  exit 0
fi

# Parsed, marked, and still missing what it needs: that is a malformed pointer
# rather than an empty one.
for f in OFFERED OFFERED_TAG OFFERED_DIGEST; do
  [ -n "${!f}" ] || die "pointer incomplete" "the ${CHANNEL} pointer declares a release but carries no ${f}; this claw is unchanged"
done

# ---------------------------------------------------------------- decide
STEP="compare versions"
rc=0; version_at_least "$CARRIED" "$OFFERED" || rc=$?
case "$rc" in
  0) VERDICT="already at or above"
     log info "carrying ${CARRIED}, offered ${OFFERED}: nothing newer, no change"
     exit 0 ;;
  2) die "version refused" "cannot compare carried '${CARRIED}' with offered '${OFFERED}': applying nothing, because an update that cannot be proved forward could move this claw backwards" ;;
esac

# MANUAL STOPS HERE, AND SAYS WHAT IT DECLINED. The timer still runs, because a
# mode expressed as unit state is one a later release can flip back with nothing
# telling the firm. A pinning firm can read this without asking anybody.
if [ "$MODE" = "manual" ] && [ "$MODE_NOW" -eq 0 ]; then
  VERDICT="available, held by manual mode"
  log info "release ${OFFERED} is available and this claw is in manual mode; apply it through the granted door"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  VERDICT="available"
  log info "release ${OFFERED} is available (carrying ${CARRIED}); --check changes nothing"
  exit 0
fi

# ---------------------------------------------------------------- fetch payload
STEP="fetch payload"
fetch_raw "https://codeload.github.com/${RELEASE_REPO}/tar.gz/refs/tags/${OFFERED_TAG}?cb=${CB}" "${STAGE}/payload.tgz" \
  || die "payload unreachable" "could not fetch the payload at tag ${OFFERED_TAG}; this claw is unchanged"

mkdir -p "${STAGE}/x"
tar xzf "${STAGE}/payload.tgz" -C "${STAGE}/x" \
  || die "payload did not extract" "the payload at ${OFFERED_TAG} did not extract; this claw is unchanged"

# The archive carries one top directory whose name is generated, so it is
# resolved rather than assumed.
TOP="$(find "${STAGE}/x" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$TOP" ] && [ -d "${TOP}/release" ] \
  || die "payload has no release directory" "the payload at ${OFFERED_TAG} carries no release/ directory; this claw is unchanged"

STEP="verify digest"
GOT_DIGEST="$(tree_digest "${TOP}/release")"
if [ "$GOT_DIGEST" != "$OFFERED_DIGEST" ]; then
  die "digest mismatch, REFUSED" "the payload at ${OFFERED_TAG} does not match the digest the channel names. wanted ${OFFERED_DIGEST}, measured ${GOT_DIGEST}. NOTHING was applied and this claw is unchanged"
fi

STEP="verify the updater it carries"
# The one guard against shipping a broken updater. It catches a syntax break. It
# says nothing about a logic break, and the header says so.
if [ -r "${TOP}/release/provision-claw/scripts/commonclaw-update.sh" ]; then
  bash -n "${TOP}/release/provision-claw/scripts/commonclaw-update.sh" \
    || die "release carries an unparseable updater" "the updater inside ${OFFERED_TAG} does not parse; refusing to install a release that would leave this claw unable to update itself"
fi

# ---------------------------------------------------------------- identity
STEP="read this box's identity"
# IDENTITY BELONGS TO A BUILD, NEVER TO AN UPDATE. Every value below is read from
# this machine. Nothing is carried in from the release, so an update cannot move
# the hostname, the clock, or the backup destination. And NO KEYS FILE IS PASSED
# AT ALL, so an update cannot re-create somebody who was offboarded.
cv() { sed -n "s/^$1=//p" "$CONF" | head -1; }
PROJECT="$(cv PROJECT)"; BOX="$(cv BOX_HOSTNAME)"; BUCKET="$(cv B2_BUCKET)"; ENDPOINT="$(cv S3_ENDPOINT)"
TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)"
for v in PROJECT BOX BUCKET ENDPOINT; do
  [ -n "${!v}" ] || die "identity incomplete" "${CONF} carries no ${v}; refusing rather than inventing an identity value"
done

# ---------------------------------------------------------------- classify
STEP="classify disruption"
DECLARED="$(sed -n 's/.*"disruption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${TOP}/release/release.json" | head -1)"
[ -n "$DECLARED" ] || DECLARED="unknown"

# The claw's own reading, from the same comparison the core phases make. Both
# this and the declaration must say quiet.
would_move_core=0
RELEASE_META="${TOP}/release/release.json"
rf() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$RELEASE_META" | head -1; }
CODEX_WANT="$(rf codex_floor)"; CLAUDE_WANT="$(rf claude_floor)"
if [ -n "$CODEX_WANT" ]; then
  have="$(command -v codex >/dev/null 2>&1 && codex --version 2>/dev/null | awk '{print $2}' || true)"
  r=0; version_at_least "${have:-}" "$CODEX_WANT" || r=$?
  [ "$r" -eq 0 ] || would_move_core=1
fi
if [ -n "$CLAUDE_WANT" ]; then
  while IFS=: read -r person _; do
    have="$(sudo -u "$person" -H bash -lc 'command -v claude >/dev/null 2>&1 && claude --version' </dev/null 2>/dev/null | awk '{print $1}' || true)"
    r=0; version_at_least "${have:-}" "$CLAUDE_WANT" || r=$?
    [ "$r" -eq 0 ] || would_move_core=1
  done < <(getent group claw-members | awk -F: '{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]!="") print a[i]":"}')
fi

if { [ "$would_move_core" -eq 1 ] || [ "$DECLARED" != "quiet" ]; } && [ "$MODE_NOW" -eq 0 ]; then
  # THE WINDOW IS A RANGE WITH A BOUND ON WAITING, and both halves are there to
  # stop this becoming the defect the fleet killed on 2026-08-13.
  #
  # The first draft of this gate compared the current hour for EQUALITY against a
  # single configured hour. That is exactly PRUNE_HOUR: a wall-clock gate whose
  # value lives in one file and whose timer lives in another, with nothing making
  # them agree, so the guarded action never fires and nothing says so. The reclaim
  # in commonclaw-backup.sh missed every scheduled tick for the whole life of the
  # rail for precisely that reason.
  #
  # Two changes make it structural rather than lucky. A RANGE, so any tick inside
  # several hours qualifies instead of one exact hour. And a BOUND on how long a
  # release may sit deferred, so if the window is missed entirely, the release
  # still lands and says it landed outside the window. The bound is what makes
  # this gate's releasing branch reachable no matter what the timer does, which
  # is the property the hour gate never had.
  now_h="$(date +%H)"; now_e="$(date +%s)"
  in_window=0
  if [ "$WINDOW_END" -gt "$WINDOW_START" ]; then
    [ "$((10#$now_h))" -ge "$((10#$WINDOW_START))" ] && [ "$((10#$now_h))" -lt "$((10#$WINDOW_END))" ] && in_window=1
  else
    # a window that wraps midnight
    { [ "$((10#$now_h))" -ge "$((10#$WINDOW_START))" ] || [ "$((10#$now_h))" -lt "$((10#$WINDOW_END))" ]; } && in_window=1
  fi

  mkdir -p "$DEFER_DIR" 2>/dev/null || true
  DEFER_FILE="${DEFER_DIR}/deferred"
  waited=0
  if [ -r "$DEFER_FILE" ]; then
    read -r d_ver d_epoch < "$DEFER_FILE" || true
    # A different release resets the clock, because the wait belongs to the
    # release being held rather than to the claw.
    if [ "${d_ver:-}" = "$OFFERED" ] && [ -n "${d_epoch:-}" ]; then
      waited=$(( (now_e - d_epoch) / 3600 ))
    else
      printf '%s %s\n' "$OFFERED" "$now_e" > "$DEFER_FILE"
    fi
  else
    printf '%s %s\n' "$OFFERED" "$now_e" > "$DEFER_FILE"
  fi

  if [ "$in_window" -eq 0 ] && [ "$waited" -lt "$MAX_DEFER_HOURS" ]; then
    VERDICT="deferred to the quiet window"
    log info "release ${OFFERED} would move a core on this box (declared: ${DECLARED}); held for ${waited}h, window is ${WINDOW_START}:00 to ${WINDOW_END}:00 local, applying regardless after ${MAX_DEFER_HOURS}h"
    exit 0
  fi
  if [ "$in_window" -eq 0 ]; then
    OUTSIDE_WINDOW=1
    log warning "release ${OFFERED} has been held ${waited}h without the quiet window being reached; applying now rather than holding indefinitely"
  fi
fi

# ---------------------------------------------------------------- apply
STEP="apply"
log info "applying release ${OFFERED} from ${OFFERED_TAG} (carrying ${CARRIED})"

# THE VERIFIED PAYLOAD MOVES TO THE RULED PREFIX BEFORE IT IS APPLIED.
#
# Everything up to here happened in a temporary directory, which is what makes a
# failed fetch or a failed verification leave this claw byte-identical. The move
# happens only after the digest matched, which is the moment this run commits to
# applying, so that property is untouched.
#
# It has to be a STABLE prefix rather than the temporary one. A provisioning run
# records the absolute path its skills resolved from into the claw's own
# declaration, so applying out of a per-run directory writes a path that is
# already gone by the time anybody reads it, and writes a different one every
# run. Measured on staging: three applies of one identical release produced three
# different declarations and the recorded source did not exist.
#
# Keeping the previous stage is also what a failed apply converges back to. That
# is not a rollback, because the provisioning script is convergent rather than
# transactional and no wrapper makes it so.
rm -rf "${FLEET_STAGE}.previous"
# if/fi rather than an AND-list, for legibility rather than for safety. A claw
# taking its FIRST release has no stage to move aside, which is the ordinary
# path and not an error. An AND-list would also survive that, because bash
# exempts a failing test in that position from set -e; checked rather than
# assumed, because the reverse is a common belief and writing it down as a
# reason would have put a false sentence in this file.
if [ -d "$FLEET_STAGE" ]; then mv "$FLEET_STAGE" "${FLEET_STAGE}.previous"; fi
mv "${TOP}/release" "$FLEET_STAGE"
RELEASE_META="${FLEET_STAGE}/release.json"

NOTES="${FLEET_STAGE}/notes.md"
CLASS="$(rf class)"
REV="$(rf revision)"

set +e
"${FLEET_STAGE}/provision-claw/scripts/provision-claw.sh" \
  --project "$PROJECT" --hostname "$BOX" --timezone "$TZ_NOW" \
  --bucket "$BUCKET" --s3-endpoint "$ENDPOINT" \
  --skills-manifest "${FLEET_STAGE}/skills.yaml" \
  --release-notes "$NOTES" --release-class "$CLASS" --revision "$REV" \
  > "${STAGE}/run.json" 2> "${STAGE}/run.log"
apply_rc=$?
set -e

mkdir -p "$RUN_LOG_DIR"
cp "${STAGE}/run.json" "${RUN_LOG_DIR}/apply-$(date -u +%Y%m%dT%H%M%SZ).json" 2>/dev/null || true

if [ "$apply_rc" -ne 0 ]; then
  VERDICT="apply failed"
  log err "the provisioning run exited ${apply_rc} applying ${OFFERED}. The carried version is NOT advanced. The previous plane is at /root/plane-previous and re-applying it converges this claw back. Its result JSON is in ${RUN_LOG_DIR}"
  exit 1
fi

# ---------------------------------------------------------------- record
STEP="record"
cat > "$STATE" <<EOF
{
  "version": "${OFFERED}",
  "tag": "${OFFERED_TAG}",
  "tree_digest": "${GOT_DIGEST}",
  "channel": "${CHANNEL}",
  "applied_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "previous": "${CARRIED}"
}
EOF
chmod 0644 "$STATE"

# The wait belonged to a release that has now landed.
rm -f "${DEFER_DIR}/deferred" 2>/dev/null || true

VERDICT="applied"
if [ "$OUTSIDE_WINDOW" -eq 1 ]; then
  VERDICT="applied outside the quiet window"
  log warning "release ${OFFERED} applied OUTSIDE the quiet window after the deferral bound was reached"
else
  log info "release ${OFFERED} applied; this claw now carries it"
fi
