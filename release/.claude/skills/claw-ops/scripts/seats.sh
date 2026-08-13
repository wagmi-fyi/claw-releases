#!/bin/bash
#
# seats.sh — read this claw's seat roster and the last verdict on it.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./seats.sh
#
# REQUIRED ROLE: member. This script holds no privilege of its own, calls no
# sudo, and changes nothing.
#
# THE ROSTER IS A DECLARATION, NOT AN OBSERVATION. It says which seats this claw
# expects. Whether each one is healthy right now is the claw's own seat check's
# answer, taken on its own schedule and written to the journal, and this readout
# reports that verdict rather than taking a new one.
#
# THIS SCRIPT DOES NOT PARSE THE ROSTER. It asks the claw's own seat check for
# the folded state, the same way the retire operation does. The grammar has one
# reader on this claw and there is no second copy of it here to drift.
#
# SEATS ARE THE CALLER'S OWN. Another person's live seat state lives in their
# home and stays there; `claw-status.sh` reports the caller's own. What is
# public here is the DECLARATION, which is a claw-level fact in a root-owned
# file every member can read.
#
# FINDINGS ARE DATA. The exit status reports whether the readout ran, never what
# it found.
#
set -uo pipefail

CHECK="/usr/local/sbin/commonclaw-seat-check.sh"
ROSTER="/etc/commonclaw/seats.yaml"
SEAT_TAG="commonclaw-seat-check"

case "${1:-}" in
  "") : ;;
  -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'jq is required and is not installed\n' >&2; exit 1; }

FINDINGS=""
finding() { FINDINGS+="$(jq -cn --arg level "$1" --arg text "$2" '{level:$level,text:$text}')"$'\n'; }

ME="$(id -un)"
GROUPS_TEXT=" $(id -nG 2>/dev/null || true) "

# The journal is group-gated. Deriving access from a journalctl exit status
# would not work: an unprivileged caller gets an empty listing and a zero exit,
# so "no access" and "no runs" would read the same.
case "$GROUPS_TEXT" in
  *" systemd-journal "*|*" adm "*) JOURNAL=true ;;
  *) if [ "$(id -u)" -eq 0 ]; then JOURNAL=true; else JOURNAL=false; fi ;;
esac

# ---------------------------------------------------------------- the roster

SEATS=""
ROSTER_PRESENT=false
ROSTER_READABLE=true

if [ ! -x "$CHECK" ]; then
  ROSTER_READABLE=false
  finding warn "no seat check at ${CHECK}: this claw was provisioned before the roster existed, or the check was removed. Repair it from the provisioning plane."
else
  # Not observed is not the same as not declared: a check that refused to read
  # its own roster says so, and its message is the useful part.
  if state="$("$CHECK" --state 2>&1)"; then
    while IFS= read -r line; do
      case "$line" in
        "roster: present") ROSTER_PRESENT=true; continue ;;
        "roster: absent")  ROSTER_PRESENT=false; continue ;;
        "") continue ;;
      esac
      read -r p c e d b rest <<< "$line"
      if id "$p" >/dev/null 2>&1; then acct=true; else acct=false; fi
      SEATS+="$(jq -cn --arg person "$p" --arg core "$c" --arg state "$e" \
        --arg date "$d" --arg by "$b" --arg reason "$rest" \
        --argjson account "$acct" --argjson mine "$([ "$p" = "$ME" ] && echo true || echo false)" \
        '{person:$person, core:$core, state:$state, since:$date, by:$by,
          reason:(if $reason == "" then null else $reason end),
          account_exists:$account, caller_is_subject:$mine}')"$'\n'
    done <<< "$state"
  else
    ROSTER_READABLE=false
    finding warn "the seat check refused to read the roster: ${state}"
  fi
fi

if [ "$ROSTER_READABLE" = true ] && [ "$ROSTER_PRESENT" = false ]; then
  finding info "this claw declares no seats: with no roster at ${ROSTER} the check infers expectation from each core's directory, which is how every claw behaved before rosters existed"
fi

# A declared seat whose person has no account is the case the roster exists to
# make visible. It is reported as an observation rather than a verdict; the
# verdict is the seat check's, and it names the same act -- retire the row.
gone="$(printf '%s' "$SEATS" | jq -s '[.[] | select(.state == "seated" and .account_exists == false)] | length')"
[ "${gone:-0}" -eq 0 ] || \
  finding warn "${gone} declared seat(s) belong to accounts that do not exist on this claw: retire those rows, with a reason"

# ---------------------------------------------------------------- last verdict

# The check's own output, read where it lands. Running the check again from
# here would take a second measurement at a member's privilege and report it
# beside the claw's, and the two would disagree for reasons that say nothing
# about seats.
LAST_RUN=""; LAST_LINES=""
if [ "$JOURNAL" = true ] && command -v journalctl >/dev/null 2>&1; then
  LAST_RUN="$(journalctl -t "$SEAT_TAG" -n 1 --no-pager -o short-iso 2>/dev/null | tail -1)"
  LAST_LINES="$(journalctl -t "$SEAT_TAG" --since "-2 days" --no-pager -o cat 2>/dev/null || true)"
  [ -n "$LAST_RUN" ] || \
    finding warn "the seat check has never written to the journal on this claw: it is installed but nothing has run it, or the entries have rotated away"
else
  finding info "the seat check's journal was not read: ${ME} is in neither systemd-journal nor adm, so the last verdict was not observed"
fi

# ---------------------------------------------------------------- emit

jq -n \
  --arg host "$(hostname)" \
  --arg me "$ME" \
  --arg roster "$ROSTER" \
  --argjson present "$ROSTER_PRESENT" \
  --argjson readable "$ROSTER_READABLE" \
  --argjson journal "$JOURNAL" \
  --arg last_run "$LAST_RUN" \
  --argjson seats "$(printf '%s' "$SEATS" | jq -s .)" \
  --argjson recent "$(printf '%s' "$LAST_LINES" | jq -R -s 'split("\n") | map(select(length > 0))')" \
  --argjson findings "$(printf '%s' "$FINDINGS" | jq -s .)" \
  '{script:"seats", ok:true, claw:$host, caller:$me,
    roster:{path:$roster, present:$present, readable:$readable},
    seats:$seats,
    last_check:{journal_readable:$journal,
                last_journal_line:(if $last_run == "" then null else $last_run end),
                recent_lines:$recent},
    findings:$findings}'
