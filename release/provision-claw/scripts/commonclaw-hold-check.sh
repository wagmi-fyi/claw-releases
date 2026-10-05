#!/bin/bash
#
# commonclaw-hold-check.sh: tell a person when the continuity rail holds an
# orchestrator.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh and run by a root
# systemd timer every ten minutes.
#
#   commonclaw-hold-check.sh              the beat. Sends what is due
#   commonclaw-hold-check.sh --state      print each hold and its verdict, send nothing
#   commonclaw-hold-check.sh --dry-run    print what it would send, send nothing
#
# WHAT A HOLD IS. The continuity rail resumes an orchestrator whose session has
# gone and whose inbox has mail. When the harness refuses that resume for any
# reason but a sign-out, the rail holds that one handle, tries it again once an
# hour, and goes on resuming the others. The hold is a field in the rail's state
# file for that handle, under the account's own home.
#
# WHY THIS EXISTS. The rail sends a hold's line to the `human` bus handle.
# Nobody reads `human`, and the stall check skips it on purpose. So a held
# orchestrator reached nobody until somebody ran the rail's --check by hand.
#
# WHY ROOT, AND NOT THE RAIL ITSELF. The rail runs as the account. The alert
# channel's webhook resolves only under the machine's service account, whose
# credential that account cannot read. The sign-in check's root half, started
# through a `+` line under User=, did not resolve it on a tenant claw on seven
# tries out of seven, while the stall check's own root unit did. This unit is
# the stall check's shape: root, with the credential loaded by systemd.
#
# WHAT IS READ. For each account with a home, the files in
# <home>/.local/state/commonclaw/continuity. A file is read only when it is a
# regular file, not a link, owned by that account, and under 64 KiB. From a
# hold, four fields are taken: `scope` (or the sign-in word an earlier release
# wrote), `id`, `class` and `cwd`. The handle is the file's own `handle` field.
# The harness's words in `reason` and `said` are never read.
#
# ONE ALERT PER HOLD. The rail gives each hold an `id` and keeps it through
# every retry. This check records the ids it delivered, per account. A retry
# that fails again keeps the id, so it sends nothing new. A hold that heals is
# gone from the state file, and a later hold gets a new id, so it sends again.
# A hold an earlier release wrote has no id, and its `since` stands in.
#
# AN ACCOUNT HOLD SENDS NOTHING HERE. A sign-out holds every handle of the
# account, and the hourly sign-in check already sends one line to the same
# channel and the same kind of address. A second alert for the same cause would
# teach its reader to skip both.
#
# FIXED WORDS ONLY. The line names the claw, the account, the handle, the
# reason class and the fix step. The handle is cut to letters, digits and
# . _ @ + -. The folder is cut to those and /, and is said only when it is an
# absolute path. Nothing the harness wrote reaches a line.
#
# WHERE IT GOES. The notifier, class continuity-hold. And one mail to
# HOLD_ALERT_TO in /etc/commonclaw/email-gatekeeper.conf, through the mail
# service's socket. That key is apart from MAIL_ALERT_TO, because a hold is the
# administrator's maintenance and the mail alarm's address can reach the firm's
# owners. Empty means no mail. A claw with no mail service sends no mail and
# says so in its log.
#
# A HOLD COUNTS AS DELIVERED when either leg delivered. When both fail, the next
# beat tries again.
#
# EXIT CODES. 0 whether or not it found something and whether or not delivery
# worked. This is a timer producer, and a Slack outage must not turn into a
# failed unit. 2 is a usage error.
#
# WHAT WATCHES THIS. Nothing, the same gap the notifier and the stall check
# name.
#
# THE OVERRIDES BELOW EXIST FOR CONTROLS. HOLD_CHECK_ACCOUNTS (a list of
# account=state-dir pairs), HOLD_CHECK_DELIVERED_DIR, HOLD_CHECK_MAIL_CONF,
# HOLD_CHECK_EMAIL_CLI, HOLD_CHECK_LOG_TAG, NOTIFIER, PROVISION_CONF and
# COMMONCLAW_CLAW point this script at fixtures. The timer sets none of them.
# HOLD_CHECK_LOG_TAG is what a suite must set: a fixture run under the live tag
# writes journal lines that read like real alerts.
#
set -uo pipefail

