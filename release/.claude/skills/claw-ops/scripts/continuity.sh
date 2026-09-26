#!/bin/bash
#
# continuity.sh: what the continuity rail has done for this account's
# orchestrators.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./continuity.sh
#   ./continuity.sh --help
#
# REQUIRED ROLE: member. It reads this account's own state and nothing else.
#
# WHAT THE RAIL IS. A program outside every session. It wakes an orchestrator
# that has mail, brings back one whose process has gone, stops what it resumed
# once that is quiet, and asks for the postures write on a clock. Its own --help
# is the description of record.
#
# THE RAIL ANSWERS FOR ITSELF. The board of handles, the bus it reads and the
# state directory it writes all come from the rail's own --check. A second
# reading of the bus here would be a second opinion about which handles are
# orchestrators, and the rail's is the one that acts.
#
# WHAT THIS ADDS TO THAT. The rail says what it would do next. This says what it
# has done: per handle, the last wake and the last resume with their outcomes,
# the session it resumed and has not stopped, and any hold. Plus the three
# readings the rail does not carry: whether it is enabled for this account, what
# its timer did, and whether the harness is signed in.
#
# THE TIMER IS A SYSTEM UNIT, one instance per account, so its state comes from
# the system manager rather than the caller's own. Reading unit state there needs
# no privilege, and this readout changes nothing.
#
# A HOLD AND A SIGN-OUT ARE ONE FINDING. A resume that fails writes a hold, and
# no handle of the account is resumed until it is cleared. A signed-out harness
# is the usual reason, so the two are read together and reported together.
#
# ANOTHER ACCOUNT IS UNREADABLE, NEVER ABSENT. The rail keeps its state under
# each owner's own home. This readout covers the caller and says so.
#
# THE SIGN-IN READING IS THE CLAW'S OWN. commonclaw-signin-check --read prints
# one word: signed-in, signed-out, never or unreadable. It makes the harness try
# its own refresh before it asks, so an expired login reads signed-out. The
# harness's status verb alone reads the login file and says signed in long after
# the login has lapsed. Where that program is absent, the answer is unreadable,
# and nothing here asks the harness instead. No token and no address is read.
#
# FINDINGS ARE DATA. The exit status says whether the readout ran, never what it
# found. A rail that is not installed is a finding and exit 0.
#
set -uo pipefail

RAIL="/opt/commonclaw/bin/session-continuity"
ENABLED_RECORD_DIR="/var/lib/commonclaw/session-continuity-enabled"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The one reading of a timer's timestamps. A missing sibling fails the run
# rather than being skipped.
# shellcheck source=job-lib.sh
[ -r "${SCRIPT_DIR}/job-lib.sh" ] \
  || { printf 'no job-lib.sh beside this script\n' >&2; exit 1; }
. "${SCRIPT_DIR}/job-lib.sh"

case "${1:-}" in
  "") : ;;
  -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'jq is required and is not installed\n' >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { printf 'systemctl is required and is not installed\n' >&2; exit 1; }

ME="$(id -un)"
FINDINGS=""
finding() { FINDINGS+="$(jq -cn --arg level "$1" --arg text "$2" '{level:$level,text:$text}')"$'\n'; }

# ------------------------------------------------------------------- the rail

RAIL_PRESENT=false
CHECK='{}'
STATE_DIR=""
BUS_DIR=""

if [ -x "$RAIL" ]; then
  RAIL_PRESENT=true
  printf 'reading the rail\n' >&2
  out="$("$RAIL" --check 2>/tmp/continuity.$$.err)"; rc=$?
  err="$(head -1 /tmp/continuity.$$.err 2>/dev/null || true)"
  rm -f /tmp/continuity.$$.err
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    CHECK="$out"
    STATE_DIR="$(printf '%s' "$CHECK" | jq -r '.state_dir // ""')"
    BUS_DIR="$(printf '%s' "$CHECK" | jq -r '.bus_dir // ""')"
  fi
  [ "$rc" -eq 0 ] || finding error "the rail refused a pass here: ${err:-exit $rc}. It resumes nothing while that stands."
