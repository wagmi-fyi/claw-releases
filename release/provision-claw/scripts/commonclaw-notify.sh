#!/bin/bash
#
# commonclaw-notify.sh — post one claw health message to a Slack channel.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh and invoked there
# by the other payload scripts, never by an agent. Its consumers are Slack and
# the journal.
#
#   commonclaw-notify.sh --class seat-expiry --level warn --summary "TEXT"
#   commonclaw-notify.sh --class backup-health --summary "TEXT" --detail "LINE" --detail "LINE"
#   producer | commonclaw-notify.sh --class update-health --summary "TEXT" --stdin
#   commonclaw-notify.sh --dry-run --class seat-fault --summary "TEXT"
#
# WHAT THIS IS FOR. A claw's checks already find what they were built to find.
# They write it to the journal, and on a machine nobody logs into that is the
# same as not finding it. This script is the delivery path. It is an incoming
# webhook and nothing else: no bot, no app scopes, no identity mapping, no
# session hosting. A message goes out; nothing comes back.
#
# THE WEBHOOK URL IS A CREDENTIAL AND IT NEVER RESTS ON THIS CLAW. Anyone
# holding it can post into the channel as this claw. It is resolved at
# invocation, from one of three sources, in this order:
#
#   environment   COMMONCLAW_SLACK_WEBHOOK is already set, because the caller
#                 re-executed itself under `op run` and the value is in its
#                 process environment. commonclaw-backup.sh works this way.
#   conf-command  WEBHOOK_CMD in the notify conf is run and its stdout taken.
#                 Same shape as FETCH_TOKEN_CMD in updater.conf: how a claw
#                 proves itself is pluggable, and the answer changes nothing
#                 else here.
#   manager       the op:// reference in the notify env-file is resolved with
#                 `op read`, under a service-account token taken from the
#                 systemd credential when running under a unit, or decrypted
#                 from the claw's own encrypted credential when running under
#                 cron as root.
#
# THE CONF CARRIES NO LITERAL URL AND THIS SCRIPT READS NONE. A literal in
# /etc/commonclaw would be a credential at rest, in a directory the backup rail
# copies off the box, on a claw whose whole credential posture is that exactly
# one secret rests here and it is encrypted to this host. An escape hatch for
# "the claw with no manager" is an escape hatch that gets used.
#
# THE RESOLVED VALUE IS SHAPE-CHECKED BEFORE IT IS POSTED TO. A reference that
# was mistyped resolves to some OTHER secret, and posting that to a third party
# turns a typo into a disclosure. The value must carry the webhook prefix, and
# it is never printed, logged, or passed on a command line -- /proc/PID/cmdline
# is world-readable and this claw is deliberately multi-user, so the URL goes to
# curl through a 0600 config file instead of an argument.
#
# EXIT CODES, AND THEY ARE THE POINT. A producer calls this and must not fail
# because delivery did.
#
#   0  delivered. In --dry-run, rendered AND the webhook resolved.
#   1  the message was built and delivery failed. Slack refused it, or the
#      network did. The claw is fine; the channel did not hear about it.
#   2  usage error. The caller is wrong, not the claw.
#   3  no webhook. Either notifications are not configured on this claw, or
#      they are configured and could not be resolved. These are different
#      findings and they log at different levels; both refuse to post.
#
#   1 and 3 are deliberately not the same code. "Slack said no" sends a reader
#   to the app config. "Nothing resolved" sends them to the manager. A single
#   failure code would send them to both and prove neither.
#
# WHO WATCHES THIS. Nothing. A notifier that fails writes to the journal, which
# is the surface it exists to replace, and that is a real hole rather than an
# oversight. It is bounded on purpose: the failure is loud in the journal, the
# next run of the producer tries again, and the alternative is a second delivery
# path with the same problem one layer out. Stated here so nobody discovers it
# during an incident.
#
# PROVE IT CAN FAIL BEFORE YOU TRUST IT. Every branch below has a control, and
# the controls live with the unit that built them, never in this directory.
#
#   Class control: --dry-run every class and require the rendered payloads to
#   DIFFER. One class rendering is not evidence the table is read; a table read
#   for its title and ignored for its icon renders identically for every row.
#
#   Refusal control: a resolved value that fails the shape check must exit 3 and
#   must NOT reach the transport. Assert on the transport being un-called, not
#   on the exit code alone -- a script that posts and then exits 3 passes an
#   exit-code test and has already leaked.
#
#   Transport control: a stub that exits non-zero must give exit 1, and the same
#   input with the stub exiting 0 must give exit 0. One verdict proves nothing.
#
#   Dedupe control: the same key twice inside the window must post once, and the
#   same key with the window elapsed must post twice. A dedupe that suppresses
#   everything passes the first half.
#
# THE OVERRIDES BELOW EXIST FOR THOSE CONTROLS. NOTIFY_CONF, NOTIFY_ENV,
# NOTIFY_STATE_DIR, PROVISION_CONF, COMMONCLAW_CLAW and NOTIFY_TRANSPORT point
# this script at fixtures instead of the claw's own files. Cron and the units
# set none of them. NOTIFY_NOW is the clock, for the same reason.
#
set -uo pipefail

