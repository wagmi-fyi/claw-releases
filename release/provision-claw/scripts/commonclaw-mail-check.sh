#!/bin/bash
#
# commonclaw-mail-check.sh: tell a named person when mail to this claw is not
# being handled.
#
# PAYLOAD SCRIPT. Installed onto the claw by install-email-gatekeeper.sh and run
# by a root systemd timer every five minutes.
#
#   commonclaw-mail-check.sh              the beat. Alerts if it finds late mail
#   commonclaw-mail-check.sh --state      print the finding, send nothing
#   commonclaw-mail-check.sh --dry-run    print what it would send, send nothing
#
# WHAT A MAIL IS HERE. The mail service puts each incoming mail on the bus as a
# message from its own handle, written by its own account. A mail is handled
# once the inbox cursor of the handle it went to has passed that message. The
# cursor moves when a session reads its inbox. A handle nobody ever registered
# has no cursor, so its mail is unhandled from the moment it arrives. A session
# that read a mail and then stalled is not caught here. The desk's own
# orchestration answers for that.
#
# THREE CONDITIONS, each measured against LATE_MINUTES.
#
#   1  a mail is unhandled and older than the threshold.
#   2  the handle that mail went to has no live session behind it. Reported as
#      a fact beside 1, because it is the usual cause with a long-running
#      session: nobody registered the name, or the session that did has ended.
#   3  the mail service has been disconnected for longer than the threshold.
#      Mail stays at the provider then, and no new mail reaches the bus.
#
# A CLAW WITH NO INBOX IS QUIET. A mail service nobody has wired is the ordinary
# state of a fresh claw, and a service turned off in its conf is a deliberate
# silence. Neither one alerts.
#
# WHERE IT SENDS. The claw's notifier, class mail-late, and one mail to
# MAIL_ALERT_TO through the mail service's own socket. No mail goes when the
# service does not answer on that socket: the notifier is then the only path. A
# service that answers and has lost its provider is still asked to send, and a
# send it refuses is logged.
#
# FIXED WORDS ONLY. An alert carries handle names, counts, ages and the claw's
# own address. It never carries a sender, a subject or any text of a mail. That
# is the stall check's rule, and the reason is the same: the channel and the
# named person are a different audience from a bus inbox. A handle name is cut
# to letters, digits and . _ @ + - before it is printed, so nothing a member
# typed into a handle can reach a shell that quotes the line.
#
# ONE ALERT PER SET OF LATE MAIL. The check keeps the set it last alerted on. A
# beat alerts when the current set holds a mail the last alert did not name, or
# when REMIND_HOURS have passed since the last alert. A beat with nothing late
# forgets the set, so a mail that goes late again is announced again. Both legs
# count as one alert: the set is recorded when either leg delivered.
#
# EXIT CODES. 0 whether or not it found something and whether or not delivery
# worked. This is a timer producer, and a Slack outage must not turn into a
# failed unit. 2 is a usage error.
#
# WHAT WATCHES THIS. Nothing, the same gap the notifier and the stall check
# name. The memory check's outside heartbeat alarms when the whole machine goes
# quiet.
#
# THE OVERRIDES BELOW EXIST FOR CONTROLS. MAIL_CHECK_CONF, MAIL_CHECK_STATE_DIR,
# MAIL_CHECK_NOW_EPOCH, MAIL_CHECK_EMAIL_CLI, MAIL_CHECK_SESSIONS_ROOT,
# MAIL_CHECK_SENDER and NOTIFIER point this script at fixtures. The timer sets
# none of them.
#
set -uo pipefail

MAIL_CONF="${MAIL_CHECK_CONF:-/etc/commonclaw/email-gatekeeper.conf}"
STATE_DIR="${MAIL_CHECK_STATE_DIR:-/var/lib/commonclaw/mail-check}"
EMAIL_CLI="${MAIL_CHECK_EMAIL_CLI:-/opt/commonclaw/bin/email}"
NOTIFIER="${NOTIFIER:-/usr/local/sbin/commonclaw-notify.sh}"
PROVISION_CONF="${PROVISION_CONF:-/etc/commonclaw/provision.conf}"
# The unix account the mail service runs as. The bus records it on every
# message as the sender, and the sender cannot choose it, so a member who types
# the service's handle into a send does not raise an alarm.
SENDER_ACCOUNT="${MAIL_CHECK_SENDER:-email-gate}"
# Empty means each handle owner's own harness records, under their home.
SESSIONS_ROOT="${MAIL_CHECK_SESSIONS_ROOT:-}"
STATUS_TIMEOUT=20
SEND_TIMEOUT=120

