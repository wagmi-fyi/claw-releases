#!/bin/bash
#
# commonclaw-update.sh — take a validated release, or say why not.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh and invoked there
# by a systemd timer, never by an agent. Its consumers are the timer's exit
# status, the journal, and the two files it writes under /etc/commonclaw.
#
#   commonclaw-update.sh            the scheduled run
#   commonclaw-update.sh --now      apply now: ignores the quiet window, applies
#                                   even on a claw pinned to manual, and retries a
#                                   release this claw has stopped retrying. It is
#                                   the operator's override and it overrides all
#                                   three. The mode door prints this command to an
#                                   admin who has just pinned their claw.
#   commonclaw-update.sh --check    report what is on offer and change nothing.
#                                   It writes no run-log JSON and creates no log
#                                   directory: a read-only flag that leaves a
#                                   record is not read-only, and an operator
#                                   asking what is on offer must be able to ask
#                                   without moving the thing they are measuring.
#                                   The answer goes to the journal and to stderr.
#   commonclaw-update.sh --release TAG
#                                   ride the named tag, instead of whatever this
#                                   claw's channel points at. It is how a tier's
#                                   FIRST claw takes a release before the tier's
#                                   pointer moves, so a release that fails on
#                                   that tier fails on one box rather than being
#                                   published to every box on the tier. From the
#                                   tag onward it is the ordinary path. It is
#                                   refused unless a channel at or below this
#                                   claw's own already carries the tag, and
#                                   refused unless a person is standing at the
#                                   run.
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
# Written into a stage before an apply starts and removed when it passes, so the
# stage itself says whether it is a way back. A dotfile, because the stage is
# also a payload tree and this is not part of the payload.
APPLY_INCOMPLETE=.commonclaw-apply-incomplete

MODE_NOW=0; CHECK_ONLY=0; RIDE_TAG=""; RIDE_FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now)   MODE_NOW=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --release)
      [ $# -ge 2 ] || { printf -- '--release takes a tag, for example --release v1.4.4\n' >&2; exit 2; }
      RIDE_TAG="$2"; shift 2 ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# THE TAG IS CHECKED FOR SHAPE BEFORE IT REACHES A URL. It is composed into an
# API path and into the codeload path, and the shape the cutter makes is a v and
# a version. Anything else is refused here rather than sent.
if [ -n "$RIDE_TAG" ]; then
  ride_bad=0
  case "$RIDE_TAG" in v[0-9]*) : ;; *) ride_bad=1 ;; esac
  case "${RIDE_TAG#v}" in ''|*[!0-9.]*|*..*|.*|*.) ride_bad=1 ;; esac
  [ "$ride_bad" -eq 0 ] || {
    printf 'not a release tag: %s. A release tag is a v and a version, for example v1.4.4\n' "$RIDE_TAG" >&2
    exit 2; }
fi

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
  # A CHECK RUN LEAVES NO RECORD, and this is the one exit that takes that branch.
  #
  # `--check` says on three surfaces that it changes nothing: its own help, its own
  # message, and the reference. It exited through this trap like every other path,
  # so it wrote a run-log JSON and created the log directory on a claw that had
  # none. Two units then avoided the flag on live boxes for exactly that reason and
  # measured the pre-state some other way, which is a documented instrument moving
  # what it measures.
  #
  # NO SECOND LOG EITHER. A check log would put the same question back one level
  # down: an operator asking what is on offer would still be writing somewhere, and
  # a reader of the run log would have a second directory to reconcile it against.
  # The verdict still reaches the journal and stderr through log() below, which is
  # where an operator running this by hand is already looking.
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log info "verdict=${VERDICT} at=${STEP} exit=${rc} carried=${CARRIED:-none} offered=${OFFERED:-none} (--check: nothing written)"
    return 0
  fi
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
for s in version-compare.sh tree-digest.sh core-version.sh; do
  [ -r "${PLANE}/scripts/${s}" ] || die "plane incomplete" "missing ${PLANE}/scripts/${s}: the provisioning plane is incomplete, so this claw cannot verify a release"
done
# shellcheck source=version-compare.sh
. "${PLANE}/scripts/version-compare.sh"
# shellcheck source=tree-digest.sh
. "${PLANE}/scripts/tree-digest.sh"
# shellcheck source=core-version.sh
. "${PLANE}/scripts/core-version.sh"

# ---------------------------------------------------------------- config
STEP="config"
[ "$(id -u)" -eq 0 ] || die "not root" "run this as root: applying a release writes root-owned paths"

# A RIDE IS REFUSED UNLESS A PERSON IS STANDING AT THE RUN, and attendance is
# MEASURED rather than declared.
#
# This script had no way to tell a timer run from a hand run. `--now` is a flag
# the operator passes, and a unit file could pass it just as easily, so it says
# what was asked for and nothing at all about who asked. The reading is therefore
# taken off the run itself, on two arms, and either one refuses.
#
#   INVOCATION_ID  systemd puts it in the environment of every unit it starts, so
#                  its presence means this run belongs to a unit. That covers the
#                  timer, and it covers `systemctl start` by hand, which is the
#                  same case: the run is detached from whoever asked for it.
#   a terminal     a run with no terminal on stdin has nobody to report to and
#                  nobody to stop it part way.
#
# A person with root gets both by running this from their own shell, and a run
# whose output they redirect keeps its terminal on stdin.
#
# THE REFUSAL SITS ABOVE EVERY NETWORK ACT, because an unattended ride must fetch
# nothing at all.
if [ -n "$RIDE_TAG" ]; then
  [ -z "${INVOCATION_ID:-}" ] || die "ride not attended" "--release names ${RIDE_TAG} and systemd started this run, so nobody is standing at it. A ride is attended by definition: it exists so the first claw on a tier meets a bad release with a person present. This claw is unchanged and nothing was fetched"
  [ -t 0 ] || die "ride not attended" "--release names ${RIDE_TAG} and this run has no terminal on stdin, so nobody is standing at it. A ride is attended by definition. Run it from a shell. This claw is unchanged and nothing was fetched"
fi
[ -r "$CONF" ]         || die "no claw config" "missing ${CONF}: this machine has not been provisioned"
[ -r "$UPDATER_CONF" ] || die "no updater config" "missing ${UPDATER_CONF}: provisioning seeds it, and its absence means somebody removed it"

# What the FIRM decides, so the conf may set it. Defaults exist so a conf missing
# an optional key does not abort under set -u.
MODE="auto"; CHANNEL="tenants"; RELEASE_REPO=""; FETCH_TOKEN_CMD=""
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
# How many times one release may fail to apply before the claw stops retrying it
# on its own. A constant here for the same reason as the three above: a firm that
# could raise it could restore the unbounded loop this bound exists to end.
MAX_APPLY_FAILURES="3"

