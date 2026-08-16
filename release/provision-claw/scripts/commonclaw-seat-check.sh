#!/bin/bash
#
# commonclaw-seat-check.sh — warn before a core login lapses.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh and invoked there
# by cron, never by an agent. Its consumer is cron and syslog.
#
# A subscription login expires. An unattended session stops when its login
# lapses, and only a human re-login fixes it. This check is that alarm.
#
# It reads EXPIRY FIELDS ONLY. It never reads, prints, or logs a token value.
#
# Exit 0 = every expected seat healthy. Exit 1 = at least one warning.
#
# TWO MODES, AND THE ROSTER DECIDES WHICH.
#
#   NO ROSTER — expectation is inferred from a core's DIRECTORY, which
#   provisioning creates for every person. Every claw behaved this way before a
#   roster existed and any claw without one still does, unchanged.
#
#   ROSTER — expectation is DECLARED. Inference conflates "the software is
#   installed" with "a seat is expected", so a firm that deliberately seats one
#   core warns forever on the other, every morning, until nobody reads the
#   warnings at all. A declaration cannot make that mistake.
#
# THE ROSTER IS THE OPT-IN, AND THIS SCRIPT NEVER CREATES IT. Provisioning
# seeds it. A check that created its own roster would migrate every claw into
# declared mode on the first morning after a login, silently, with nobody
# deciding.
#
# THE RATCHET. The two drift directions have asymmetric costs, so they are
# handled asymmetrically:
#
#   ADDING is automatic. An observed live login appends its own row, so the
#   person logging in IS the bookkeeping and infrastructure that newly depends
#   on a seat is covered without anyone remembering to declare it.
#
#   REMOVING is manual, and it is not this script's. A retired seat and a
#   destroyed seat look identical from here, so removing on absence would
#   recreate exactly the blindness this check exists to prevent. A claw-admin
#   retires a row, with a reason, through its own operation.
#
# This script only ever APPENDS to the roster. It never edits and never removes.
#
# PROVE IT CAN FAIL BEFORE YOU TRUST IT. A check whose failure branch is
# unreachable is decoration, and its pass is an unexamined claim.
#
#   Threshold control: run clean, then run with WARN_DAYS far in the future.
#   The two must produce DIFFERENT output. Matching on "some warning appeared"
#   is not enough -- before anyone logs in, the only warning available comes
#   from the not-active branch, so a forced run looks like it proved the
#   threshold branch when that branch never executed.
#
#   Not-active control: run before anyone has authenticated
#                                          -> must warn for every seat.
#
#   Roster control: a declared row whose seat is absent must WARN, and the same
#   input with that row retired must be SILENT. One verdict proves nothing;
#   the two must differ.
#
# The threshold control needs a live login and cannot run before one exists.
# The not-active control is only cheap before one exists. So they belong at
# opposite ends of a build, and neither substitutes for the other.
#
# ROSTER and WARN_DAYS are environment overrides so a control can point this
# script at a fixture instead of the claw's own file. Cron sets neither.
#
# --state prints the folded roster and stops: no observation, no append, no
# other effect. It exists so that NOTHING ELSE ON THE CLAW PARSES THIS FILE.
# The grammar has one reader, and every other consumer -- the retire operation,
# the member-plane readout -- asks that reader instead of keeping a second copy
# of the rules to drift from it.
#
#   roster: present | absent
#   <person> <core> <event> <date> <by> [reason...]      one line per pair
#
# Exit 0 when the roster was read, 1 when it does not parse.
#
set -uo pipefail

MODE="check"
case "${1:-}" in
  "") : ;;
  --state) MODE="state" ;;
  -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

WARN_DAYS="${WARN_DAYS:-14}"
ROSTER="${ROSTER:-/etc/commonclaw/seats.yaml}"
now="$(date +%s)"
today="$(date -I)"
rc=0
seats=0        # no-roster mode: core directories found
checked=0      # roster mode: pairs either declared seated or observed live

# ONE list, two uses: the directories scanned below and the core names the
# roster accepts. A roster naming a core this script cannot check would be a
# declaration nothing reads.
CORES="claude codex"

is_unix_name() { case "$1" in [a-z_]*) : ;; *) return 1 ;; esac; case "$1" in *[!a-z0-9_-]*) return 1 ;; esac; }
emit() { logger -t commonclaw-seat-check -p user.warning -- "$1"; printf 'WARN %s\n' "$1"; rc=1; }
note() { logger -t commonclaw-seat-check -p user.notice  -- "$1"; printf 'NOTE %s\n' "$1"; }