# ------------------------------------------------------------------ defaults
NOTIFY_CONF="${NOTIFY_CONF:-/etc/commonclaw/notify.conf}"
NOTIFY_ENV="${NOTIFY_ENV:-/etc/commonclaw/notify.env}"
NOTIFY_STATE_DIR="${NOTIFY_STATE_DIR:-/var/lib/commonclaw/notify}"
PROVISION_CONF="${PROVISION_CONF:-/etc/commonclaw/provision.conf}"
CRED_FILE_DEFAULT="/etc/commonclaw/credentials/op-service-account.cred"

# Slack's own limit on a section block is 3000 characters. Truncating at 2400
# leaves room for the fence, the header and the truncation notice, so a long
# detail block degrades into a short one plus a pointer instead of a rejected
# post. A message Slack refuses for length is a message nobody reads.
DETAIL_CHAR_CAP=2400
DETAIL_LINE_CAP=40
POST_TIMEOUT=15

# ------------------------------------------------------------------ the table
#
# ONE table, and it is the only place that knows how a class reads. A producer
# names a class and says nothing about presentation, so a change to how seat
# findings look is one edit here rather than one edit per producer.
#
# An unknown class is a USAGE ERROR, not a default. A typo'd class rendered
# under a generic heading posts a message that looks fine and is filed under
# the wrong topic, which is worse than a caller that fails loudly at wire time.
#
#   class            title                     default level
class_title() {
  case "$1" in
    seat-expiry)   printf 'seat expiry' ;;
    seat-fault)    printf 'seat fault' ;;
    backup-health) printf 'backup rail' ;;
    update-health) printf 'release rail' ;;
    memory-pressure) printf 'memory pressure' ;;
    claw-note)     printf 'note' ;;
    *) return 1 ;;
  esac
}
class_default_level() {
  case "$1" in
    seat-expiry)   printf 'warn' ;;
    seat-fault)    printf 'warn' ;;
    backup-health) printf 'warn' ;;
    update-health) printf 'info' ;;
    memory-pressure) printf 'warn' ;;
    claw-note)     printf 'info' ;;
    *) return 1 ;;
  esac
}

# Urgency is ONE axis and the icon carries it. Topic is the other and the title
# carries it. Crossing them -- a per-class icon that also has to mean severity --
# gives a table where a warning and an error look the same because they share a
# class, which is the one distinction a person scanning a channel needs.
level_icon() {
  case "$1" in
    info) printf ':information_source:' ;;
    warn) printf ':warning:' ;;
    err)  printf ':rotating_light:' ;;
  esac
}