# THE CHANNEL LADDER, lowest tier first. `reference/release-rail.md` draws it, and
# a ride reads it to answer one question: which channels sit at or below this
# claw's own. It is assigned here for the same reason as the four values above.
# Settable from the conf, a firm could name itself the first tier and ride
# anything, which is the proof this flag exists to require.
CHANNEL_LADDER="staging wagmi tenants"

# THE BOUND'S STATE BELONGS DOWN HERE TOO, and this was the hole in the argument
# above. The three constants were protected by being assigned after the conf, and
# these two were assigned before it, so the conf could set them. That protected
# the bound's VALUE while leaving the directory its accrual lives in settable: a
# DEFER_DIR pointed at a tmpfs loses the stamp on every reboot, the wait restarts
# from zero each time, and the releasing branch stops being reachable. A bound
# whose state a firm can reset is not a bound, which is the same sentence the
# comment above makes about the numbers. OUTSIDE_WINDOW is the recorded verdict
# and moves for the same reason: settable from the conf, it reports a release as
# having landed outside the window when it did not.
OUTSIDE_WINDOW=0
DEFER_DIR=/var/lib/commonclaw/updater

case "$MODE" in auto|manual) : ;; *) die "bad mode" "MODE in ${UPDATER_CONF} must be auto or manual, not '${MODE}'" ;; esac
[ -n "$RELEASE_REPO" ] || die "no repo" "RELEASE_REPO is unset in ${UPDATER_CONF}: there is nowhere to pull from"

# ---------------------------------------------------------------- what we carry
STEP="read carried version"
# NO STATE MEANS NOTHING HAS BEEN TAKEN YET, which compares below every release.
# It does NOT mean refuse: a claw provisioned before this rail existed carries no
# state file and must still be able to take its first release.
sv() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STATE" 2>/dev/null | head -1; }

CARRIED="0.0.0"
CARRIED_TAG=""; CARRIED_DIGEST=""; CARRIED_APPLIED=""; CARRIED_PREV=""; CARRIED_FROM=""
LAST_VERDICT=""; FAILING_VERSION=""; FAILURE_COUNT=0
if [ -r "$STATE" ]; then
  CARRIED="$(sv version)"
  [ -n "$CARRIED" ] || CARRIED="0.0.0"
  # Carried forward verbatim, because a failed apply rewrites this file to record
  # the failure and must not lose what the claw actually holds.
  CARRIED_TAG="$(sv tag)"; CARRIED_DIGEST="$(sv tree_digest)"
  CARRIED_APPLIED="$(sv applied_at)"; CARRIED_PREV="$(sv previous)"
  # HOW THIS CLAW GOT WHAT IT CARRIES, carried forward like the four above.
  # A claw provisioned before this ships has no such field, and empty is the
  # honest reading of it: not recorded. That is the last_verdict lesson again,
  # which the reference named for weeks before anything wrote it.
  CARRIED_FROM="$(sv applied_from)"
  LAST_VERDICT="$(sv last_verdict)"; FAILING_VERSION="$(sv failing_version)"
  # An unreadable count is treated as none. It costs one extra attempt, which is
  # the safe direction: a count trusted wrongly stops a claw that could still
  # have repaired itself.
  FAILURE_COUNT="$(sed -n 's/.*"consecutive_failures"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$STATE" 2>/dev/null | head -1)"
  case "$FAILURE_COUNT" in ''|*[!0-9]*) FAILURE_COUNT=0 ;; esac
fi

# THE STATE FILE IS WRITTEN ON BOTH PATHS, and it is one writer so the two cannot
# describe different worlds.
#
# `release-rail.md` has always said this file carries the last run's verdict and
# the consecutive-failure count, and nothing wrote either. Without them a failed
# apply left the carried version where it was and the next tick repeated the
# whole pass -- fetch, extract, digest, stage swap, a full provisioning run --
# every hour, forever, on a box with nobody watching.
#
# THE RECORD SAYS HOW THE RELEASE GOT HERE, and that is one field because the
# next tick has to be explainable from it. A claw that rode a tag sits AHEAD of
# its own channel pointer, so the tick after the ride reads "already at or above"
# and skips, and nothing in the record would tell a reader that apart from a
# pointer that never moved.
#
# write_state <version> <tag> <digest> <applied_at> <previous> <verdict> <failing> <count> <applied_from>
write_state() {
  cat > "$STATE" <<STATEEOF
{
  "version": "${1}",
  "tag": "${2}",
  "tree_digest": "${3}",
  "channel": "${CHANNEL}",
  "applied_at": "${4}",
  "applied_from": "${9}",
  "previous": "${5}",
  "last_verdict": "${6}",
  "failing_version": "${7}",
  "consecutive_failures": ${8}
}
STATEEOF
  chmod 0644 "$STATE"
}

# EVERY DETERMINISTIC REFUSAL PAST THE FETCH COUNTS TOWARD THE BOUND, because the
# cost it repeats is the fetch. The apply counter alone left every post-download refusal outside
# the bound: the tarball came back every hour, forever, and the claw never
# reached the point that stops it. What is being counted is not "the apply
# failed" but "this offered release could not be taken", and that is the same
# question the bound answers, and every one of these will answer it the same way
# on the next tick: a payload that does not extract, carries no release directory,
# ships an unparseable updater, or meets a claw whose identity file is incomplete
# is in exactly that state again an hour later.
#
# THE FETCH FAILING IS DELIBERATELY NOT COUNTED. It is the one refusal here that
# is not a property of the payload or the box, so a transient network fault would
# burn attempts against a release that is fine and stop a claw from ever taking
# it. It also downloads nothing, so it is not the repeated cost this bound exists
# to end.
count_refusal() {   # count_refusal <verdict>
  if [ "$FAILING_VERSION" = "$OFFERED" ]; then
    FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
  else
    FAILURE_COUNT=1
  fi
  write_state "$CARRIED" "$CARRIED_TAG" "$CARRIED_DIGEST" "$CARRIED_APPLIED" "$CARRIED_PREV" \
              "$1" "$OFFERED" "$FAILURE_COUNT" "$CARRIED_FROM"
}

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
    curl -fsSL --max-time 120 -H "Accept: application/vnd.github.raw" -H "Authorization: Bearer ${token}" -o "$dest" "$what"
  else
    curl -fsSL --max-time 120 -H "Accept: application/vnd.github.raw" -o "$dest" "$what"
  fi
}