else
  finding warn "no continuity rail at ${RAIL}, so nothing outside a session brings an orchestrator of this account back. A release installs it."
fi

# --------------------------------------------------------- enabled, and timed
#
# The rail's timer is a system unit, one instance per account, the way the wake
# rail's and the sweeper's are. So this reads the system manager and not the
# caller's own. Unit state there is readable by anybody; changing it is not, and
# this readout changes nothing.

ENABLED=false
[ -f "${ENABLED_RECORD_DIR}/${ME}" ] && ENABLED=true

TIMER="session-continuity@${ME}.timer"
SERVICE="session-continuity@${ME}.service"
TIMER_STATE="unreadable"
TIMER_ENABLED="unreadable"
TIMER_NEXT=""
TIMER_LAST=""
TIMER_RESULT=""
MANAGER=false

if systemctl is-system-running >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
  MANAGER=true
  TIMER_STATE="$(systemctl is-active "$TIMER" 2>/dev/null || true)"
  [ -n "$TIMER_STATE" ] || TIMER_STATE="inactive"
  TIMER_ENABLED="$(systemctl is-enabled "$TIMER" 2>/dev/null || true)"
  [ -n "$TIMER_ENABLED" ] || TIMER_ENABLED="disabled"
  TIMER_NEXT="$(job_timestamp_utc "$(systemctl show "$TIMER" -p NextElapseUSecRealtime --value 2>/dev/null || true)")"
  TIMER_LAST="$(job_timestamp_utc "$(systemctl show "$TIMER" -p LastTriggerUSec --value 2>/dev/null || true)")"
  TIMER_RESULT="$(systemctl show "$SERVICE" -p Result --value 2>/dev/null || true)"
else
  finding warn "no system service manager answers here, so the rail's timer was not read."
fi

if [ "$RAIL_PRESENT" = true ] && [ "$MANAGER" = true ] && [ "$TIMER_STATE" != "active" ] && [ "$TIMER_ENABLED" = "disabled" ]; then
  finding warn "the rail's timer for ${ME} reads ${TIMER_STATE} and ${TIMER_ENABLED}. Nothing is waking an orchestrator of this account."
fi
if [ "$RAIL_PRESENT" = true ] && [ "$ENABLED" = false ] && [ "$TIMER_ENABLED" = "disabled" ]; then
  finding info "the rail is installed and not enabled for ${ME}. Its handles are covered by nothing outside their own sessions."
fi

# ------------------------------------------------------------- the sign-in
#
# The hold's usual reason, in the sign-in check's one word. Unreadable is not
# signed out.

SIGNIN="/opt/commonclaw/bin/commonclaw-signin-check"
SIGNED_IN="unreadable"
if [ -x "$SIGNIN" ]; then
  printf 'reading the sign-in check\n' >&2
  word="$(timeout 60 "$SIGNIN" --read 2>/dev/null | head -1 | tr -d '[:space:]')"
  case "$word" in
    signed-in|signed-out|never|unreadable) SIGNED_IN="$word" ;;
  esac
else
  finding info "no sign-in check at ${SIGNIN}, so whether ${ME} is signed in was not read. A release installs it."
fi
case "$SIGNED_IN" in
  signed-out) finding error "the harness is signed out for ${ME}. Every resume fails until somebody signs in as ${ME}, and the rail holds after the first failure." ;;
  never)      finding info "${ME} has never signed in to the harness on this claw, so no orchestrator of this account can be resumed." ;;
  unreadable) [ ! -x "$SIGNIN" ] || finding info "the sign-in check answered unreadable for ${ME}. Unreadable is not signed out." ;;
esac

# ------------------------------------------------------------------ the rows
#
# One row per orchestrator handle the rail covers for this account, with what it
# has done for that handle. The rail's row carries the handle, its session, its
# unread count and the action a pass would take now; the state file carries the
# history.