# ------------------------------------------------------------------ defaults
# The shipped defaults, the same values the conf template carries.
ENABLED="yes"
BUS_DIR="/var/lib/commonclaw/bus"
BUS_HANDLE="email-gatekeeper"
MAIL_ALERT_TO=""
LATE_MINUTES=60
REMIND_HOURS=24

MODE="beat"
while [ $# -gt 0 ]; do
  case "$1" in
    --state)   MODE="state"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

log() { logger -t commonclaw-mail-check -p "user.$1" -- "$2" 2>/dev/null || true; printf '[%s] %s\n' "$1" "$2" >&2; }

# ------------------------------------------------------------------ the conf
#
# READ, NEVER SOURCED. The mail service reads this file with its own parser, so
# a line that is valid there and not valid shell must not run here. Only the
# keys this check uses are taken, and each is unquoted the way the service
# unquotes it.
if [ -e "$MAIL_CONF" ]; then
  [ -r "$MAIL_CONF" ] || { log err "the conf at ${MAIL_CONF} cannot be read"; exit 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
    case "$key" in
      ENABLED|BUS_DIR|BUS_HANDLE|MAIL_ALERT_TO|LATE_MINUTES|REMIND_HOURS)
        printf -v "$key" '%s' "$val" ;;
    esac
  done < "$MAIL_CONF"
else
  log notice "there is no mail service conf at ${MAIL_CONF}, so there is no mail to watch"
  exit 0
fi

case "$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')" in
  yes|true|1|on) : ;;
  *) log notice "the mail service is turned off in ${MAIL_CONF}, so the mail check has nothing to watch"; exit 0 ;;
esac
case "$LATE_MINUTES" in ''|*[!0-9]*|0) log err "LATE_MINUTES in ${MAIL_CONF} is a whole number of minutes above 0, not '${LATE_MINUTES}'"; exit 0 ;; esac
case "$REMIND_HOURS" in ''|*[!0-9]*|0) log err "REMIND_HOURS in ${MAIL_CONF} is a whole number of hours above 0, not '${REMIND_HOURS}'"; exit 0 ;; esac
[ -n "$BUS_DIR" ] || BUS_DIR="/var/lib/commonclaw/bus"
[ -n "$BUS_HANDLE" ] || BUS_HANDLE="email-gatekeeper"

# One address, no spaces, one @. Anything else is a typo, and a typo here would
# send the alert to somebody nobody chose.
ALERT_TO=""
if [ -n "$MAIL_ALERT_TO" ]; then
  case "$MAIL_ALERT_TO" in
    *[[:space:]]*|*,*|*\;*|@*|*@|*@*@*) log err "MAIL_ALERT_TO in ${MAIL_CONF} is not one address, so no alert goes by mail" ;;
    *@*) ALERT_TO="$MAIL_ALERT_TO" ;;
    *) log err "MAIL_ALERT_TO in ${MAIL_CONF} is not one address, so no alert goes by mail" ;;
  esac
fi

command -v jq >/dev/null 2>&1 || { log err "jq is not installed, so no bus can be read"; exit 0; }

NOW="${MAIL_CHECK_NOW_EPOCH:-$(date +%s)}"
LATE_S=$(( LATE_MINUTES * 60 ))
REMIND_S=$(( REMIND_HOURS * 3600 ))

if [ -r "$PROVISION_CONF" ]; then
  BOX_HOSTNAME="$(sed -n 's/^BOX_HOSTNAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$PROVISION_CONF" 2>/dev/null | tail -1)"
fi
clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9._@+-' '?'; }

CLAW="$(clean "${COMMONCLAW_CLAW:-${BOX_HOSTNAME:-$(hostname 2>/dev/null || printf 'this-claw')}}")"

span() {
  local s="$1" h m
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then printf '%sh %sm' "$h" "$m"; else printf '%sm' "$m"; fi
}

# ------------------------------------------------------------------ the service
#
# SERVICE is one of: connected, disconnected, down, unwired.
SERVICE="down"; ADDRESS=""
status_json=""
if [ -x "$EMAIL_CLI" ]; then
  status_json="$(EMAIL_GATEKEEPER_CONF="$MAIL_CONF" timeout "$STATUS_TIMEOUT" "$EMAIL_CLI" status 2>/dev/null)" || true