# ------------------------------------------------------------------ arguments
CLASS=""; LEVEL=""; SUMMARY=""; DRY_RUN=0; READ_STDIN=0
DEDUPE_KEY=""; DEDUPE_HOURS=20
DETAILS=()

usage() { printf 'usage: %s --class CLASS --summary TEXT [--level LEVEL] [--detail LINE]... [--stdin] [--dedupe-key K [--dedupe-hours N]] [--dry-run]\n' "$0" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --class)         CLASS="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --level)         LEVEL="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --summary)       SUMMARY="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --detail)        DETAILS+=("${2:-}"); shift 2 || { usage; exit 2; } ;;
    --stdin)         READ_STDIN=1; shift ;;
    --dedupe-key)    DEDUPE_KEY="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --dedupe-hours)  DEDUPE_HOURS="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

log() { logger -t commonclaw-notify -p "user.$1" -- "$2" 2>/dev/null || true; printf '[%s] %s\n' "$1" "$2" >&2; }

[ -n "$CLASS" ]   || { printf 'a message needs a --class\n' >&2; usage; exit 2; }
[ -n "$SUMMARY" ] || { printf 'a message needs a --summary\n' >&2; usage; exit 2; }

TITLE="$(class_title "$CLASS")" || { printf 'unknown class: %s\n' "$CLASS" >&2; usage; exit 2; }
[ -n "$LEVEL" ] || LEVEL="$(class_default_level "$CLASS")"
case "$LEVEL" in info|warn|err) : ;; *) printf 'level is info, warn or err, not %s\n' "$LEVEL" >&2; exit 2 ;; esac
case "$DEDUPE_HOURS" in ''|*[!0-9]*) printf 'dedupe-hours is a whole number of hours\n' >&2; exit 2 ;; esac
[ -n "$DEDUPE_KEY" ] || [ "$DEDUPE_HOURS" = 20 ] || { printf '--dedupe-hours needs a --dedupe-key to apply to\n' >&2; exit 2; }

if [ "$READ_STDIN" -eq 1 ]; then
  while IFS= read -r line; do DETAILS+=("$line"); done
fi

command -v jq >/dev/null 2>&1 || { log err "jq is not installed, so no message could be built"; exit 3; }

# ------------------------------------------------------------------ the conf
#
# Three states, and they are not the same finding.
#
#   absent   this claw has no notification rail. Normal, and quiet: a claw
#            nobody wired must not write an error into its own journal every
#            morning, because that trains a reader to skip the tag.
#   off      somebody decided. Exit 0, because a producer that treats a
#            deliberate silence as a delivery failure will grow a workaround.
#   on       configured. From here, a failure to resolve is a real fault and
#            it is loud.
#
ENABLED="yes"
WEBHOOK_CMD=""
WEBHOOK_PREFIX="https://hooks.slack.com/services/"
CRED_FILE="$CRED_FILE_DEFAULT"
CONF_PRESENT=0
NOT_CONFIGURED=0
if [ -e "$NOTIFY_CONF" ]; then
  [ -r "$NOTIFY_CONF" ] || { log err "the notify conf at ${NOTIFY_CONF} cannot be read, so nothing was delivered"; exit 3; }

  # Checked BEFORE the source, so a literal never enters this process at all. A
  # literal in the conf is refused rather than ignored: ignoring it would leave
  # somebody believing the rail is wired while every message goes nowhere, and
  # would leave the secret sitting in /etc, in the backups, unnoticed. This says
  # so at the one moment somebody is looking.
  if grep -qE '^[[:space:]]*WEBHOOK_URL=' "$NOTIFY_CONF" 2>/dev/null; then
    log err "${NOTIFY_CONF} carries a literal WEBHOOK_URL. A webhook is a credential and none rests on this claw. Put it in the manager, reference it from ${NOTIFY_ENV}, and remove the line -- then rotate the webhook, because it has been on disk and in the backups"
    exit 3
  fi

  CONF_PRESENT=1
  # shellcheck disable=SC1090
  . "$NOTIFY_CONF"