# ---------------------------------------------------------------- the roster
#
# A STRICT subset of YAML, and strict on purpose. A parser that skipped what it
# did not understand would read a damaged roster as an empty one, drop every
# expectation it carries, and report a claw healthy on the strength of having
# understood nothing.
#
#   seats:
#     - {person: NAME, core: CORE, event: seated,  date: YYYY-MM-DD, by: WHO}
#     - {person: NAME, core: CORE, event: retired, date: YYYY-MM-DD, by: WHO, reason: free text}
#
# An APPEND-ONLY EVENT LOG, not a table of rows that get edited. The current
# expectation for a person and core is its LAST event. Three things follow, and
# each is why the shape was chosen:
#
#   - A retired row keeps its reason and its date instead of vanishing, so the
#     file is its own audit trail rather than a file with a convention attached.
#   - Neither writer ever reads-modifies-writes a root-owned file in /etc, so a
#     cron run and a claw-admin retire cannot truncate one another.
#   - Reopening a seat is one more append, not an edit.
#
# `reason` is free text and is therefore LAST: everything between it and the
# closing brace belongs to it.

declare -A SEAT_STATE=()    # "person/core" -> seated | retired, the LAST event
declare -A SEAT_DETAIL=()   # "person/core" -> "<date> <by> [reason...]" of that event
ROSTER_PRESENT=0

parse_roster() {
  local file="$1"
  local lineno=0 line stripped body key val pair
  local in_seats=0 entries=0

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    line="${line%$'\r'}"
    stripped="${line#"${line%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    [ -z "$stripped" ] && continue
    case "$stripped" in \#*) continue ;; esac

    if [ "$stripped" = "seats:" ] && [ "$line" = "seats:" ]; then in_seats=1; continue; fi
    if [ "$in_seats" -eq 0 ]; then
      printf 'roster line %s: content before the seats: key\n' "$lineno" >&2; return 1
    fi

    case "$line" in
      "  - {"*"}") : ;;
      *) printf 'roster line %s: not a seat entry\n' "$lineno" >&2; return 1 ;;
    esac
    body="${stripped#- \{}"; body="${body%\}}"

    local person="" core="" event="" edate="" by="" reason=""
    # The fields are read in a fixed order. `reason` swallows the remainder,
    # which is what lets it carry a comma without a quoting rule nobody would
    # remember when writing one by hand. This script validates it and does not
    # store it: the reason is written for a person reading the file, and for
    # the operation that shows the roster.
    # Bounded. Every path below shortens `body`, so the bound is unreachable by
    # construction today -- and it is here anyway, because the failure it stops
    # is a root cron job spinning silently every morning forever, and the cost
    # of stopping it is one comparison.
    local fields=0
    while [ -n "$body" ]; do
      fields=$((fields+1))
      if [ "$fields" -gt 16 ]; then
        printf 'roster line %s: the parser did not converge -- refusing to spin\n' "$lineno" >&2; return 1
      fi
      case "$body" in
        *:*) : ;;
        *) printf 'roster line %s: trailing text is not a key: value pair\n' "$lineno" >&2; return 1 ;;
      esac
      key="${body%%:*}"
      key="${key#"${key%%[![:space:]]*}"}"
      val="${body#*:}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [ "$key" = "reason" ]; then
        body=""
      else
        case "$val" in
          *", "*) body="${val#*, }"; val="${val%%, *}" ;;
          *) body="" ;;
        esac
      fi
      case "$key" in
        person) person="$val" ;;
        core)   core="$val" ;;
        event)  event="$val" ;;
        date)   edate="$val" ;;
        by)     by="$val" ;;
        reason) reason="$val" ;;
        *) printf 'roster line %s: unknown key %s\n' "$lineno" "$key" >&2; return 1 ;;
      esac
    done

    # Two patterns each, and the negative one is what decides. A case pattern is
    # ANCHORED AT BOTH ENDS, so `[a-z_][a-z0-9_-]*` reads as a class followed by
    # ANYTHING -- its trailing star is not "more of the same class". Measured
    # 2026-08-11: that form validates the first two characters and nothing after,
    # so a roster line naming `ab; touch /tmp/x` parsed as a person. This is the
    # grammar's only reader, so a name it accepts is a name every consumer
    # believes in.
    is_unix_name "$person" || { printf 'roster line %s: person is not a unix name\n' "$lineno" >&2; return 1; }
    is_unix_name "$by"     || { printf 'roster line %s: by is not a name\n' "$lineno" >&2; return 1; }
    case " ${CORES} " in *" ${core} "*) : ;; *) printf 'roster line %s: unknown core %s\n' "$lineno" "$core" >&2; return 1 ;; esac
    case "$event"  in seated|retired) : ;; *) printf 'roster line %s: event is seated or retired\n' "$lineno" >&2; return 1 ;; esac
    case "$edate"  in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;; *) printf 'roster line %s: date is not YYYY-MM-DD\n' "$lineno" >&2; return 1 ;; esac

    pair="${person}/${core}"
    SEAT_STATE["$pair"]="$event"
    SEAT_DETAIL["$pair"]="${edate} ${by}${reason:+ ${reason}}"
    entries=$((entries+1))
  done < "$file"

  [ "$in_seats" -eq 1 ] || { printf 'roster carries no seats: key\n' >&2; return 1; }
  return 0
}

