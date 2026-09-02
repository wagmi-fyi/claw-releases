#!/bin/bash
#
# commonclaw-stall-check.sh — say out loud when an orchestration has stopped
# being read.
#
# PAYLOAD SCRIPT. Installed onto the claw and run by a root systemd timer.
# It posts through commonclaw-notify.sh and it is the first producer that
# exists to reach a person when NO session is running.
#
#   commonclaw-stall-check.sh              the beat. Posts if it finds a stall
#   commonclaw-stall-check.sh --state      print the finding, post nothing
#   commonclaw-stall-check.sh --dry-run    render the message, post nothing
#
# THE DEFECT THIS CLOSES. The session bus is files. A delegate writes its
# report into an inbox and announces it to nobody. When the session that owns
# that inbox has ended, or is alive and idle, the report waits. Three stalls in
# August ran for days that way. Every in-session mechanism tried so far dies
# with the session, which is the one condition under which the message matters.
# A root timer does not.
#
# WHAT COUNTS AS A STALL, AND WHY IT IS THIS AND NOT SOMETHING BROADER.
#
#   An ORCHESTRATOR handle with unread mail older than the threshold.
#
# The obvious rule -- any handle with aged unread mail -- was measured before it
# was rejected. On this claw it matches about 37 of 122 handles, and nearly all
# of them are finished workers holding a stand-down message nobody ever needs to
# read. A beat that posts 37 lines on its first run teaches its reader to skip
# the tag, which is the failure this rail exists to end, arriving one layer out.
#
# An orchestrator handle is different in kind. It is the one handle a run
# guarantees somebody drains, so mail sitting in it past the threshold means the
# reader is gone or is not looking. That is the stall, exactly.
#
# THE `human` HANDLE IS DELIBERATELY NOT WATCHED. It is an append-only ledger:
# the orchestrations write asks into it and nothing drains it, by design, because
# its human-facing rendering is the action-items file beside each workpaper. Its
# unread count only grows. Watching it would post every beat forever.
#
# IT REPORTS NAMES, COUNTS AND AGES. NEVER SUBJECTS, NEVER BODIES. This claw is
# multi-user on purpose, the buses under /home belong to their owners, and a
# Slack channel is a different audience from a bus inbox. The finding a reader
# needs is "this run stopped being read", and the handle name carries it.
#
# EXIT CODES. 0 whether or not it found something and whether or not delivery
# worked. This is a timer producer: its own health is the unit's business, and a
# Slack outage must not turn into a failed unit. 2 is a usage error.
#
# WHAT WATCHES THIS. Nothing, the same hole commonclaw-notify.sh names about
# itself. Silence means healthy, and it also means the timer is off. Named here
# rather than discovered during an incident.
#
# THE OVERRIDES BELOW EXIST FOR CONTROLS. STALL_CONF, STALL_NOW_EPOCH and
# NOTIFIER point this script at fixtures. The timer sets none of them.
#
set -uo pipefail

STALL_CONF="${STALL_CONF:-/etc/commonclaw/stall-check.conf}"
NOTIFIER="${NOTIFIER:-/usr/local/sbin/commonclaw-notify.sh}"

# ------------------------------------------------------------------ defaults
ENABLED="yes"
THRESHOLD_HOURS=3
DEDUPE_HOURS=20
# Empty means discover. The claw's own bus, plus each member's own under their
# home. Discovery rather than a list, so a member who joins next month is
# watched without anybody remembering to edit a conf.
BUS_DIRS=""

MODE="beat"
while [ $# -gt 0 ]; do
  case "$1" in
    --state)   MODE="state"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

log() { logger -t commonclaw-stall-check -p "user.$1" -- "$2" 2>/dev/null || true; printf '[%s] %s\n' "$1" "$2" >&2; }

if [ -e "$STALL_CONF" ]; then
  [ -r "$STALL_CONF" ] || { log err "the conf at ${STALL_CONF} cannot be read"; exit 0; }
  # shellcheck disable=SC1090
  . "$STALL_CONF"
fi

case "$ENABLED" in
  yes) : ;;
  no)  log notice "the stall check is turned off on this claw"; exit 0 ;;
  *)   log err "ENABLED in ${STALL_CONF} is yes or no, not '${ENABLED}'"; exit 0 ;;
esac
case "$THRESHOLD_HOURS" in ''|*[!0-9]*) log err "THRESHOLD_HOURS is a whole number of hours, not '${THRESHOLD_HOURS}'"; exit 0 ;; esac
case "$DEDUPE_HOURS"    in ''|*[!0-9]*) log err "DEDUPE_HOURS is a whole number of hours, not '${DEDUPE_HOURS}'"; exit 0 ;; esac