fi

case "$ENABLED" in
  yes|no) : ;;
  *) log err "ENABLED in ${NOTIFY_CONF} is yes or no, not '${ENABLED}'"; exit 3 ;;
esac

# THE CONF IS WHAT DECLARES THE RAIL EXISTS, and its absence is handled here
# rather than at resolution, so the answer does not depend on what happens to be
# in the environment. A claw with no conf and an inherited variable would
# otherwise deliver from one caller and not from another, which is the hardest
# kind of wiring bug to see.
[ "$CONF_PRESENT" -eq 1 ] || NOT_CONFIGURED=1

if [ "$ENABLED" = "no" ]; then
  log notice "notifications are turned off on this claw, so this ${CLASS} message was not delivered"
  exit 0
fi

# The claw's own name. Sourced, not guessed: the hostname and the name the fleet
# calls this box by are allowed to differ, and the channel reads the fleet name.
if [ -r "$PROVISION_CONF" ]; then
  # shellcheck disable=SC1090
  . "$PROVISION_CONF"
fi
CLAW="${COMMONCLAW_CLAW:-${BOX_HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown-claw')}}"

# ------------------------------------------------------------------ the message
#
# Details go inside a fence. Two reasons, and the second is the one that matters:
# Slack leaves fenced text alone, so a warning that happens to contain an
# underscore or an angle bracket arrives as it was written; and detail text comes
# from whatever a check found, which means it is not trusted to be markup.
# Backticks are stripped because a fence cannot contain its own delimiter.
detail_block=""
if [ "${#DETAILS[@]}" -gt 0 ]; then
  n=0; chars=0; dropped=0
  for d in "${DETAILS[@]}"; do
    d="${d//\`/\'}"
    if [ "$n" -ge "$DETAIL_LINE_CAP" ] || [ $(( chars + ${#d} + 1 )) -gt "$DETAIL_CHAR_CAP" ]; then
      dropped=$((dropped+1)); continue
    fi
    detail_block="${detail_block}${d}"$'\n'
    chars=$(( chars + ${#d} + 1 )); n=$((n+1))
  done
  # A truncation that says nothing reads as a complete list. It names where the
  # rest is, because the rest is genuinely still there.
  [ "$dropped" -eq 0 ] || detail_block="${detail_block}... ${dropped} more line(s); the full finding is in the journal on ${CLAW}"$'\n'
fi

WHEN="${NOTIFY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
ICON="$(level_icon "$LEVEL")"
FALLBACK="${CLAW} · ${TITLE} · ${SUMMARY}"

# jq builds the JSON. Quoting a webhook payload by hand in shell is how a
# warning containing a quote becomes a malformed post that Slack rejects with a
# message about JSON, sending the reader to the transport instead of the check.
PAYLOAD="$(
  jq -n \
    --arg fallback "$FALLBACK" \
    --arg head "${ICON} *${CLAW} · ${TITLE}*"$'\n'"${SUMMARY}" \
    --arg detail "$detail_block" \
    --arg context "${CLASS} · ${LEVEL} · ${WHEN}" \
    '{
       text: $fallback,
       blocks: (
         [ {type:"section", text:{type:"mrkdwn", text:$head}} ]
         + (if ($detail | length) > 0
            then [ {type:"section", text:{type:"mrkdwn", text:("```\n" + $detail + "```")}} ]
            else [] end)
         + [ {type:"context", elements:[{type:"mrkdwn", text:$context}]} ]
       )
     }'
)" || { log err "could not build the ${CLASS} payload"; exit 1; }

# ------------------------------------------------------------------ the dedupe
#
# A fault that persists is reported every time its producer runs. The updater
# runs hourly and the backup rail every six hours, so a stuck repository posts
# four times a day forever and the channel learns to skip the tag.
#
# The key is the caller's choice and that is the whole control surface. Put the
# changing part of the message in the key and every change breaks through; leave
# it out and the class is quiet for the window. This suppresses on the KEY, not
# on the message text: a seat warning whose day count falls by one every morning
# is the same finding, and it should not defeat its own dedupe.
#
# FAILS OPEN. An unwritable state directory posts the message rather than
# swallowing it. The cost of the open direction is a duplicate; the cost of the
# closed direction is the silence this whole script exists to end.
dedupe_stamp=""; SUPPRESSED=0
if [ -n "$DEDUPE_KEY" ]; then
  case "$DEDUPE_KEY" in
    ""|*[!a-zA-Z0-9._-]*) log err "a dedupe key is letters, digits, dot, underscore and dash, not '${DEDUPE_KEY}'"; exit 2 ;;
  esac
  dedupe_stamp="${NOTIFY_STATE_DIR}/${DEDUPE_KEY}"
  now_s="${NOTIFY_NOW_EPOCH:-$(date +%s)}"
  window=$(( DEDUPE_HOURS * 3600 ))
  if [ -r "$dedupe_stamp" ]; then
    last="$(cat "$dedupe_stamp" 2>/dev/null)"
    case "$last" in
      ''|*[!0-9]*) last="" ;;
    esac
    # A stamp from the future is a clock that moved and is treated as no stamp.
    # Trusting it would silence the class until the future caught up.
    if [ -n "$last" ] && [ "$last" -le "$now_s" ] && [ $(( now_s - last )) -lt "$window" ]; then
      SUPPRESSED=1
      # A rehearsal must show the verdict it is rehearsing. Exiting here would
      # print no payload and read as a render failure.
      if [ "$DRY_RUN" -eq 0 ]; then
        log info "suppressed: ${CLASS} under key ${DEDUPE_KEY}, $(( now_s - last ))s since the last one, window ${DEDUPE_HOURS}h"
        exit 0
      fi
    fi
  fi
fi

# ------------------------------------------------------------------ the webhook
#
# Each source names itself in SOURCE, and a --dry-run prints that name. Knowing
# WHICH source answered is the difference between "the manager is reachable" and
# "some environment variable was already set", and those two claws are debugged
# in different places.
WEBHOOK=""; SOURCE=""; WHY=""

resolve_webhook() {
  local v=""

  if [ "$NOT_CONFIGURED" -eq 1 ]; then
    WHY="notifications are not configured on this claw (${NOTIFY_CONF} is absent)"
    return 1
  fi

  if [ -n "${COMMONCLAW_SLACK_WEBHOOK:-}" ]; then
    WEBHOOK="$COMMONCLAW_SLACK_WEBHOOK"; SOURCE="environment"; return 0
  fi

  if [ -n "$WEBHOOK_CMD" ]; then
    # The command's stderr goes to ours so a failure says why. Its stdout is the
    # secret and is captured, never echoed.
    if v="$(eval "$WEBHOOK_CMD" 2>/dev/null)" && [ -n "$v" ]; then
      WEBHOOK="$v"; SOURCE="conf-command"; return 0
    fi
    WHY="WEBHOOK_CMD in ${NOTIFY_CONF} produced nothing"
    return 1
  fi

  if [ ! -r "$NOTIFY_ENV" ]; then
    WHY="no WEBHOOK_CMD in ${NOTIFY_CONF} and no reference file at ${NOTIFY_ENV}"
    return 1
  fi

  local ref
  ref="$(grep -m1 -E '^[[:space:]]*COMMONCLAW_SLACK_WEBHOOK=op://' "$NOTIFY_ENV" 2>/dev/null | sed 's/^[[:space:]]*COMMONCLAW_SLACK_WEBHOOK=//')"
  if [ -z "$ref" ]; then
    WHY="${NOTIFY_ENV} carries no COMMONCLAW_SLACK_WEBHOOK op:// reference"
    return 1
  fi

  command -v op >/dev/null 2>&1 || { WHY="the manager CLI is not installed, so ${NOTIFY_ENV} cannot be resolved"; return 1; }

  # The token, from whichever plane is running us. Under a unit systemd has
  # already decrypted it. Under cron there is no unit, and root decrypts the
  # claw's own credential itself -- the same file, the same host key, one layer
  # lower. Without both, this script would work from the backup timer and fail
  # from the seat check, which is the caller that needed it first.
  local tok=""
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    tok="$OP_SERVICE_ACCOUNT_TOKEN"
  elif [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -r "${CREDENTIALS_DIRECTORY}/op-service-account" ]; then
    tok="$(cat "${CREDENTIALS_DIRECTORY}/op-service-account")"
  elif [ -r "$CRED_FILE" ] && command -v systemd-creds >/dev/null 2>&1; then
    tok="$(systemd-creds decrypt --name=op-service-account "$CRED_FILE" - 2>/dev/null)" || tok=""
  fi
  if [ -z "$tok" ]; then
    WHY="no service-account token reached this process, so ${NOTIFY_ENV} could not be resolved"
    return 1
  fi

  if v="$(OP_SERVICE_ACCOUNT_TOKEN="$tok" op read "$ref" 2>/dev/null)" && [ -n "$v" ]; then
    WEBHOOK="$v"; SOURCE="manager"; return 0
  fi
  WHY="the manager did not return a value for the reference in ${NOTIFY_ENV}"
  return 1
}

resolve_webhook || true

# The shape check. It runs on whatever came back, from whichever source, before
# anything is sent anywhere. A reference pointing at the wrong item resolves to a
# real secret, and a POST to an unknown host would hand it over.
if [ -n "$WEBHOOK" ]; then
  WEBHOOK="${WEBHOOK%%$'\n'*}"
  case "$WEBHOOK" in
    *[[:space:]]*) WEBHOOK=""; WHY="the value ${SOURCE} returned contains whitespace, so it is not a webhook URL. It is not printed" ;;
    "${WEBHOOK_PREFIX}"?*) : ;;
    *) WEBHOOK=""; WHY="the value ${SOURCE} returned does not carry the prefix ${WEBHOOK_PREFIX}, so nothing was posted. The value is not printed" ;;
  esac
  [ -n "$WEBHOOK" ] || SOURCE=""