fi
if [ -n "$status_json" ] && [ "$(printf '%s' "$status_json" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
  ADDRESS="$(printf '%s' "$status_json" | jq -r '.address // ""' 2>/dev/null)"
  inbox_id="$(printf '%s' "$status_json" | jq -r '.inbox_id // ""' 2>/dev/null)"
  if [ "$(printf '%s' "$status_json" | jq -r '.connected // false' 2>/dev/null)" = true ]; then
    SERVICE="connected"
  elif [ -z "$inbox_id" ]; then
    SERVICE="unwired"
  else
    SERVICE="disconnected"
  fi
fi

if [ "$SERVICE" = unwired ]; then
  [ "$MODE" = beat ] || printf 'the mail service has no inbox yet, so there is no mail to watch\n'
  [ "$MODE" = beat ] && rm -f "${STATE_DIR}/down-since" "${STATE_DIR}/last-alert" 2>/dev/null
  exit 0
fi

# HOW LONG IT HAS BEEN OUT. The service does not say when it lost its
# connection, so the first beat that sees it out records the time. Only the
# beat writes: a rehearsal reads the record and leaves it alone.
OUT_S=0
if [ "$SERVICE" = connected ]; then
  [ "$MODE" = beat ] && rm -f "${STATE_DIR}/down-since" 2>/dev/null
else
  since=""
  [ -r "${STATE_DIR}/down-since" ] && since="$(cat "${STATE_DIR}/down-since" 2>/dev/null)"
  case "$since" in ''|*[!0-9]*) since="" ;; esac
  if [ -n "$since" ] && [ "$since" -gt "$NOW" ]; then since=""; fi
  if [ -z "$since" ]; then
    since="$NOW"
    if [ "$MODE" = beat ]; then
      { [ -d "$STATE_DIR" ] || install -d -m 0700 "$STATE_DIR" 2>/dev/null; } \
        && printf '%s\n' "$since" > "${STATE_DIR}/down-since" 2>/dev/null \
        || log warning "could not record at ${STATE_DIR} when the mail service went out, so its age will not grow"
    fi
  fi
  OUT_S=$(( NOW - since ))
fi