# A roster that is present and unusable is its own finding, and it is LOUD.
# Falling back to inference here would quietly restore the behaviour the roster
# replaced, on the one claw whose declaration is known to be damaged -- a check
# that demotes itself on bad input and still exits zero cannot fail.
roster_fault() {
  # In state mode this is a query and the caller reads the exit status. In
  # check mode it is a finding about the claw and belongs in the journal.
  if [ "$MODE" = "state" ]; then printf '%s\n' "$1" >&2; exit 1; fi
  emit "$1"
  exit "$rc"
}

if [ -e "$ROSTER" ]; then
  ROSTER_PRESENT=1
  [ -r "$ROSTER" ] || \
    roster_fault "the seat roster at ${ROSTER} cannot be read, so no expectation could be established"
  parse_roster "$ROSTER" || \
    roster_fault "the seat roster at ${ROSTER} does not parse, so no seat was checked -- repair the file"
fi

if [ "$MODE" = "state" ]; then
  if [ "$ROSTER_PRESENT" -eq 1 ]; then printf 'roster: present\n'; else printf 'roster: absent\n'; fi
  for pair in "${!SEAT_STATE[@]}"; do
    printf '%s %s %s %s\n' "${pair%%/*}" "${pair##*/}" "${SEAT_STATE["$pair"]}" "${SEAT_DETAIL["$pair"]}"
  done
  exit 0
fi

# ---------------------------------------------------------------- observation
#
# What the claw can see about one person and one core, right now. Keyed on the
# core's DIRECTORY for the scan, because provisioning creates it for everybody:
# keying the scan on a credentials file would hide the person who never logged
# in, since that file appears only at first login.
#
# Echoes "<state> <days>". days is empty unless a live seat carries an expiry.

probe_seat() {
  local user="$1" core="$2" home="$3" cred exp
  case "$core" in
    claude)
      # --- the persistent-session core: the refresh token is the durable one ---
      cred="${home}/.claude/.credentials.json"
      if [ ! -r "$cred" ]; then printf 'not-active '; return 0; fi
      exp="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$cred" 2>/dev/null || true)"
      [ -n "$exp" ] || { printf 'no-expiry '; return 0; }
      # A field that is present but not a number is its own answer. Arithmetic
      # on it silently yields zero and reports a seat expiring twenty thousand
      # days ago, which sends a reader to the wrong place entirely.
      case "$exp" in *[!0-9]*) printf 'bad-expiry '; return 0 ;; esac
      printf 'active %s' "$(( (exp / 1000 - now) / 86400 ))"
      ;;
    codex)
      # --- the per-task core: READ THE STATE, never start the core ---
      #
      # This branch used to ask the core itself, as the member and with -H, which
      # started a core process inside their real home every time the check ran.
      # It was armed for everybody rather than for seat-holders, because the scan
      # keys on the core's directory and provisioning creates that directory for
      # every person, so somebody who never seated this core was walked into
      # anyway. The daily cron entry paid the same price every morning.
      #
      # The state is a file, so it is read as a file, by root, exactly like the
      # branch above. Nothing executes in anybody's home and the verdict is
      # unchanged.
      cred="${home}/.codex/auth.json"
      if [ ! -r "$cred" ]; then printf 'not-active '; return 0; fi
      # Either credential is a live seat, which is what the core's own status
      # string reported: a subscription seat carries a refresh token, an API-key
      # seat carries a key. PRESENCE ONLY -- no value is read, printed or logged,
      # which is the rule stated at the top of this file.
      if [ -n "$(jq -r '.tokens.refresh_token // empty' "$cred" 2>/dev/null || true)" ] ||
         [ -n "$(jq -r '.OPENAI_API_KEY // empty' "$cred" 2>/dev/null || true)" ]; then
        printf 'active '
      else
        printf 'not-active '
      fi
      ;;
  esac
}