fi

# ------------------------------------------------------------------ dry run
if [ "$DRY_RUN" -eq 1 ]; then
  printf -- '--- commonclaw-notify --dry-run ---\n'
  printf 'claw:    %s\n' "$CLAW"
  printf 'class:   %s\n' "$CLASS"
  printf 'level:   %s\n' "$LEVEL"
  printf 'title:   %s\n' "$TITLE"
  if [ -n "$DEDUPE_KEY" ]; then
    printf 'dedupe:  key %s, window %sh, stamp %s\n' "$DEDUPE_KEY" "$DEDUPE_HOURS" "$dedupe_stamp"
  else
    printf 'dedupe:  none\n'
  fi
  if [ "$SUPPRESSED" -eq 1 ]; then
    printf 'verdict: SUPPRESSED by the dedupe window; nothing would be posted\n'
  elif [ -n "$WEBHOOK" ]; then
    printf 'webhook: resolved from %s (not printed)\n' "$SOURCE"
    printf 'verdict: would post\n'
  else
    printf 'webhook: NOT RESOLVED -- %s\n' "${WHY:-no source was configured}"
    printf 'verdict: would NOT post\n'
  fi
  printf 'payload:\n%s\n' "$PAYLOAD"
  # A rehearsal that says the message is fine while the credential is missing is
  # the wiring bug this script exists to catch, so the exit code carries it. A
  # suppressed message is a working rail and exits 0.
  [ "$SUPPRESSED" -eq 1 ] && exit 0
  [ -n "$WEBHOOK" ] || exit 3
  exit 0