LOG_TAG="${HOLD_CHECK_LOG_TAG:-commonclaw-hold-check}"
NOTIFIER="${NOTIFIER:-/usr/local/sbin/commonclaw-notify.sh}"
MAIL_CONF="${HOLD_CHECK_MAIL_CONF:-/etc/commonclaw/email-gatekeeper.conf}"
EMAIL_CLI="${HOLD_CHECK_EMAIL_CLI:-/opt/commonclaw/bin/email}"
PROVISION_CONF="${PROVISION_CONF:-/etc/commonclaw/provision.conf}"
DELIVERED_DIR="${HOLD_CHECK_DELIVERED_DIR:-/var/lib/commonclaw/hold-check}"
SEND_TIMEOUT=120
MAX_BYTES=65536

MODE="beat"
while [ $# -gt 0 ]; do
  case "$1" in
    --state)   MODE="state"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# The stall check says why the stream is read on fd 3 and why the stderr copy is
# dropped under a unit.
stderr_is_journal() {
  [ -n "${JOURNAL_STREAM:-}" ] || return 1
  local here
  here="$( { stat -Lc '%d:%i' /proc/self/fd/3 2>/dev/null; } 3>&2 )"
  [ -n "$here" ] && [ "$JOURNAL_STREAM" = "$here" ]
}

log() {
  logger -t "$LOG_TAG" -p "user.$1" -- "$2" 2>/dev/null || true
  stderr_is_journal || printf '[%s] %s\n' "$1" "$2" >&2
}

clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9._@+-' '?'; }
clean_path() { printf '%s' "$1" | tr -c 'A-Za-z0-9._@+/-' '?'; }

command -v jq >/dev/null 2>&1 || { log err "jq is not installed, so no hold can be read"; exit 0; }
[ "$(id -u)" = 0 ] || [ -n "${HOLD_CHECK_ACCOUNTS:-}" ] \
  || { log err "the hold check runs as root, because the alert channel resolves only there"; exit 0; }

# ------------------------------------------------------------------ the claw
if [ -r "$PROVISION_CONF" ]; then
  CLAW="$(sed -n 's/^COMMONCLAW_CLAW="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$PROVISION_CONF" 2>/dev/null | tail -1)"
  [ -n "$CLAW" ] || CLAW="$(sed -n 's/^BOX_HOSTNAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$PROVISION_CONF" 2>/dev/null | tail -1)"
fi
CLAW="$(clean "${COMMONCLAW_CLAW:-${CLAW:-$(hostname 2>/dev/null || printf 'this-claw')}}")"

# ------------------------------------------------------------------ the mail leg
#
# The conf is read, never sourced, by the mail check's rule. One address or
# none. MAIL_WHY says in words why no mail goes, for the log and for --state.
TO=""; MAIL_WHY=""
if [ ! -e "$MAIL_CONF" ]; then
  MAIL_WHY="this claw has no mail service, so no hold goes by mail"
elif [ ! -r "$MAIL_CONF" ]; then
  MAIL_WHY="the conf at ${MAIL_CONF} cannot be read, so no hold goes by mail"
else
  conf_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$MAIL_CONF" | tail -1
  }
  enabled="$(conf_get ENABLED | tr '[:upper:]' '[:lower:]')"
  raw="$(conf_get HOLD_ALERT_TO)"
  case "${enabled:-yes}" in
    yes|true|1|on) : ;;
    *) MAIL_WHY="the mail service is turned off in ${MAIL_CONF}, so no hold goes by mail" ;;
  esac
  if [ -z "$MAIL_WHY" ]; then
    case "$raw" in
      '') MAIL_WHY="HOLD_ALERT_TO is empty in ${MAIL_CONF}, so no hold goes by mail" ;;
      *[[:space:]]*|*,*|*\;*|@*|*@|*@*@*) MAIL_WHY="HOLD_ALERT_TO in ${MAIL_CONF} is not one address, so no hold goes by mail" ;;
      *@*) TO="$raw" ;;
      *) MAIL_WHY="HOLD_ALERT_TO in ${MAIL_CONF} is not one address, so no hold goes by mail" ;;
    esac
  fi
  if [ -n "$TO" ] && [ ! -x "$EMAIL_CLI" ]; then
    TO=""; MAIL_WHY="this claw has no mail command at ${EMAIL_CLI}, so no hold goes by mail"
  fi