STEP="fetch channel pointer"
STAGE="$(mktemp -d /tmp/commonclaw-update.XXXXXX)"

# ONE READER FOR EVERY POINTER FILE. A ride reads more than one of them, so the
# file is an argument; jqv keeps the name the rest of this script calls it by.
ptr() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
jqv() { ptr "${STAGE}/pointer.json" "$1"; }

# THE POINTER COMES FROM THE API, NOT FROM THE RAW HOST.
#
# Measured 2026-08-13, twice, and the second measurement corrected the first. The
# raw host serves a channel pointer with max-age 300 and answered a claw with the
# PREVIOUS release seconds after a new one was published. A query-string cache
# buster does NOT fix it: the same host answered x-cache HIT with a unique
# parameter and served a copy 249 seconds old. That was tried, shipped, and found
# not to work, which is why the reasoning is written here rather than the fix
# being quietly swapped.
#
# The API contents endpoint is authoritative, carries a 60 second edge cache
# instead of 300, and serves the current file. Its unauthenticated rate limit is
# 60 an hour per address, and an hourly timer spends one or two, so nothing here
# needs a credential to stay inside it. The one run that spends more is a crossing,
# which reads the tag list once and two files per skipped release: a claw crossing
# five costs eleven, once, on the tick the crossing lands. Nothing on an ordinary
# tick changes.
#
# The tarball still comes from codeload, where a tag is effectively immutable and
# any staleness is caught by the digest comparison rather than acted on.

# HOW THIS RUN RESOLVED ITS RELEASE, recorded on the way through so the state
# file can carry it.
APPLIED_FROM="channel pointer"

if [ -n "$RIDE_TAG" ]; then
  STEP="resolve the ride's tag"
  APPLIED_FROM="tag ride"

  # THE ONE SEAM THIS FLAG ADDS, AND IT IS THE ONLY ONE.
  #
  # A pointer ride learns three things out of one file: the version, the tag, and
  # the digest that tag's payload must have. A tag ride learns the same three out
  # of the same kind of file, read off a channel at or below this claw's own that
  # already names the tag. Everything past this block is the pointer ride's own
  # code, unchanged and not branched on: the version comparison, the mode gate,
  # the failure bound, the payload fetch, the digest comparison, the stage, the
  # apply and the record.
  #
  # THE PROOF AND THE PROMISE ARE ONE READ, and that is why the promise comes
  # from a pointer rather than from the tag. The payload at a tag carries no
  # digest of itself. The baseline the cutter measures stays in the cutter's
  # working material and is never committed, so the only published promise about
  # a tag's bytes is a channel pointer that names it. That is also the source
  # `publish.sh --promote` re-derives against, so a ride and a promotion check
  # the same number against the same bytes.
  #
  # AT OR BELOW, RATHER THAN STRICTLY BELOW. A tier takes a release the tier
  # under it has proven, which is the rule `--promote` enforces. The first tier
  # has no tier under it, so its own pointer is what it reads, and that is what
  # lets a staging claw ride at all. Below the first tier the two readings agree:
  # a tag reaches a channel through a cut or a promotion, and a promotion already
  # required a lower channel to carry it.
  case " $CHANNEL_LADDER " in
    *" $CHANNEL "*) : ;;
    *) die "channel not on the ladder" "this claw's channel '${CHANNEL}' is not one of the tiers this release knows (${CHANNEL_LADDER}), so a ride cannot say which channels sit below it. Refusing rather than reading an unknown channel as the first tier. This claw is unchanged and nothing was fetched" ;;
  esac

  for c in $CHANNEL_LADDER; do
    fetch_raw "https://api.github.com/repos/${RELEASE_REPO}/contents/channels/${c}.json" "${STAGE}/pointer-${c}.json" \
      || die "pointer unreachable" "could not read the ${c} channel pointer, which a ride of ${RIDE_TAG} has to read to find the tier that carries it; this claw is unchanged"
    [ "$(ptr "${STAGE}/pointer-${c}.json" pointer_schema)" = "commonclaw-channel-v1" ] \
      || die "pointer unreadable" "what came back for the ${c} channel is not a channel pointer: no pointer_schema marker. This claw is unchanged, and a fetch that returns something else must never read as a tier not carrying the tag"
    if [ "$(ptr "${STAGE}/pointer-${c}.json" tag)" = "$RIDE_TAG" ]; then
      RIDE_FROM="$c"
      cp "${STAGE}/pointer-${c}.json" "${STAGE}/pointer.json"
      break
    fi
    # The ladder is read upward and stops at this claw's own tier. A channel
    # above this one carrying the tag proves nothing about the tier below.
    if [ "$c" = "$CHANNEL" ]; then break; fi
  done

  [ -n "$RIDE_FROM" ] || die "no tier carries the tag" "NO CHANNEL AT OR BELOW ${CHANNEL} CARRIES ${RIDE_TAG}. A tier takes a release the tier below it has proven, so a ride needs a channel to ride FROM. Either no tier below this one has taken ${RIDE_TAG}, or there is no such tag; the pointers are what was read and they name neither. This claw is unchanged and no payload was fetched"

  OFFERED="$(jqv version)"; OFFERED_TAG="$(jqv tag)"; OFFERED_DIGEST="$(jqv tree_digest)"
  # ONE TRUE SENTENCE ON EVERY TIER. The ladder is read at or below this claw's
  # own channel, so the tier that carries the tag can be this claw's own: that is
  # every ride by a first-tier claw, and any ride of a tag this claw's channel
  # already names. One line saying it read a lower pointer and did not read its
  # own then names the same channel twice, once as each. Measured on staging
  # 2026-09-04, w166's finding 3.
  if [ "$RIDE_FROM" = "$CHANNEL" ]; then
    log info "riding ${RIDE_TAG} from this claw's own ${CHANNEL} pointer, which carries the tag and version ${OFFERED}; no channel below ${CHANNEL} was needed"
  else
    log info "riding ${RIDE_TAG} from the ${RIDE_FROM} channel's pointer, which carries version ${OFFERED}; this claw's own ${CHANNEL} pointer is not read"
  fi
else
  POINTER_URL="https://api.github.com/repos/${RELEASE_REPO}/contents/channels/${CHANNEL}.json"
  fetch_raw "$POINTER_URL" "${STAGE}/pointer.json" \
    || die "pointer unreachable" "could not read the ${CHANNEL} channel pointer; this claw is unchanged"

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
fi