fi

if [ -z "$WEBHOOK" ]; then
  if [ "$NOT_CONFIGURED" -eq 1 ]; then
    # A claw nobody wired must not write an error into its own journal every
    # morning. That trains a reader to skip the tag, which is how the finding
    # this rail carries got lost in the first place.
    log notice "notifications are not configured on this claw, so this ${CLASS} message was not delivered"
  else
    log err "no Slack webhook resolved, so this ${CLASS} message was not delivered: ${WHY:-no source was configured}"
  fi
  exit 3
fi

# ------------------------------------------------------------------ transport
#
# NOTIFY_TRANSPORT replaces curl for a control: it is run with the URL as $1 and
# the payload on stdin, and its exit status becomes the delivery verdict. The
# controls stub it rather than posting, because a test that reaches Slack is a
# test that needs Slack to be up, an app to exist, and somebody to read what it
# posted.
post_with_curl() {
  local url="$1" cfg body code rc
  # The URL never becomes an argument. /proc/PID/cmdline is world-readable and
  # this claw has other unix users on it by design.
  cfg="$(umask 077; mktemp)" || { log err "could not create a request config"; return 1; }
  body="$(umask 077; mktemp)" || { rm -f "$cfg"; log err "could not create a response buffer"; return 1; }
  printf 'url = "%s"\n' "$url" > "$cfg"
  code="$(printf '%s' "$PAYLOAD" | curl -sS -m "$POST_TIMEOUT" -K "$cfg" \
            -X POST -H 'Content-type: application/json' --data-binary @- \
            -o "$body" -w '%{http_code}' 2>>"$body")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log err "the post did not complete (curl exit ${rc}): $(tr -d '\n' < "$body" | cut -c1-200)"
    rm -f "$cfg" "$body"; return 1
  fi
  case "$code" in
    2*) rm -f "$cfg" "$body"; return 0 ;;
    # Slack answers a bad webhook in the body, not only the code, and the body
    # is what says which of "the app is gone" and "the channel is gone" it is.
    *)  log err "Slack refused the ${CLASS} message with HTTP ${code}: $(tr -d '\n' < "$body" | cut -c1-200)"
        rm -f "$cfg" "$body"; return 1 ;;
  esac
}