ROWS=""
HOLDS=""
if [ "$RAIL_PRESENT" = true ]; then
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    handle="$(printf '%s' "$row" | jq -r '.handle')"
    state='{}'
    if [ -n "$STATE_DIR" ]; then
      f="${STATE_DIR}/$(printf '%s' "$handle" | tr -c 'A-Za-z0-9_.-' '_').json"
      if [ -r "$f" ] && s="$(cat "$f")" && printf '%s' "$s" | jq -e . >/dev/null 2>&1; then
        state="$s"
      fi
    fi
    ROWS+="$(jq -cn --argjson r "$row" --argjson s "$state" \
      '{handle:$r.handle, session:$r.session, unread:$r.unread,
        address:$r.address, cwd:$r.cwd,
        next_action:$r.action, next_action_reason:$r.reason,
        last_wake:($s.last_wake // null),
        last_wake_outcome:($s.last_wake_outcome // null),
        last_resume:($s.last_resume // null),
        last_resume_outcome:($s.last_resume_outcome // null),
        last_resume_bare:($s.last_resume_bare // null),
        resumed_session:($s.resumed_session // null),
        stopped_at:($s.stopped_at // null),
        hold:($s.hold // null)}')"$'\n'

    if printf '%s' "$state" | jq -e '.hold != null' >/dev/null 2>&1; then
      HOLDS+="$(jq -cn --arg handle "$handle" --argjson hold "$(printf '%s' "$state" | jq -c '.hold')" \
        '{handle:$handle, hold:$hold}')"$'\n'
    fi
  done <<< "$(printf '%s' "$CHECK" | jq -c '.rows[]? // empty')"
fi

holds_count="$(printf '%s' "$HOLDS" | jq -s 'length')"
[ "${holds_count:-0}" -eq 0 ] || \
  finding error "${holds_count} handle(s) carry a hold, so no handle of ${ME} is resumed until it is cleared. The rail's --clear-hold clears one."

nudged_unread="$(printf '%s' "$ROWS" | jq -s '[.[] | select(.unread > 0 and .last_wake_outcome == "delivered")] | length')"
[ "${nudged_unread:-0}" -eq 0 ] || \
  finding info "${nudged_unread} handle(s) took a delivered wake and still hold unread mail. That session got the nudge and did not act on it."

resumed_open="$(printf '%s' "$ROWS" | jq -s '[.[] | select(.resumed_session != null)] | length')"
[ "${resumed_open:-0}" -eq 0 ] || \
  finding info "${resumed_open} session(s) the rail resumed are still recorded as running. A pass stops one once its transcript has been quiet."

# ---------------------------------------------------------------------- emit

jq -n \
  --arg script "continuity" \
  --arg host "$(hostname -s)" \
  --arg me "$ME" \
  --arg rail "$RAIL" \
  --argjson rail_present "$RAIL_PRESENT" \
  --argjson enabled "$ENABLED" \
  --arg state_dir "$STATE_DIR" \
  --arg bus_dir "$BUS_DIR" \
  --arg timer "$TIMER" \
  --arg timer_state "$TIMER_STATE" \
  --arg timer_enabled "$TIMER_ENABLED" \
  --arg timer_next "$TIMER_NEXT" \
  --arg timer_last "$TIMER_LAST" \
  --arg timer_result "$TIMER_RESULT" \
  --argjson manager "$MANAGER" \
  --arg signed_in "$SIGNED_IN" \
  --arg signin "$SIGNIN" \
  --argjson handles "$(printf '%s' "$ROWS" | jq -s .)" \
  --argjson holds "$(printf '%s' "$HOLDS" | jq -s .)" \
  --argjson findings "$(printf '%s' "$FINDINGS" | jq -s .)" \
  '{script:$script, ok:true, claw:$host, caller:$me,
    rail:{program:$rail, present:$rail_present, enabled_for_caller:$enabled,
          state_dir:(if $state_dir == "" then null else $state_dir end),
          bus_dir:(if $bus_dir == "" then null else $bus_dir end)},
    timer:{unit:$timer, state:$timer_state, enabled:$timer_enabled,
           system_manager_readable:$manager,
           next_run:(if $timer_next == "" then null else $timer_next end),
           last_run:(if $timer_last == "" then null else $timer_last end),
           last_result:(if $timer_result == "" then null else $timer_result end)},
    harness:{signed_in:$signed_in, read_by:$signin},
    handles:$handles,
    holds:$holds,
    findings:$findings}'