# Parsed, marked, and still missing what it needs: that is a malformed pointer
# rather than an empty one. It names the pointer that was read, which on a ride
# is the tier this claw rode from and not this claw's own channel.
SOURCE_POINTER="${RIDE_FROM:-$CHANNEL}"
for f in OFFERED OFFERED_TAG OFFERED_DIGEST; do
  [ -n "${!f}" ] || die "pointer incomplete" "the ${SOURCE_POINTER} pointer declares a release but carries no ${f}; this claw is unchanged"
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

# THE SAME RELEASE IS TRIED A BOUNDED NUMBER OF TIMES, THEN IT STOPS.
#
# `release-rail.md` states this bound and nothing implemented it. A failed apply
# does not advance the carried version, so without a bound the next tick finds
# the same release still newer and repeats the entire pass: a repository tarball,
# an extract, a digest, a stage swap and a full provisioning run. Hourly. Forever.
# The run that causes it is one that can converge the whole box and still exit
# non-zero, because `bad()` in the provisioning script records a failure and
# returns 0, so a single late check decides the verdict for a pass that worked.
#
# A NEWER RELEASE IS ALWAYS ACCEPTED, because a newer release is the repair path.
# The count is keyed to the version that failed and any other version clears it.
#
# `--now` walks past this, deliberately. The escape from a stuck rail is a person
# deciding, which is the granted door, and that is the same escape the quiet
# window has.
STUCK_HERE=0
if [ "$FAILING_VERSION" = "$OFFERED" ] && [ "$FAILURE_COUNT" -ge "$MAX_APPLY_FAILURES" ] && [ "$MODE_NOW" -eq 0 ]; then
  STUCK_HERE=1
fi

# --check REPORTS AND WRITES NOTHING, AND IT IS ANSWERED BEFORE THE BOUND ACTS.
#
# The bound used to sit above this exit and rewrite the state file on its way to
# refusing, so `--check` on a stuck claw rewrote state and exited 1 while its own
# help says it changes nothing and its own message says the same. A read-only flag
# that writes is worse than the thing it was reporting on.
if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$STUCK_HERE" -eq 1 ]; then
    VERDICT="stuck"
    log info "release ${OFFERED} is available and this claw has stopped retrying it after ${FAILURE_COUNT} failed attempts (carrying ${CARRIED}); --check changes nothing"
  else
    VERDICT="available"
    if [ -n "$RIDE_TAG" ]; then
      log info "release ${OFFERED} is available as a ride of ${RIDE_TAG} from the ${RIDE_FROM} channel (carrying ${CARRIED}); --check changes nothing"
    else
      log info "release ${OFFERED} is available (carrying ${CARRIED}); --check changes nothing"
    fi
  fi
  exit 0
fi

if [ "$STUCK_HERE" -eq 1 ]; then
  VERDICT="stuck"
  write_state "$CARRIED" "$CARRIED_TAG" "$CARRIED_DIGEST" "$CARRIED_APPLIED" "$CARRIED_PREV" \
              "stuck" "$OFFERED" "$FAILURE_COUNT" "$CARRIED_FROM"
  die "stuck" "release ${OFFERED} has failed to apply ${FAILURE_COUNT} times and will not be retried on its own. This claw still carries ${CARRIED} and is unchanged. A NEWER release will be taken normally. To retry this one, an operator runs this script with --now"
fi

# THE PEOPLE SET IS REQUIRED BEFORE THE TARBALL, NOT AFTER IT.
#
# This refusal used to sit down in the classifier, past the fetch, the extract and
# the digest. A claw with no people set therefore downloaded and verified the
# whole payload every hour before refusing on a fact that was true before the
# first byte moved, and the refusal never touched the failure count, so it never
# reached the bound either. Nothing here needs the payload.
MEMBER_LIST="$(getent group claw-members 2>/dev/null | awk -F: '{print $4}')"
MEMBER_COUNT="$(printf '%s' "$MEMBER_LIST" | awk -F, '{n=0; for(i=1;i<=NF;i++) if($i!="") n++; print n}')"
[ -n "${MEMBER_COUNT:-}" ] || MEMBER_COUNT=0
if [ "$MEMBER_COUNT" -eq 0 ]; then
  die "no people set" "the claw-members group is missing or empty, so this claw cannot say whether a release would move anybody's core. Refusing rather than reporting quiet from a measurement that read nobody. This claw is unchanged and nothing was fetched"
fi

# ---------------------------------------------------------------- fetch payload
STEP="fetch payload"
fetch_raw "https://codeload.github.com/${RELEASE_REPO}/tar.gz/refs/tags/${OFFERED_TAG}" "${STAGE}/payload.tgz" \
  || die "payload unreachable" "could not fetch the payload at tag ${OFFERED_TAG}; this claw is unchanged"

mkdir -p "${STAGE}/x"
tar xzf "${STAGE}/payload.tgz" -C "${STAGE}/x" \
  || { count_refusal "payload did not extract"; die "payload did not extract" "the payload at ${OFFERED_TAG} did not extract; this claw is unchanged. Attempt ${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} for this release"; }

# The archive carries one top directory whose name is generated, so it is
# resolved rather than assumed.
TOP="$(find "${STAGE}/x" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$TOP" ] && [ -d "${TOP}/release" ] \
  || { count_refusal "payload has no release directory"; die "payload has no release directory" "the payload at ${OFFERED_TAG} carries no release/ directory; this claw is unchanged. Attempt ${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} for this release"; }


STEP="verify digest"
GOT_DIGEST="$(tree_digest "${TOP}/release")"
if [ "$GOT_DIGEST" != "$OFFERED_DIGEST" ]; then
  count_refusal "digest mismatch"
  die "digest mismatch, REFUSED" "the payload at ${OFFERED_TAG} does not match the digest the channel names. wanted ${OFFERED_DIGEST}, measured ${GOT_DIGEST}. NOTHING was applied and this claw is unchanged. Attempt ${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} for this release"
fi

STEP="verify the updater it carries"
# The one guard against shipping a broken updater. It catches a syntax break. It
# says nothing about a logic break, and the header says so.
if [ -r "${TOP}/release/provision-claw/scripts/commonclaw-update.sh" ]; then
  bash -n "${TOP}/release/provision-claw/scripts/commonclaw-update.sh" \
    || { count_refusal "unparseable updater"; die "release carries an unparseable updater" "the updater inside ${OFFERED_TAG} does not parse; refusing to install a release that would leave this claw unable to update itself. Attempt ${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} for this release"; }
fi