if [ -n "${NOTIFY_TRANSPORT:-}" ]; then
  printf '%s' "$PAYLOAD" | "$NOTIFY_TRANSPORT" "$WEBHOOK"
  post_rc=$?
else
  post_with_curl "$WEBHOOK"
  post_rc=$?
fi

if [ "$post_rc" -ne 0 ]; then
  exit 1
fi

# The stamp is written only after a delivery that SUCCEEDED. A stamp written on
# the attempt would suppress the retry of a message that never arrived, which is
# the dedupe silencing the exact case it must not.
if [ -n "$dedupe_stamp" ]; then
  # `install -d -m` APPLIES THE MODE TO A DIRECTORY THAT ALREADY EXISTS, so this
  # line owned the mode of a root three components now write under, and it reset
  # it on every delivered note. Provisioning declares 0755 there; this took it to
  # 0700 and the next provisioning run put it back, so the mode oscillated with
  # the traffic. Measured on staging across three applies on 2026-09-02. The
  # guard is the idiom the other call sites here already use: create it when it
  # is absent, and never re-mode somebody else's directory.
  if { [ -d "$NOTIFY_STATE_DIR" ] || install -d -m 0700 "$NOTIFY_STATE_DIR" 2>/dev/null; } \
     && printf '%s\n' "${NOTIFY_NOW_EPOCH:-$(date +%s)}" > "$dedupe_stamp" 2>/dev/null; then
    :
  else
    log warning "delivered, but the dedupe stamp at ${dedupe_stamp} did not write, so this message will repeat"
  fi
fi

log info "delivered ${CLASS} (${LEVEL}) via ${SOURCE}"
exit 0