fi

# ------------------------------------------------------------------ the accounts
#
# account=dir, one per line. Every account with a home, by default. A home
# without the rail's state directory is passed over quietly.
accounts() {
  if [ -n "${HOLD_CHECK_ACCOUNTS:-}" ]; then
    printf '%s\n' $HOLD_CHECK_ACCOUNTS
    return 0
  fi
  getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $6 != "" { print $1 "=" $6 "/.local/state/commonclaw/continuity" }'
}

# ------------------------------------------------------------------ the sweep
#
# One row per handle hold, tab-separated: account, file uid, handle, key, class,
# cwd. jq reads the four fields and nothing else.
ROWS=()
while IFS= read -r pair; do
  acct="${pair%%=*}"; dir="${pair#*=}"
  [ -n "$acct" ] && [ -n "$dir" ] || continue
  [ -d "$dir" ] && [ ! -L "$dir" ] || continue
  uid="$(id -u "$acct" 2>/dev/null)" || continue
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    if [ -L "$f" ] || [ ! -f "$f" ] || [ "$(stat -c '%u' "$f" 2>/dev/null)" != "$uid" ]; then
      log err "a state file of $(clean "$acct") is not a regular file that account owns, so it was not read"
      continue
    fi
    [ "$(stat -c '%s' "$f" 2>/dev/null || printf 0)" -le "$MAX_BYTES" ] || continue
    row="$(head -c "$MAX_BYTES" "$f" | jq -r '
      select(type == "object" and (.hold | type) == "object")
      | .hold as $h
      | (if ($h.scope == "account" or $h.scope == "handle") then $h.scope
         elif $h.signin == "signed-out" then "account" else "handle" end) as $scope
      | select($scope == "handle")
      | [(.handle // "" | tostring),
         ($h.id // $h.since // $h.at // "" | tostring),
         (if $h.class == "untrusted" or (($h.said // "") | tostring) == "Workspace not trusted"
          then "untrusted" else "refused" end),
         ($h.cwd // "" | tostring)] | @tsv' 2>/dev/null)" || continue
    [ -n "$row" ] || continue
    ROWS+=("${acct}"$'\t'"${row}")
  done
done < <(accounts)

if [ "${#ROWS[@]}" -eq 0 ]; then
  [ "$MODE" = beat ] || printf 'no orchestrator is held on its own on %s\n' "$CLAW"
  if [ "$MODE" = beat ] && [ -d "$DELIVERED_DIR" ]; then
    find "$DELIVERED_DIR" -maxdepth 1 -type f -delete 2>/dev/null
  fi
  exit 0
fi

# ------------------------------------------------------------------ the words
#
# words <account> <handle> <class> <cwd> sets LINE, FIX and SUBJECT.
words() {
  local acct handle cls folder
  acct="$(clean "$1")"; handle="$(clean "$2")"; cls="$3"; folder=""
  case "$4" in /?*) folder="$(clean_path "${4:0:200}")" ;; esac
  [ -n "$folder" ] || folder="the folder that handle is registered in"
  if [ "$cls" = untrusted ]; then
    LINE="${handle} on ${CLAW} is held: the continuity rail cannot resume it, because the harness does not trust its folder."
    FIX="Run the agent once in ${folder} as ${acct} and accept the trust prompt."
  else
    LINE="${handle} on ${CLAW} is held: the continuity rail cannot resume it, because the harness refused the resume."
    FIX="Run the agent once in ${folder} as ${acct} to read the refusal, and fix what it names."
  fi
  FIX="${FIX} The rail tries it again within the hour, and every other orchestrator of ${acct} is resumed as usual."
  SUBJECT="${handle} on ${CLAW} is held by the continuity rail"
}

delivered_file() { printf '%s/%s' "$DELIVERED_DIR" "$(clean "$1")"; }
was_delivered() { grep -qxF -- "$(clean "$2")"$'\t'"$(clean "$3")" "$(delivered_file "$1")" 2>/dev/null; }

# ------------------------------------------------------------------ state and dry run
if [ "$MODE" != beat ]; then
  if [ -n "$TO" ]; then printf 'hold mail: to the address in HOLD_ALERT_TO\n'; else printf 'hold mail: none, because %s\n' "$MAIL_WHY"; fi
  for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r acct handle key cls cwd <<< "$r"
    words "$acct" "$handle" "$cls" "$cwd"
    if was_delivered "$acct" "$handle" "$key"; then verdict="quiet, because this hold was already sent"; else verdict="due"; fi
    printf '%s (%s): %s, %s\n' "$(clean "$handle")" "$(clean "$acct")" "$cls" "$verdict"
    if [ "$MODE" = dry-run ] && [ "$verdict" = due ]; then
      printf '  channel: %s %s\n' "$LINE" "$FIX"
      [ -n "$TO" ] && printf '  mail subject: %s\n' "$SUBJECT"
    fi
  done
  exit 0
fi

# ------------------------------------------------------------------ delivery
#
# The record of what was sent is rewritten per account each beat, from the holds
# present now. A hold that healed drops out of it.
declare -A KEEP=()
for r in "${ROWS[@]}"; do
  IFS=$'\t' read -r acct handle key cls cwd <<< "$r"
  entry="$(clean "$handle")"$'\t'"$(clean "$key")"
  if was_delivered "$acct" "$handle" "$key"; then
    KEEP["$(clean "$acct")"]+="${entry}"$'\n'
    continue
  fi
  words "$acct" "$handle" "$cls" "$cwd"
  sent=0
  if [ -x "$NOTIFIER" ]; then
    nrc=0
    "$NOTIFIER" --class continuity-hold --summary "$LINE" --detail "$FIX" >/dev/null 2>&1 || nrc=$?
    if [ "$nrc" -eq 0 ]; then sent=1; else log notice "the notifier exited ${nrc}, so the channel did not take the hold of $(clean "$handle")"; fi
  else
    log notice "no notifier at ${NOTIFIER}, so the hold of $(clean "$handle") did not reach the channel"
  fi
  if [ -n "$TO" ]; then
    mrc=0
    EMAIL_GATEKEEPER_CONF="$MAIL_CONF" timeout "$SEND_TIMEOUT" "$EMAIL_CLI" send \
      --to "$TO" --subject "$SUBJECT" --body "${LINE}"$'\n\n'"${FIX}" --handle hold-check >/dev/null 2>&1 || mrc=$?
    if [ "$mrc" -eq 0 ]; then sent=1; else log err "the hold of $(clean "$handle") could not be mailed (email send exited ${mrc})"; fi
  else
    log notice "$MAIL_WHY"
  fi
  if [ "$sent" -eq 1 ]; then
    KEEP["$(clean "$acct")"]+="${entry}"$'\n'
    log warning "${LINE} ${FIX}"
  else
    log err "the hold of $(clean "$handle") reached nobody and is tried again at the next beat"
  fi
done

install -d -m 0755 "$DELIVERED_DIR" 2>/dev/null
for f in "$DELIVERED_DIR"/*; do
  [ -f "$f" ] || continue
  a="$(basename "$f")"
  [ -n "${KEEP[$a]+x}" ] || rm -f "$f"
done
for acct in "${!KEEP[@]}"; do
  out="${DELIVERED_DIR}/${acct}"
  printf '%s' "${KEEP[$acct]}" > "${out}.tmp" && mv -f "${out}.tmp" "$out" \
    || log warning "${out} did not write, so a hold of $(clean "$acct") may be sent again"
done

exit 0