# ---------------------------------------------------------------- identity
STEP="read this box's identity"
# IDENTITY BELONGS TO A BUILD, NEVER TO AN UPDATE. Every value below is read from
# this machine. Nothing is carried in from the release, so an update cannot move
# the hostname, the clock, or the backup destination. And NO KEYS FILE IS PASSED
# AT ALL, so an update cannot re-create somebody who was offboarded.
cv() { sed -n "s/^$1=//p" "$CONF" | head -1; }
PROJECT="$(cv PROJECT)"; BOX="$(cv BOX_HOSTNAME)"; BUCKET="$(cv B2_BUCKET)"; ENDPOINT="$(cv S3_ENDPOINT)"

# THE CLOCK IS AN IDENTITY FIELD AND IT REFUSES LIKE THE REST OF THEM.
#
# This read used to end in `|| echo Etc/UTC`, which INVENTED a timezone whenever
# the machine failed to report one, while the four fields above it died rather
# than invent. The comment at the top of this block says an update cannot move
# the clock, and the clock was the one thing it could move: a box set to
# anything else took Etc/UTC from a failed read and handed it to the provisioning
# run as an argument. Three schedules follow local time -- the seat-check hour,
# the backup timer, and the prune gate -- so they all move together and none of
# them names the timezone anywhere.
#
# The claw records its own timezone, so that is the first source. The machine
# answers for a claw whose config predates the field. Neither answering is a
# refusal, because a value nobody chose is worse than a run that did not happen.
TZ_NOW="$(cv TIMEZONE)"
[ -n "$TZ_NOW" ] || TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

for v in PROJECT BOX BUCKET ENDPOINT; do
  [ -n "${!v}" ] || { count_refusal "identity incomplete"; die "identity incomplete" "${CONF} carries no ${v}; refusing rather than inventing an identity value. Attempt ${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} for this release"; }
done
[ -n "$TZ_NOW" ] || { count_refusal "identity incomplete"; die "identity incomplete" "neither ${CONF} nor this machine reports a timezone; refusing rather than inventing one, because a clock nobody chose moves the seat-check hour, the backup timer and the prune gate together. Attempt ${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} for this release"; }

# ---------------------------------------------------------------- classify
STEP="classify disruption"
DECLARED="$(sed -n 's/.*"disruption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${TOP}/release/release.json" | head -1)"
[ -n "$DECLARED" ] || DECLARED="unknown"

# The claw's own reading, from the same comparison the core phases make. Both
# this and the declaration must say quiet.
would_move_core=0
RELEASE_META="${TOP}/release/release.json"
rf() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$RELEASE_META" | head -1; }
# THE FLOORS COME FROM THE THING THAT WILL ACTUALLY INSTALL THEM.
#
# This read them from release.json, which no provisioning run ever opens. The
# floors phase 9 and phase 10 enforce are constants inside provision-claw.sh, so
# release.json's copy is a declaration ABOUT the payload rather than the payload's
# own answer, and nothing makes the two agree. Two ways that bit. A release whose
# metadata omits a floor left the want empty and skipped the entire block, so the
# claw classified quiet while the payload went on to replace cores. A release
# declaring a floor lower than the one its own script ships classified quiet for
# the same reason, and then installed the higher one at whatever hour the tick
# landed.
#
# So the floors are read out of the payload's own script. It is sitting in the
# temporary directory at this point, unpacked and digest-verified, and it is the
# exact file that will run.
PAYLOAD_PROV="${TOP}/release/provision-claw/scripts/provision-claw.sh"
pf() { sed -n "s/^$1=\"\([^\"]*\)\".*/\1/p" "$PAYLOAD_PROV" 2>/dev/null | head -1; }
CODEX_WANT="$(pf CODEX_FLOOR)"; CLAUDE_WANT="$(pf CLAUDE_FLOOR)"

# A PAYLOAD THIS CLAW CANNOT READ THE FLOORS OUT OF IS TREATED AS CORE-MOVING.
# Refusing outright would let a rename of that file stop every release; assuming
# quiet would put the case back that this row exists to close. Waiting for the
# window costs at most the deferral bound, which still releases it.
FLOORS_UNREADABLE=0
# EITHER floor missing is unreadable, not both. Requiring both empty meant a
# payload declaring one floor and not the other classified from the half it could
# read and said nothing about the core it could not, which is the same
# measured-nothing shape one level down.
if [ ! -r "$PAYLOAD_PROV" ] || [ -z "$CODEX_WANT" ] || [ -z "$CLAUDE_WANT" ]; then
  FLOORS_UNREADABLE=1
  log warning "could not read the core floors out of ${PAYLOAD_PROV}; treating this release as core-moving so it waits for the quiet window rather than classifying quiet from a value nobody read"
fi

[ "$FLOORS_UNREADABLE" -eq 0 ] || would_move_core=1

if [ -n "$CODEX_WANT" ]; then
  have="$(command -v codex >/dev/null 2>&1 && codex --version 2>/dev/null | awk '{print $2}' || true)"
  r=0; version_at_least "${have:-}" "$CODEX_WANT" || r=$?
  [ "$r" -eq 0 ] || would_move_core=1
fi

# THE SECOND ARM THAT REPLACES CORES, AND IT IS ASKED UNCONDITIONALLY.
#
# The provisioning run installs the per-task core on two arms, not one. The
# version floor is the arm above. The other is the companion set: the skip
# requires the version to be at or above the floor AND the companion host to be
# present, so a box missing that binary is reinstalled even when its version is
# fine, replacing /opt/codex for every member at once.
#
# This sat inside the floor block, which meant a release that declared no codex
# floor skipped the question entirely and still replaced the core. The arm does
# not depend on any floor being declared, so neither does the question.
if [ ! -x /opt/codex/codex-code-mode-host ]; then
  would_move_core=1
  log info "the per-task core's companion host is absent, so applying this release replaces the core binaries regardless of version; treating it as core-moving"