# ------------------------------------------------------------------ liveness
#
# live, gone or unregistered. Empty means nothing was recorded to ask about, and
# the alert then says nothing about the session.
#
# A PID ALONE GOES STALE. A session keeps its id across a resume and comes back
# under a new process, so a handle whose own pid has ended is looked up once
# more in its owner's harness records before it is called gone. That is the bus
# CLI's own rule.
handle_session() {
  local h="$1" rec pid sess owner dir f p
  rec="$(jq -r --arg h "$h" 'if has($h) then "yes\t\(.[$h].pid // "")\t\(.[$h].session // "")\t\(.[$h].owner // "")" else "no" end' \
         "${BUS_DIR}/handles.json" 2>/dev/null)" || rec=""
  case "$rec" in
    no) printf 'unregistered'; return 0 ;;
    yes*) : ;;
    *) printf ''; return 0 ;;
  esac
  IFS=$'\t' read -r _ pid sess owner <<< "$rec"
  case "$pid" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  if [ -d "/proc/${pid}" ]; then printf 'live'; return 0; fi
  if [ -n "$sess" ] && [ -n "$owner" ]; then
    if [ -n "$SESSIONS_ROOT" ]; then
      dir="${SESSIONS_ROOT}/${owner}/sessions"
    else
      dir="$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)/.claude/sessions"
    fi
    for f in "$dir"/*.json; do
      [ -r "$f" ] || continue
      p="$(jq -r --arg s "$sess" 'select(.sessionId == $s) | .pid // empty' "$f" 2>/dev/null)"
      case "$p" in ''|*[!0-9]*) continue ;; esac
      if [ -d "/proc/${p}" ]; then printf 'live'; return 0; fi
    done
  fi
  printf 'gone'
}

# ------------------------------------------------------------------ the sweep
LINES=(); IDS=(); TOTAL=0; OLDEST=0
if [ -d "${BUS_DIR}/inbox" ]; then
  for inbox in "${BUS_DIR}"/inbox/*.jsonl; do
    [ -r "$inbox" ] || continue
    h="$(basename "$inbox" .jsonl)"
    cursor=0
    cfile="${BUS_DIR}/cursors/${h}.cursor"
    if [ -r "$cfile" ]; then
      cursor="$(cat "$cfile" 2>/dev/null)"
      case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    fi
    count=0; oldest=0
    # The grep keeps jq off inboxes the service never wrote to.
    while IFS=$'\t' read -r mid ts; do
      [ -n "$mid" ] || continue
      then_s="$(date -d "$ts" +%s 2>/dev/null)" || continue
      case "$then_s" in ''|*[!0-9]*) continue ;; esac
      age=$(( NOW - then_s ))
      [ "$age" -ge "$LATE_S" ] || continue
      count=$(( count + 1 ))
      [ "$age" -gt "$oldest" ] && oldest="$age"
      IDS+=("$(clean "$h")/$(clean "$mid")")
    done < <(tail -n "+$(( cursor + 1 ))" "$inbox" 2>/dev/null \
               | grep -F -- "$BUS_HANDLE" \
               | jq -rR --arg f "$BUS_HANDLE" --arg s "$SENDER_ACCOUNT" \
                   'fromjson? | select(.from == $f and .sender == $s) | "\(.id // "")\t\(.ts // "")"' 2>/dev/null)
    [ "$count" -gt 0 ] || continue
    TOTAL=$(( TOTAL + count ))
    [ "$oldest" -gt "$OLDEST" ] && OLDEST="$oldest"
    line="${count} went to $(clean "$h"). The oldest has waited $(span "$oldest")."
    case "$(handle_session "$h")" in
      unregistered) line="${line} No session has registered that name, so nobody is reading it." ;;
      gone)         line="${line} The session that registered that name has ended, so nobody is reading it." ;;
    esac
    LINES+=("$line")
  done
fi

OUT_LATE=0
if [ "$SERVICE" != connected ] && [ "$OUT_S" -ge "$LATE_S" ]; then
  OUT_LATE=1
  IDS+=("service/${SERVICE}")
  if [ "$SERVICE" = down ]; then
    LINES+=("The mail service has not answered for $(span "$OUT_S"). No mail can arrive until it runs again, so this alert went to the channel only.")
  else
    LINES+=("The mail service has been disconnected from its provider for $(span "$OUT_S"). Mail stays at the provider while the service is disconnected.")
  fi
fi

if [ "${#IDS[@]}" -eq 0 ]; then
  if [ "$MODE" = beat ]; then
    rm -f "${STATE_DIR}/last-alert" 2>/dev/null
  else
    printf 'no late mail: nothing older than %s minutes is unhandled, and the mail service reads %s\n' "$LATE_MINUTES" "$SERVICE"
  fi
  exit 0
fi

TO_WHAT="this claw"
[ -n "$ADDRESS" ] && TO_WHAT="$(clean "$ADDRESS")"
if [ "$TOTAL" -gt 0 ]; then
  if [ "$TOTAL" -eq 1 ]; then
    SUMMARY="1 mail to ${TO_WHAT} has waited more than ${LATE_MINUTES} minutes and nobody has read it."
  else
    SUMMARY="${TOTAL} mails to ${TO_WHAT} have waited more than ${LATE_MINUTES} minutes and nobody has read them."
  fi
else
  SUMMARY="The mail service on ${CLAW} has been out for more than ${LATE_MINUTES} minutes."
fi

# ------------------------------------------------------------------ the dedupe
CURRENT="$(printf '%s\n' "${IDS[@]}" | sort -u)"
DUE=1; WHY_DUE="nothing was alerted on before"
if [ -r "${STATE_DIR}/last-alert" ]; then
  last_s="$(head -1 "${STATE_DIR}/last-alert" 2>/dev/null)"
  case "$last_s" in ''|*[!0-9]*) last_s="" ;; esac
  if [ -n "$last_s" ] && [ "$last_s" -le "$NOW" ]; then
    new_ids="$(comm -23 <(printf '%s\n' "$CURRENT") <(tail -n +2 "${STATE_DIR}/last-alert" | sort -u))"
    if [ -n "$new_ids" ]; then
      WHY_DUE="the set holds late mail the last alert did not name"
    elif [ $(( NOW - last_s )) -ge "$REMIND_S" ]; then
      WHY_DUE="the last alert was ${REMIND_HOURS} hours or more ago, so this is the reminder"
    else
      DUE=0; WHY_DUE="the same set was alerted on $(span $(( NOW - last_s ))) ago"
    fi
  fi
fi

MAIL_SUBJECT="Mail on ${CLAW} is waiting and nobody is handling it"
MAIL_BODY="$(
  printf '%s\n\n' "$SUMMARY"
  printf '%s\n' "${LINES[@]}"
  printf '\n'
  if [ "$TOTAL" -gt 0 ]; then
    printf 'What to do: on %s, start the session each name above belongs to, usually the email orchestrator, so it reads its inbox. The mail is safe at the provider. Nothing is lost.\n' "$CLAW"
  fi
  if [ "$OUT_LATE" -eq 1 ]; then
    printf 'What to do: on %s, the command email status says why the mail service is out, and systemctl status email-gatekeeper says whether it runs.\n' "$CLAW"
  fi
  printf '\nThis alert repeats every %s hours while the mail stays unread, and a new late mail sends a new one.\n' "$REMIND_HOURS"
  printf 'The mail check on %s sent it. It carries no sender, subject or text of any mail.\n' "$CLAW"
)"
MAIL_LEG=1
[ -n "$ALERT_TO" ] || MAIL_LEG=0
[ "$SERVICE" != down ] || MAIL_LEG=0

if [ "$MODE" = state ]; then
  printf '%s\n' "$SUMMARY"
  printf '  %s\n' "${LINES[@]}"
  if [ "$DUE" -eq 1 ]; then printf 'verdict: would alert, because %s\n' "$WHY_DUE"; else printf 'verdict: quiet, because %s\n' "$WHY_DUE"; fi
  exit 0
fi

if [ "$MODE" = dry-run ]; then
  printf -- '--- commonclaw-mail-check --dry-run ---\n'
  if [ "$DUE" -eq 1 ]; then printf 'verdict: would alert, because %s\n' "$WHY_DUE"; else printf 'verdict: would stay quiet, because %s\n' "$WHY_DUE"; fi
  printf -- '--- the channel ---\n'
  if [ -x "$NOTIFIER" ]; then
    printf '%s\n' "${LINES[@]}" | "$NOTIFIER" --dry-run --class mail-late --level warn --stdin --summary "$SUMMARY" 2>&1 || true
  else
    printf 'the notifier at %s is not installed, so nothing would reach the channel\n' "$NOTIFIER"
  fi
  printf -- '--- the mail ---\n'
  if [ "$MAIL_LEG" -eq 1 ]; then
    printf 'to: %s\nsubject: %s\n\n%s\n' "$ALERT_TO" "$MAIL_SUBJECT" "$MAIL_BODY"
  elif [ -z "$ALERT_TO" ]; then
    printf 'no mail would go: MAIL_ALERT_TO is empty in %s, so the channel is the only path\n' "$MAIL_CONF"
  else
    printf 'no mail would go: the mail service reads %s, so the channel is the only path\n' "$SERVICE"
  fi
  exit 0
fi

if [ "$DUE" -eq 0 ]; then
  log info "late mail unchanged: ${WHY_DUE}"
  exit 0
fi

# ------------------------------------------------------------------ delivery
#
# `|| rc=$?` keeps each leg's number without letting it become this script's.
DELIVERED=0
if [ -x "$NOTIFIER" ]; then
  nrc=0
  printf '%s\n' "${LINES[@]}" | "$NOTIFIER" --class mail-late --level warn --stdin --summary "$SUMMARY" || nrc=$?
  [ "$nrc" -eq 0 ] && DELIVERED=1
else
  log err "the notifier at ${NOTIFIER} is not installed, so the late-mail alert did not reach the channel"
fi

if [ "$MAIL_LEG" -eq 1 ]; then
  mrc=0
  EMAIL_GATEKEEPER_CONF="$MAIL_CONF" timeout "$SEND_TIMEOUT" "$EMAIL_CLI" send \
    --to "$ALERT_TO" --subject "$MAIL_SUBJECT" --body "$MAIL_BODY" --handle mail-check >/dev/null 2>&1 || mrc=$?
  if [ "$mrc" -eq 0 ]; then
    DELIVERED=1
    log info "the late-mail alert was mailed to the address in MAIL_ALERT_TO"
  else
    log err "the late-mail alert could not be mailed (email send exited ${mrc})"
  fi
elif [ -z "$ALERT_TO" ]; then
  log notice "MAIL_ALERT_TO is empty in ${MAIL_CONF}, so the late-mail alert went to the channel only"
fi

if [ "$DELIVERED" -eq 1 ]; then
  if { [ -d "$STATE_DIR" ] || install -d -m 0700 "$STATE_DIR" 2>/dev/null; } \
     && { printf '%s\n' "$NOW"; printf '%s\n' "$CURRENT"; } > "${STATE_DIR}/last-alert" 2>/dev/null; then
    :
  else
    log warning "the alert went out, but ${STATE_DIR}/last-alert did not write, so it will repeat"
  fi
else
  log err "the late-mail alert reached nobody: ${SUMMARY}"
fi

exit 0
