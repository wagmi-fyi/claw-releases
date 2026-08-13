#!/bin/bash
#
# retire-seat.sh — retire one declared seat from the claw's roster.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./retire-seat.sh --person alice --core codex --reason "moved to claude only"
#
#   --dry-run    say what would be appended, change nothing
#
# The roster ratchets UP by itself: an observed live login declares its own
# seat. It never ratchets down, because a retired seat and a destroyed seat look
# identical from the machine, and removing on absence would recreate exactly the
# blindness the seat check exists to prevent. So coming down is a decision, a
# person makes it, and this is where that decision is recorded.
#
# APPEND-ONLY, like every other writer of this file. The seat is not deleted
# from the roster; a `retired` event is added after it, carrying who decided and
# why. The file stays its own audit trail, and nothing is ever rewritten under a
# concurrent reader.
#
# RETIRE A SEAT THAT HAS GONE, NOT ONE THAT IS RUNNING. A live login is observed
# on the next check and re-opens its own row -- deliberately, because a seat
# somebody is still using is a seat this claw expects, and leaving it undeclared
# is the failure mode that costs the most. The JSON says so on every run.
#
# THIS SCRIPT DOES NOT PARSE THE ROSTER. It asks the claw's own seat check for
# the folded state. One reader of that grammar, one place it can drift from.
#
set -euo pipefail

PERSON=""; CORE=""; REASON=""; DRY_RUN=0

# The contract with the provisioning plane: the paths phase 12 installs. Both
# sides name them and neither may move one alone.
ROSTER="/etc/commonclaw/seats.yaml"
CHECK="/usr/local/sbin/commonclaw-seat-check.sh"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --person) PERSON="${2:-}"; shift 2 ;;
    --core)   CORE="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"

say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  OK    %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(true); return 0; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(false); FAILED=1; return 0; }
warn() { printf '  note  %s\n' "$*" >&2; NOTES+=("$*"); return 0; }

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_json() {
  local i first
  printf '{\n'
  printf '  "script": "retire-seat",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "person": "%s",\n' "$(json_esc "$PERSON")"
  printf '  "core": "%s",\n' "$(json_esc "$CORE")"
  printf '  "reason": "%s",\n' "$(json_esc "$REASON")"
  printf '  "roster": "%s",\n' "$(json_esc "$ROSTER")"
  printf '  "action": "%s",\n' "$(json_esc "$ACTION")"
  printf '  "checks": [\n'
  for i in "${!CHK_DESC[@]}"; do
    printf '    {"check": "%s", "ok": %s}' "$(json_esc "${CHK_DESC[$i]}")" "${CHK_OK[$i]}"
    [ "$i" -lt $(( ${#CHK_DESC[@]} - 1 )) ] && printf ','
    printf '\n'
  done
  printf '  ],\n'
  printf '  "failed_checks": ['
  first=1
  for i in "${!CHK_DESC[@]}"; do
    [ "${CHK_OK[$i]}" = "false" ] || continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "${CHK_DESC[$i]}")"; first=0
  done
  printf '],\n'
  printf '  "notes": ['
  first=1
  for i in "${NOTES[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "$i")"; first=0
  done
  printf ']\n}\n'
}

finish() { emit_json; [ "$FAILED" -eq 0 ] || exit 1; exit 0; }

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { say "run this as root"; exit 1; }

for v in PERSON CORE REASON; do
  [ -n "${!v}" ] || { say "missing required argument: $v"; usage; }
done

# The grant carries no argument pattern, so every rule about arguments lives
# here. A name that is not a name, or a reason carrying a newline or a brace,
# would write a line the roster's own grammar cannot read back.
#
# TWO patterns each, and the negative one is what decides. A shell case pattern
# is ANCHORED AT BOTH ENDS, so `[a-z_][a-z0-9_-]*` reads as a character class
# followed by ANY remaining characters -- its trailing star is not "more of the
# same class". Measured 2026-08-11: that form validates the FIRST TWO CHARACTERS
# and nothing after them, so it accepted `ab; touch /tmp/pwned` as a person.
# Nothing was reachable through it here, because every use is quoted and the
# roster lookup refuses a name it does not already carry -- but a refusal that
# comes from somewhere else is a property somebody can change without knowing it
# was load-bearing.
is_unix_name() { case "$1" in [a-z_]*) : ;; *) return 1 ;; esac; case "$1" in *[!a-z0-9_-]*) return 1 ;; esac; }
is_slug()      { case "$1" in [a-z]*)  : ;; *) return 1 ;; esac; case "$1" in *[!a-z0-9-]*)  return 1 ;; esac; }