fi
if [ -n "$CLAUDE_WANT" ]; then
  # READ THE INSTALL, DO NOT RUN IT. This asked each person's core directly, as
  # them and with -H, so deciding whether a release needs the quiet window opened
  # a login shell in every member's home -- to answer a question about a release
  # they may not even be behind. The reader is sourced from core-version.sh,
  # which is the same one the provisioning run uses, so the two cannot drift on
  # how much of somebody's home a routine check opens.
  while IFS=: read -r person _; do
    have="$(claude_version_for "$person")"
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
    # THE STAMP IS ARITHMETIC INPUT, SO IT IS VALIDATED BEFORE IT IS ARITHMETIC.
    #
    # Two different bad values, and only one of them is loud. A stamp that is not
    # a number aborts the whole run under this script's `set -u`, because bash
    # reads the name as a variable; that is a stopped rail rather than a wrong
    # verdict. The quiet one is a stamp that is still DIGITS but truncated, which
    # a digits-only check accepts: a torn `1786624214` left as `17552` reads as
    # 1970, `waited` becomes about half a million hours, the bound is passed on
    # the first tick and the release applies at once, outside the quiet window,
    # reporting that it waited.
    #
    # Digits alone cannot tell those apart, so the check is against something the
    # content cannot corrupt: the file's own modification time. The stamp is
    # written once and never edited, so its epoch and its mtime describe the same
    # instant. A value that disagrees with the mtime is not what was written.
    # Anything rejected here is treated as no usable stamp and rewritten, which
    # costs one deferral cycle and is the safe direction.
    # THE MTIME CHECK ALONE STILL TRUSTS THE CLOCK THAT WROTE BOTH.
    #
    # Content and mtime are written in the same instant, so a box whose clock was
    # days ahead when the stamp was made produces a future epoch and a matching
    # future mtime: the skew is zero and the pair agrees with itself while both
    # are wrong. The wait then goes NEGATIVE, negative is below the bound, and the
    # release defers on every tick forever, which is the unreachable releasing
    # branch this rail already killed once. So a stamp from the future is refused
    # on its own terms as well.
    d_mtime="$(stat -c %Y "$DEFER_FILE" 2>/dev/null || echo 0)"
    d_ok=0
    case "${d_epoch:-}" in
      ''|*[!0-9]*) : ;;
      *) d_skew=$(( d_epoch > d_mtime ? d_epoch - d_mtime : d_mtime - d_epoch ))
         if [ "$d_skew" -le 300 ] && [ "$d_epoch" -le "$now_e" ]; then d_ok=1; fi ;;
    esac
    if [ "${d_ver:-}" = "$OFFERED" ] && [ "$d_ok" -eq 1 ]; then
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
log info "applying release ${OFFERED} from ${OFFERED_TAG} by ${APPLIED_FROM} (carrying ${CARRIED})"

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
# ONLY A STAGE THAT APPLIED MAY BECOME THE ONE WE CONVERGE BACK TO.
#
# This rotated unconditionally, and that destroyed the thing it exists to keep.
# The first failed tick correctly moved the good stage aside. The second one
# deleted it and put the FAILED release there instead, so an hour after a bad
# release landed, the artifact this rail names as the way back was the bad
# release itself. Under an hourly retry nobody had read the journal yet.
#
# The verdict recorded by the previous run is what decides. A claw with no
# previous stage rotates normally, which is the ordinary first-release path.
# ONLY A VERDICT THAT SAYS THE STAGE FAILED MAY KEEP THE OLD ONE.
#
# The first cut of this gate asked whether the last verdict was `applied`, and
# that is the wrong question on every claw alive today: none of them carries a
# `last_verdict` field yet, because this script is what introduces it.
#
# THE VERDICT STRING IS RETIRED AS THE TEST, and this is the third defect that
# gate has carried. It rotated unconditionally and destroyed the way back. Then
# it read `applied`, which no existing claw records. Then a refusal on a path
# that never reaches an apply -- a digest mismatch -- began writing its own word
# into the same field, so a tag recut after a failed apply read as "not a
# failure" and promoted the FAILED stage. One global string, written by several
# writers, asked to describe one particular directory.
#
# So the stage carries its own answer. A marker file is written INTO the stage
# before the apply starts and removed when the apply succeeds, so its presence
# means "an apply into this stage began and did not finish". It travels with the
# directory, no other path can write it, and it needs nothing from the state file.
#
# WRITTEN BEFORE AND CLEARED AFTER, rather than written on success. Measured on
# the fleet this morning: every claw carries a stage AND a `.previous`, and none
# carries a verdict field, so a marker written only on success would be absent on
# all of them and the first release after this ships would take the keep branch
# and delete the stage holding the release the box is running. That is the same
# defect again. Absent therefore has to mean rotate. Writing the marker first
# also survives the case a success-marker was meant to catch: a run killed part
# way leaves the marker in place, which is the honest answer.
# THE MARKER IS PLACED WHILE THE TREE IS STILL IN THE TEMPORARY DIRECTORY, so it
# arrives WITH the stage rather than a moment after it.
#
# Writing it after the arrival left a window: a run killed between the stage
# landing and the marker being written leaves a stage that never applied and
# carries no marker, which the next tick reads as a way back and promotes. The
# move is one operation, so a marker already inside the tree cannot arrive late.
# This also drops the assumption that the move is atomic, which depends on the
# staging directory and the fleet prefix sharing a filesystem and is not
# something this script can check.
: > "${TOP}/release/${APPLY_INCOMPLETE}"

if [ ! -f "${FLEET_STAGE}/${APPLY_INCOMPLETE}" ]; then
  # THE DELETION LIVES INSIDE THE GUARD. It used to run first and unconditionally,
  # so a run killed between it and the move left the claw with no previous stage
  # at all: the way back was deleted to make room for something that had not
  # arrived. Nothing is removed until there is something to put in its place.
  #
  # if/fi rather than an AND-list, for legibility rather than for safety. A claw
  # taking its FIRST release has no stage to move aside, which is the ordinary
  # path and not an error. An AND-list would also survive that, because bash
  # exempts a failing test in that position from set -e; checked rather than
  # assumed, because the reverse is a common belief and writing it down as a
  # reason would have put a false sentence in this file.
  if [ -d "$FLEET_STAGE" ]; then
    rm -rf "${FLEET_STAGE}.previous"
    mv "$FLEET_STAGE" "${FLEET_STAGE}.previous"
  fi
else
  # The stage standing here carries its own unfinished-apply marker, so it is not
  # a way back for anybody. The good one is already at .previous and stays there.
  log info "keeping the existing ${FLEET_STAGE}.previous: the stage being replaced carries an unfinished-apply marker, so it is not the way back"
  rm -rf "$FLEET_STAGE"
fi
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

# THE PROGRESS STREAM IS KEPT, NOT JUST THE VERDICTS.
#
# The staging directory goes at exit and `run.log` went with it, so an operator
# reading a failed ride afterwards had the per-check JSON and no account of how the
# run got there. The JSON says which check failed. The log says what the run was
# doing around it, which is the thing somebody debugging at four in the morning
# actually needs.
#
# ONE STAMP FOR BOTH FILES. Computed once and reused, so the pair a reader has to
# put side by side carries one name and cannot straddle a second boundary.
apply_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_LOG_DIR"
cp "${STAGE}/run.json" "${RUN_LOG_DIR}/apply-${apply_stamp}.json" 2>/dev/null || true
cp "${STAGE}/run.log"  "${RUN_LOG_DIR}/apply-${apply_stamp}.log"  2>/dev/null || true