command -v jq >/dev/null 2>&1 || { log err "jq is not installed, so no bus can be read"; exit 0; }

NOW="${STALL_NOW_EPOCH:-$(date +%s)}"
THRESHOLD_S=$(( THRESHOLD_HOURS * 3600 ))

if [ -z "$BUS_DIRS" ]; then
  BUS_DIRS="/var/lib/commonclaw/bus"
  for d in /home/*/.claude/session-bus; do
    [ -d "$d" ] && BUS_DIRS="${BUS_DIRS} ${d}"
  done
fi

# ------------------------------------------------------------------ the sweep
FINDINGS=(); KEYPARTS=()

for bus in $BUS_DIRS; do
  handles="${bus}/handles.json"
  [ -r "$handles" ] || continue

  # One jq pass gives every orchestrator handle on this bus and its owner. The
  # role is what the run itself declared at registration; nothing here guesses.
  while IFS=$'\t' read -r h owner; do
    [ -n "$h" ] || continue
    inbox="${bus}/inbox/${h}.jsonl"
    [ -r "$inbox" ] || continue

    total="$(wc -l < "$inbox" 2>/dev/null || printf 0)"
    cursor=0
    cfile="${bus}/cursors/${h}.cursor"
    if [ -r "$cfile" ]; then
      cursor="$(cat "$cfile" 2>/dev/null)"
      case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    fi

    unread=$(( total - cursor ))
    [ "$unread" -gt 0 ] || continue

    # The oldest unread message is the line the cursor points at. Its age is the
    # age of the stall: a run that stopped being read three days ago reads as
    # three days here, not as the age of the newest thing sent into it.
    ts="$(sed -n "$(( cursor + 1 ))p" "$inbox" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null)"
    [ -n "$ts" ] || continue
    then_s="$(date -d "$ts" +%s 2>/dev/null)" || continue
    case "$then_s" in ''|*[!0-9]*) continue ;; esac

    age=$(( NOW - then_s ))
    [ "$age" -ge "$THRESHOLD_S" ] || continue

    hours=$(( age / 3600 ))
    FINDINGS+=("${h} (${owner}): ${unread} unread, oldest ${hours}h old, on ${bus}")
    KEYPARTS+=("${bus}:${h}")
  done < <(jq -r 'to_entries[] | select(.value.role == "orchestrator") | "\(.key)\t\(.value.owner // "?")"' "$handles" 2>/dev/null | sort)
done

if [ "${#FINDINGS[@]}" -eq 0 ]; then
  [ "$MODE" = "beat" ] || printf 'no stalled orchestrator handle: nothing older than %sh is unread\n' "$THRESHOLD_HOURS"
  exit 0
fi

SUMMARY="${#FINDINGS[@]} orchestration(s) on this claw have unread mail nobody is reading. Open a session and drain them"

# ------------------------------------------------------------------ the key
#
# The dedupe key carries the SET of stalled handles, so the same stall stays
# quiet for the window and a NEW one breaks through the same beat it appears.
# A key that named only the count would swallow a new stall whenever an old one
# closed in the same beat, which is the pair of events most worth hearing about.
KEY="stall-$(printf '%s\n' "${KEYPARTS[@]}" | sort | sha256sum | cut -c1-12)"

if [ "$MODE" = "state" ]; then
  printf '%s\n' "$SUMMARY"
  printf '  %s\n' "${FINDINGS[@]}"
  printf 'dedupe key: %s (window %sh)\n' "$KEY" "$DEDUPE_HOURS"
  exit 0
fi

# ------------------------------------------------------------------ delivery
#
# `|| true` is the rule every wire into the notifier follows. A producer's exit
# code is its own health signal; a notifier that could change it would make a
# Slack outage read as a stalled claw.
[ -x "$NOTIFIER" ] || { log err "the notifier at ${NOTIFIER} is not installed, so ${#FINDINGS[@]} stall finding(s) reached nobody"; exit 0; }

DRY=()
[ "$MODE" = "dry-run" ] && DRY=(--dry-run)

printf '%s\n' "${FINDINGS[@]}" | "$NOTIFIER" "${DRY[@]}" \
  --class claw-note --level warn --stdin \
  --summary "$SUMMARY" \
  --dedupe-key "$KEY" --dedupe-hours "$DEDUPE_HOURS" || true

# Stamps accumulate one file per distinct stall set. Thirty days is far outside
# any dedupe window this conf can set, so pruning here can never un-suppress a
# message that is still inside its own window.
find /var/lib/commonclaw/notify -maxdepth 1 -type f -name 'stall-*' -mtime +30 -delete 2>/dev/null || true

exit 0