# One APPEND, one line, written by a single call. Two writers touch this file
# and neither holds a lock, so nobody may read it, alter it, and write it back.
ratchet() {
  local user="$1" core="$2"
  printf '  - {person: %s, core: %s, event: seated, date: %s, by: seat-check}\n' \
    "$user" "$core" "$today" >> "$ROSTER" || {
      emit "could not append ${user} ${core} to the roster at ${ROSTER}"
      return 0
    }
  SEAT_STATE["${user}/${core}"]="seated"
  note "rostered ${core} for ${user} on first observation of a live seat"
}

declare -A SEEN=()

for home in /home/*; do
  [ -d "$home" ] || continue
  user="$(basename "$home")"
  id "$user" >/dev/null 2>&1 || continue

  for core in $CORES; do
    [ -d "${home}/.${core}" ] || continue
    SEEN["${user}/${core}"]=1

    read -r state days <<< "$(probe_seat "$user" "$core" "$home")"

    if [ "$ROSTER_PRESENT" -eq 0 ]; then
      # Inference. Every core directory is a seat this claw expects.
      seats=$((seats+1))
      case "$state" in
        active)
          if [ -n "$days" ] && [ "$days" -lt "$WARN_DAYS" ]; then
            emit "${core} login for ${user} expires in ${days}d (threshold ${WARN_DAYS}d)"
          fi
          ;;
        no-expiry)  emit "${core} credentials for ${user} carry no refresh-expiry field" ;;
        bad-expiry) emit "${core} credentials for ${user} carry an unreadable refresh-expiry field" ;;
        *)          emit "${core} login for ${user} is not active" ;;
      esac
      continue
    fi

    # Declaration. The roster says what this claw expects; the directory says
    # only what is installed.
    declared="${SEAT_STATE["${user}/${core}"]:-}"

    if [ "$state" = "active" ]; then
      checked=$((checked+1))
      [ "$declared" = "seated" ] || ratchet "$user" "$core"
      if [ -n "$days" ] && [ "$days" -lt "$WARN_DAYS" ]; then
        emit "${core} login for ${user} expires in ${days}d (threshold ${WARN_DAYS}d)"
      fi
      continue
    fi

    # Not live. Only a DECLARED seat is a finding; an undeclared core is the
    # deliberately-unseated state and costs nothing.
    [ "$declared" = "seated" ] || continue
    checked=$((checked+1))
    case "$state" in
      no-expiry)  emit "${core} credentials for ${user} carry no refresh-expiry field" ;;
      bad-expiry) emit "${core} credentials for ${user} carry an unreadable refresh-expiry field" ;;
      *)          emit "${core} login for ${user} is not active" ;;
    esac
  done
done

# A declared seat whose directory the scan never reached is invisible to the
# loop above and is exactly the case a roster exists to catch: the account or
# the seat was removed and the declaration was not. Both answers point at the
# same act -- retire the row -- and they send a reader to different places, so
# they are not collapsed into one message.
if [ "$ROSTER_PRESENT" -eq 1 ]; then
  for pair in "${!SEAT_STATE[@]}"; do
    [ "${SEAT_STATE["$pair"]}" = "seated" ] || continue
    [ -z "${SEEN["$pair"]:-}" ] || continue
    checked=$((checked+1))
    p_user="${pair%%/*}"; p_core="${pair##*/}"
    if id "$p_user" >/dev/null 2>&1; then
      emit "${p_core} seat for ${p_user} is declared and the seat is gone"
    else
      emit "${p_core} seat for ${p_user} is declared and there is no such account"
    fi
  done
fi

# Finding nothing to check is not the same as everything being healthy.
if [ "$ROSTER_PRESENT" -eq 1 ]; then
  if [ "$checked" -eq 0 ]; then
    emit "no seat is declared or observed on this claw -- nothing was checked"
  fi
elif [ "$seats" -eq 0 ]; then
  logger -t commonclaw-seat-check -p user.warning -- "no core logins found on this claw -- nothing was checked"
  printf 'WARN no core logins found on this claw -- nothing was checked\n'
  rc=1
fi

exit "$rc"