if [ "$apply_rc" -ne 0 ]; then
  VERDICT="apply failed"

  # THE COUNT IS KEYED TO THE VERSION, so a different release starts at one.
  if [ "$FAILING_VERSION" = "$OFFERED" ]; then
    FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
  else
    FAILURE_COUNT=1
  fi
  write_state "$CARRIED" "$CARRIED_TAG" "$CARRIED_DIGEST" "$CARRIED_APPLIED" "$CARRIED_PREV" \
              "apply failed" "$OFFERED" "$FAILURE_COUNT" "$CARRIED_FROM"

  # THE MESSAGE NAMES A PATH ONLY WHEN THE PATH IS THERE.
  #
  # It used to send the operator to /root/plane-previous, which nothing on any
  # claw creates: the constant is FLEET_STAGE and the copy is FLEET_STAGE.previous.
  # This is the one row where the rail names a human as the repair mechanism, and
  # it was pointing them at an empty directory while the rotation above was
  # deleting the real one. A promise about an artifact is checked against the
  # artifact before it is made.
  local_hint="No previous stage is kept on this claw yet, so there is nothing to converge back to; the repair is a newer release or an operator ride"
  if [ -d "${FLEET_STAGE}.previous" ]; then
    local_hint="The previous plane is at ${FLEET_STAGE}.previous and re-applying it converges this claw back"
  fi

  remaining=$(( MAX_APPLY_FAILURES - FAILURE_COUNT ))
  if [ "$remaining" -gt 0 ]; then
    tries_hint="${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} attempts used; ${remaining} left before this claw stops retrying it"
  else
    tries_hint="${FAILURE_COUNT} of ${MAX_APPLY_FAILURES} attempts used; this claw will NOT retry ${OFFERED} again on its own"
  fi

  log err "the provisioning run exited ${apply_rc} applying ${OFFERED}. The carried version is NOT advanced and this claw still carries ${CARRIED}. ${tries_hint}. ${local_hint}. Its result JSON is in ${RUN_LOG_DIR}"
  exit 1
fi

# ---------------------------------------------------------------- record
STEP="record"
# AN APPLY THAT PASSED CLEARS THE FAILURE RECORD. The count exists to stop one
# release being retried forever; a release that landed has nothing left to count.
write_state "$OFFERED" "$OFFERED_TAG" "$GOT_DIGEST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CARRIED" \
            "applied" "" "0" "$APPLIED_FROM"

# THE APPLY PASSED, so this stage becomes a way back. Clearing the marker is the
# only thing that makes it one, and nothing else on the claw writes this file.
rm -f "${FLEET_STAGE}/${APPLY_INCOMPLETE}"

# The wait belonged to a release that has now landed.
rm -f "${DEFER_DIR}/deferred" 2>/dev/null || true

# ------------------------------------------------- the crossing's own entries
STEP="back-fill the skipped releases"
#
# A CLAW SEVERAL RELEASES BEHIND CROSSES THEM IN ONE APPLY, AND THE CHANGELOG HAS
# TO CARRY ALL OF THEM.
#
# The content of every skipped release arrives, because a release is a whole tree
# and a run consumes it entire. The NOTES did not. The provisioning run writes one
# entry from the offered release's notes, so a claw crossing 1.1.0 to 1.3.1 landed
# five releases' changes and told its own people about one. Measured on a tenant
# claw on 2026-09-02: the firm's people lost the account of the shared agents
# token, the admin tiers, wide mode and the session bus, all of which had just
# landed on their machine.
#
# ONE ENTRY PER SKIPPED RELEASE, and that is the shape the file already has. An
# entry carries one `**Revision:**` and one `**Class:**`, so a single entry
# concatenating several releases would have to pick one revision and one class and
# be wrong about the rest. Each release keeps its own.
#
# AFTER THE APPLY, NEVER BEFORE IT. The changelog's law is that an entry claims a
# release LANDED, which is why the provisioning run writes nothing when it fails.
# Back-filling first would put that claim in the file before it was true and leave
# it there if the apply never passed. The cost is the order: these entries land
# below the offered release's own, which the run appended a moment ago. Each one
# says so in its first line, so a reader is not left to infer it from the position.
#
# IT CANNOT FAIL THIS RUN. The release applied. A repository that will not answer,
# or a release whose material the writer refuses, is a gap in the record and not a
# failed update, so every branch here warns and continues. A claw that has spent
# its hourly anonymous budget lands in that branch too, which is one more reason
# the run does not turn on it.
if [ "$CARRIED" != "0.0.0" ]; then
  crossing_writer="${FLEET_STAGE}/provision-claw/scripts/commonclaw-changelog.sh"
  if [ ! -x "$crossing_writer" ]; then
    log warning "cannot back-fill the skipped releases' changelog entries: ${crossing_writer} is missing or not executable. This claw carries ${OFFERED} and its changelog names that release alone"
  else
    # THE TAG LIST IS PAGED UNTIL IT RUNS OUT. A fixed first page would silently
    # drop the oldest releases once the repository passes one page, and the entries
    # that went missing would be exactly the ones a long-behind claw needs.
    crossing_tags=""
    crossing_listed=1
    crossing_page=1
    while [ "$crossing_page" -le 10 ]; do
      if ! fetch_raw "https://api.github.com/repos/${RELEASE_REPO}/tags?per_page=100&page=${crossing_page}" "${STAGE}/tags.json"; then
        log warning "could not read the tag list from ${RELEASE_REPO} (page ${crossing_page}); the skipped releases' entries are not back-filled"
        crossing_tags=""
        crossing_listed=0
        break
      fi
      crossing_got="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "${STAGE}/tags.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' || true)"
      [ -n "$crossing_got" ] || break
      crossing_tags="${crossing_tags}${crossing_got}
"
      [ "$(printf '%s\n' "$crossing_got" | wc -l)" -ge 100 ] || break
      crossing_page=$(( crossing_page + 1 ))
    done

    # STRICTLY BETWEEN, DECIDED BY THE RULED COMPARISON AND BY NOTHING ELSE.
    # `release-rail.md` forbids a second version comparison, and a string test for
    # equality is one: it would call 1.2 and 1.2.0 different releases. So both
    # bounds are asked of version_at_least, which is the same function the verdict
    # above and the core floors use.
    crossing_between=""
    for t in $crossing_tags; do
      v="${t#v}"
      case "$v" in ''|*[!0-9.]*) continue ;; esac
      r=0; version_at_least "$CARRIED" "$v" || r=$?
      [ "$r" -eq 1 ] || continue          # carried < v
      r=0; version_at_least "$v" "$OFFERED" || r=$?
      [ "$r" -eq 1 ] || continue          # v < offered
      crossing_between="${crossing_between}${v}