is_unix_name "$PERSON" || { say "person is not a unix name: '$PERSON'"; exit 1; }
is_slug "$CORE"        || { say "core is not a core name: '$CORE'"; exit 1; }
case "$REASON" in
  *[$'\n\r\t']*|*'{'*|*'}'*) say "reason may not carry a line break or a brace"; exit 1 ;;
esac
[ "${#REASON}" -le 200 ] || { say "reason is longer than 200 characters"; exit 1; }
case "$REASON" in *[![:space:]]*) : ;; *) say "reason is empty"; exit 1 ;; esac

[ -x "$CHECK" ] || { say "the claw's seat check is not installed at ${CHECK}"; exit 1; }
[ -f "$ROSTER" ] || {
  say "no roster at ${ROSTER}: this claw does not declare its seats, so there is nothing to retire"
  say "the roster is seeded by provisioning; run the provisioning plane rather than creating it here"
  exit 1
}

# The caller behind sudo, not root. A retirement records who decided it, and
# "root" would record nothing.
BY="${SUDO_USER:-$(id -un)}"
is_unix_name "$BY" || BY="root"

TODAY="$(date -I)"

say ""
say "=== retire seat ${CORE} for ${PERSON} ==="
say "  roster:  ${ROSTER}"
say "  by:      ${BY}"
say "  reason:  ${REASON}"
say ""

# ---------------------------------------------------------------- current state

# One reader of the roster grammar. ROSTER is passed explicitly so an inherited
# environment cannot redirect the read to a file this script is not writing.
state_of() {
  local out line
  out="$(ROSTER="$ROSTER" "$CHECK" --state 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in
      "${PERSON} ${CORE} "*) line="${line#"${PERSON} ${CORE} "}"; printf '%s' "${line%% *}"; return 0 ;;
    esac
  done <<< "$out"
  printf ''
  return 0
}

if ! before="$(state_of)"; then
  bad "the roster could not be read: ${CHECK} --state refused it, so its own message names the fault"
  finish
fi

case "$before" in
  seated) ok "the roster declares ${CORE} seated for ${PERSON}" ;;
  retired)
    # Idempotent by design: a re-run converges rather than doubling. A grant on
    # a script that appends a row every time it is called is a grant on a file
    # somebody can grow without limit.
    ACTION="already-retired"
    ok "already retired: the last event for ${PERSON} ${CORE} is a retirement, so nothing was appended"
    warn "a live login re-opens this seat at the next check, by design. Retire a seat that has gone, not one that is running."
    finish
    ;;
  "")
    bad "the roster carries no seat for ${PERSON} ${CORE}, so there is nothing to retire -- check the spelling against the roster"
    finish
    ;;
  *)
    bad "the roster reports an unexpected state '${before}' for ${PERSON} ${CORE}"
    finish
    ;;
esac

# ---------------------------------------------------------------- the append

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-retire"
  say "  would append: {person: ${PERSON}, core: ${CORE}, event: retired, date: ${TODAY}, by: ${BY}, reason: ${REASON}}"
  warn "dry run: nothing was written"
  finish
fi

# ONE append, one line, one call. Nobody reads this file, alters it, and writes
# it back, so a concurrent check run cannot lose a row to this one.
printf '  - {person: %s, core: %s, event: retired, date: %s, by: %s, reason: %s}\n' \
  "$PERSON" "$CORE" "$TODAY" "$BY" "$REASON" >> "$ROSTER"
ACTION="retired"

# ---------------------------------------------------------------- read back

# The write is not the evidence. A line that appends fine and then fails the
# roster's own grammar would leave the claw with an unreadable declaration and
# this script reporting success.
after="$(state_of)" || {
  bad "the roster no longer parses after the append -- the appended line is the last one in ${ROSTER}"
  finish
}
if [ "$after" = "retired" ]; then
  ok "read back: ${CHECK} --state now reports ${PERSON} ${CORE} retired"
else
  bad "read back: the roster reports '${after:-nothing}' for ${PERSON} ${CORE}, not retired"
fi

warn "a live login re-opens this seat at the next check, by design. Retire a seat that has gone, not one that is running."
warn "the earlier events for this seat stay in the roster above the retirement; the file is its own audit trail."

finish