"
    done

    # OLDEST FIRST, SORTED BY THE SAME FUNCTION. `sort -V` is a second ordering
    # with its own opinion about 2.1.9 and 2.1.10, and the rail's rule against a
    # second comparison covers the sort as much as the verdict.
    crossing_order=""
    crossing_left="$crossing_between"
    while [ -n "$(printf '%s' "$crossing_left" | tr -d '[:space:]')" ]; do
      crossing_min=""
      for v in $crossing_left; do
        if [ -z "$crossing_min" ]; then crossing_min="$v"; continue; fi
        r=0; version_at_least "$v" "$crossing_min" || r=$?
        if [ "$r" -eq 1 ]; then crossing_min="$v"; fi
      done
      crossing_order="${crossing_order}${crossing_min}
"
      crossing_next=""
      for v in $crossing_left; do
        [ "$v" = "$crossing_min" ] || crossing_next="${crossing_next}${v}
"
      done
      crossing_left="$crossing_next"
    done

    # NOTHING TO BACK-FILL AND NOTHING READABLE ARE TWO DIFFERENT ANSWERS, and only
    # one of them is quiet. A failed tag read leaves the same empty list a one-hop
    # update leaves, and reporting "no releases were skipped" from a list nobody
    # could read is the measured-nothing green again. The failure already warned
    # above, so this branch stays silent rather than contradicting it.
    crossing_n="$(printf '%s' "$crossing_order" | grep -c . || true)"
    if [ "$crossing_listed" -eq 0 ]; then
      :
    elif [ "${crossing_n:-0}" -eq 0 ]; then
      log info "no releases were skipped between ${CARRIED} and ${OFFERED}; the changelog needs no back-fill"
    else
      log info "this apply crossed ${crossing_n} release(s) between ${CARRIED} and ${OFFERED}; writing their member-facing notes into the changelog, oldest first"
      for v in $crossing_order; do
        crossing_tag="v${v}"
        rm -f "${STAGE}/x-release.json" "${STAGE}/x-notes.md" "${STAGE}/x-entry.md"
        if ! fetch_raw "https://api.github.com/repos/${RELEASE_REPO}/contents/release/release.json?ref=${crossing_tag}" "${STAGE}/x-release.json" \
           || ! fetch_raw "https://api.github.com/repos/${RELEASE_REPO}/contents/release/notes.md?ref=${crossing_tag}" "${STAGE}/x-notes.md"; then
          log warning "could not read the notes or the release file at ${crossing_tag}; release ${v} landed on this claw and its changelog entry is missing"
          continue
        fi
        crossing_rev="$(sed -n 's/.*"revision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${STAGE}/x-release.json" | head -1)"
        crossing_class="$(sed -n 's/.*"class"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${STAGE}/x-release.json" | head -1)"
        if [ -z "$crossing_rev" ] || [ -z "$crossing_class" ] || [ ! -s "${STAGE}/x-notes.md" ]; then
          log warning "the release at ${crossing_tag} carries no revision, no class or no notes; release ${v} landed on this claw and its changelog entry is missing"
          continue
        fi
        # THE FIRST LINE SAYS WHY THIS ENTRY SITS WHERE IT SITS, and it is also the
        # line the writer fingerprints, so a re-run of the same crossing dedupes on
        # it rather than appending a second copy.
        {
          printf 'This release landed on this claw as part of the update to %s, whose entry is above. It is recorded here so the account of what changed is complete.\n\n' "$OFFERED"
          cat "${STAGE}/x-notes.md"
        } > "${STAGE}/x-entry.md"
        if "$crossing_writer" --revision "$crossing_rev" --class "$crossing_class" --notes "${STAGE}/x-entry.md" >&2; then
          log info "changelog entry written for the skipped release ${v} (${crossing_rev}, class ${crossing_class})"
        else
          log warning "the changelog entry for the skipped release ${v} FAILED to write; that release landed on this claw and its people have no record of it"
        fi
      done
    fi
  fi
fi


VERDICT="applied"
if [ "$OUTSIDE_WINDOW" -eq 1 ]; then
  VERDICT="applied outside the quiet window"
  log warning "release ${OFFERED} applied OUTSIDE the quiet window after the deferral bound was reached"
elif [ -n "$RIDE_TAG" ]; then
  log info "release ${OFFERED} applied from the ride of ${OFFERED_TAG}; this claw now carries it and is AHEAD of the ${CHANNEL} pointer, so every tick reads 'already at or above' and changes nothing until that pointer passes it"
else
  log info "release ${OFFERED} applied; this claw now carries it"
fi

# ---------------------------------------------------------------- the health
#
# THE APPLY PASSING IS NOT THE SAME QUESTION AS THE BOX BEING WELL. A release
# converges units, and a unit this run laid can come up and then start dying on
# a schedule with every check in the run already green. Nobody watches an
# unattended tick, so the reading goes in the journal beside the verdict.
#
# IT NEVER FAILS THE UPDATE. The release applied and that stays true. A unit
# this apply did not lay can be looping for its own reasons, and turning that
# into a failed update would move the carried version backwards over somebody
# else's fault. So this warns and the verdict is untouched.
#
# The reading comes from the sibling rather than from a `systemctl --failed`
# line here, because the ride runbook tells a person to run the same reading and
# two copies would drift on what healthy means.
health_reader="${PLANE}/scripts/unit-health.sh"
[ -r "$health_reader" ] || health_reader="${FLEET_STAGE}/provision-claw/scripts/unit-health.sh"
if [ -r "$health_reader" ]; then
  # shellcheck source=unit-health.sh
  . "$health_reader"
  health_out=""
  if health_out="$(unit_health 2>&1)"; then
    log info "unit health after the apply: ${health_out}"
  else
    while IFS= read -r health_line; do
      [ -n "$health_line" ] || continue
      log warning "unit health after the apply: ${health_line}"
    done <<< "$health_out"
    log warning "the release applied and this claw carries it. The units above are a separate matter and nothing here retries them"
  fi
else
  log warning "no unit-health.sh beside this script, so the apply's end-of-run health was not read"
fi
