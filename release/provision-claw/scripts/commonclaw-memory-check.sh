#!/bin/bash
#
# commonclaw-memory-check.sh
#
# Say out loud when this claw is running out of memory, and tell an off-box
# watcher that it is still alive.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh and started there
# by its own timer, never by an agent. Its consumers are the notifier, the
# heartbeat service, and the journal.
#
#   commonclaw-memory-check.sh
#
# WHAT THIS IS FOR. On 2026-09-01 a claw's memory filled. The box thrashed, ssh
# could not log in for half an hour, and nothing told anybody. Two things were
# missing and this script is both of them.
#
#   THE ON-BOX ALARM. Available memory and swap use are read every few minutes.
#   When either crosses a line the finding goes to the channel through
#   commonclaw-notify.sh, under the class `memory-pressure`.
#
#   THE DEAD-MAN PING. Every healthy run makes one request to a heartbeat check
#   off this box. The check alarms when the requests stop. That is the half an
#   on-box alarm cannot do: a box that is thrashing, off, or gone posts nothing,
#   and silence from an on-box rail is indistinguishable from health.
#
# THE PING MEANS "UP AND NOT SHORT OF MEMORY", and it is skipped on a run that
# found pressure. So a claw under sustained pressure alarms twice: once from the
# channel, once from the heartbeat's grace expiring. That is deliberate. The
# failure this closes is the one where the box got too busy to tell anybody.
#
# THE HEARTBEAT URL IS A CREDENTIAL. Whoever holds it can silence the alarm by
# pinging it themselves. It is handled the way the webhook is: a manager
# reference in the env file, resolved at invocation, shape-checked before use,
# never printed, never logged, and never a command-line argument, because
# /proc/PID/cmdline is world-readable and this claw has other people's accounts
# on it by design.
#
# UNWIRED IS QUIET, ON BOTH LEGS. A claw with no heartbeat reference skips the
# ping and still runs the alarm. A claw with no notifier installed still pings.
# Neither absence is an error, because a claw nobody wired must not write an
# error into its own journal every few minutes: that trains a reader to skip the
# tag, which is how the finding this rail carries got lost in the first place.
#
# EXIT CODES.
#
#   0  the beat ran. It found pressure and posted, or it found none and pinged,
#      or notifications are deliberately turned off on this claw.
#   1  the beat could not read memory at all. Nothing was measured.
#   2  usage error. The caller is wrong, not the claw.
#   3  no conf. This claw has no memory rail, which is the quiet state.
#
#   A failed post and a failed ping are NOT failures of this script. The
#   notifier's exit code is its own health signal and a channel outage must not
#   read as a memory fault. A failed ping is reported through the notifier as a
#   note, because a broken heartbeat that nobody hears about is a second silence.
#
# PROVE IT CAN FAIL BEFORE YOU TRUST IT. The controls live with the unit that
# built them, in `_workpapers/w129-memory-rail/memory-controls.sh`, never in this
# directory: provisioning copies `scripts/` onto every claw inside the sudo
# grant's own prefix, so a harness left here ships to the fleet.
#
# THE OVERRIDES BELOW EXIST FOR THOSE CONTROLS. MEMORY_CONF, MEMORY_ENV,
# MEMINFO_PATH, NOTIFIER, PING_TRANSPORT, PROVISION_CONF and CRED_FILE point this
# script at fixtures instead of the claw's own files. The timer sets none of them.
#
set -uo pipefail

MEMORY_CONF="${MEMORY_CONF:-/etc/commonclaw/memory.conf}"
MEMORY_ENV="${MEMORY_ENV:-/etc/commonclaw/memory.env}"
MEMINFO_PATH="${MEMINFO_PATH:-/proc/meminfo}"
NOTIFIER="${NOTIFIER:-/usr/local/sbin/commonclaw-notify.sh}"
PROVISION_CONF="${PROVISION_CONF:-/etc/commonclaw/provision.conf}"
CRED_FILE="${CRED_FILE:-/etc/commonclaw/credentials/op-service-account.cred}"
PING_TIMEOUT=10

[ $# -eq 0 ] || {
  case "${1:-}" in
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'this check takes no arguments; it reads %s\n' "$MEMORY_CONF" >&2; exit 2 ;;
  esac
}

log() { logger -t commonclaw-memory-check -p "user.$1" -- "$2" 2>/dev/null || true; printf '[%s] %s\n' "$1" "$2" >&2; }

# ------------------------------------------------------------------ the conf
#
# Three states, the same three the notifier has, for the same reason.
#
#   absent   this claw has no memory rail. Quiet, exit 3.
#   off      somebody decided. Exit 0.
#   on       configured. From here a fault is loud.
ENABLED="yes"
AVAILABLE_PCT=15
SWAP_USED_PCT=50
DEDUPE_HOURS=6
HEARTBEAT_PREFIX="https://"

if [ ! -e "$MEMORY_CONF" ]; then
  log notice "no memory rail on this claw (${MEMORY_CONF} is absent), so nothing was measured"
  exit 3
fi
[ -r "$MEMORY_CONF" ] || { log err "the memory conf at ${MEMORY_CONF} cannot be read"; exit 3; }

# Checked BEFORE the source, so a literal never enters this process. The same
# refusal the notifier makes about a webhook, for the same reason: a value that
# reached /etc/commonclaw is in the backups and stays in the snapshots after the
# file is deleted.
if grep -qE '^[[:space:]]*COMMONCLAW_HEARTBEAT_URL=' "$MEMORY_CONF" 2>/dev/null; then
  log err "${MEMORY_CONF} carries a literal heartbeat URL. It is a credential and none rests on this claw. Put it in the manager, reference it from ${MEMORY_ENV}, remove the line, and then replace the check, because the URL has been on disk and in the backups"
  exit 3
fi

# shellcheck disable=SC1090
. "$MEMORY_CONF"

case "$ENABLED" in
  yes) : ;;
  no)  log notice "the memory rail is turned off on this claw, so nothing was measured"; exit 0 ;;
  *)   log err "ENABLED in ${MEMORY_CONF} is yes or no, not '${ENABLED}'"; exit 3 ;;
esac

whole_number() {
  case "$2" in
    ''|*[!0-9]*) log err "${1} in ${MEMORY_CONF} is a whole number, not '${2}'"; exit 3 ;;
  esac
}
whole_number AVAILABLE_PCT "$AVAILABLE_PCT"
whole_number SWAP_USED_PCT "$SWAP_USED_PCT"
whole_number DEDUPE_HOURS  "$DEDUPE_HOURS"

# The claw's own name, sourced rather than guessed: the hostname and the name the
# fleet calls this box by are allowed to differ, and the channel reads the fleet
# name. Same read the notifier makes.
if [ -r "$PROVISION_CONF" ]; then
  # shellcheck disable=SC1090
  . "$PROVISION_CONF"
fi
CLAW="${COMMONCLAW_CLAW:-${BOX_HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown-claw')}}"

# ------------------------------------------------------------------ the reading
[ -r "$MEMINFO_PATH" ] || { log err "cannot read ${MEMINFO_PATH}, so this claw's memory was not measured at all"; exit 1; }

meminfo_kb() { sed -n "s/^${1}:[[:space:]]*\([0-9]\+\) kB\$/\1/p" "$MEMINFO_PATH" | head -1; }

MEM_TOTAL="$(meminfo_kb MemTotal)"
MEM_AVAIL="$(meminfo_kb MemAvailable)"
SWAP_TOTAL="$(meminfo_kb SwapTotal)"
SWAP_FREE="$(meminfo_kb SwapFree)"

# MemTotal is the one field nothing works without: it is the denominator of the
# only percentage that decides anything. A missing or zero value would make every
# comparison below read as healthy, which is the reading that measures nothing.
case "${MEM_TOTAL:-0}" in
  ''|0|*[!0-9]*) log err "${MEMINFO_PATH} carries no usable MemTotal, so nothing was measured"; exit 1 ;;
esac
case "${MEM_AVAIL:-}" in
  ''|*[!0-9]*) log err "${MEMINFO_PATH} carries no usable MemAvailable, so nothing was measured"; exit 1 ;;
esac
case "${SWAP_TOTAL:-}" in ''|*[!0-9]*) SWAP_TOTAL=0 ;; esac
case "${SWAP_FREE:-}"  in ''|*[!0-9]*) SWAP_FREE=0  ;; esac

AVAIL_PCT=$(( MEM_AVAIL * 100 / MEM_TOTAL ))
if [ "$SWAP_TOTAL" -gt 0 ]; then
  SWAP_PCT=$(( (SWAP_TOTAL - SWAP_FREE) * 100 / SWAP_TOTAL ))
else
  SWAP_PCT=0
fi

mem_crossed=0; swap_crossed=0
[ "$AVAIL_PCT" -lt "$AVAILABLE_PCT" ] && mem_crossed=1
[ "$SWAP_TOTAL" -gt 0 ] && [ "$SWAP_PCT" -gt "$SWAP_USED_PCT" ] && swap_crossed=1

# ------------------------------------------------------------------ the post
#
# The key carries WHICH line was crossed, so a box that was short of memory and
# then also filled its swap posts a second time rather than being suppressed as
# the same finding. The stall rail's key carries its handle set for the same
# reason.
notify() {
  local class="$1" level="$2" key="$3" summary="$4"; shift 4
  [ -x "$NOTIFIER" ] || { log notice "no notifier at ${NOTIFIER}, so this ${class} finding stayed in the journal"; return 0; }
  local args=(--class "$class" --level "$level" --summary "$summary"
              --dedupe-key "$key" --dedupe-hours "$DEDUPE_HOURS")
  local d
  for d in "$@"; do args+=(--detail "$d"); done
  "$NOTIFIER" "${args[@]}" >/dev/null 2>&1 || true
}

mb() { printf '%s' $(( $1 / 1024 )); }

if [ "$mem_crossed" -eq 1 ] || [ "$swap_crossed" -eq 1 ]; then
  kind="mem-swap"
  [ "$swap_crossed" -eq 1 ] || kind="mem"
  [ "$mem_crossed"  -eq 1 ] || kind="swap"

  finding="${AVAIL_PCT}% of memory available"
  [ "$SWAP_TOTAL" -gt 0 ] && finding="${finding}, ${SWAP_PCT}% of swap in use"
  log warning "memory pressure on ${CLAW}: ${finding}"

  details=("available memory $(mb "$MEM_AVAIL") MB of $(mb "$MEM_TOTAL") MB, ${AVAIL_PCT}%, line at ${AVAILABLE_PCT}%")
  if [ "$SWAP_TOTAL" -gt 0 ]; then
    details+=("swap in use $(mb $(( SWAP_TOTAL - SWAP_FREE )) ) MB of $(mb "$SWAP_TOTAL") MB, ${SWAP_PCT}%, line at ${SWAP_USED_PCT}%")
  else
    details+=("this claw has no swap, so there is no cushion under the pressure above")
  fi
  details+=("the OOM guard kills the largest process before the box stops answering ssh; it has not necessarily acted yet")

  notify memory-pressure warn "memory-pressure-${kind}" \
    "${CLAW} is short of memory: ${finding}" "${details[@]}"
  exit 0
fi

# ------------------------------------------------------------------ the ping
#
# Only on a healthy run. The heartbeat means "up and not short of memory", so a
# box under pressure stops pinging and the off-box check says so on its own.
log info "memory is fine on ${CLAW}: ${AVAIL_PCT}% available, ${SWAP_PCT}% of swap in use"

resolve_heartbeat() {
  local ref tok v
  if [ -n "${COMMONCLAW_HEARTBEAT_URL:-}" ]; then
    HEARTBEAT="$COMMONCLAW_HEARTBEAT_URL"; SOURCE="environment"; return 0
  fi
  [ -r "$MEMORY_ENV" ] || { WHY="no reference file at ${MEMORY_ENV}"; return 1; }
  ref="$(grep -m1 -E '^[[:space:]]*COMMONCLAW_HEARTBEAT_URL=op://' "$MEMORY_ENV" 2>/dev/null | sed 's/^[[:space:]]*COMMONCLAW_HEARTBEAT_URL=//')"
  [ -n "$ref" ] || { WHY="${MEMORY_ENV} carries no COMMONCLAW_HEARTBEAT_URL op:// reference"; return 1; }
  command -v op >/dev/null 2>&1 || { WHY="the manager CLI is not installed, so ${MEMORY_ENV} cannot be resolved"; return 1; }

  # The token, from whichever plane is running us. Under the timer's unit systemd
  # has already decrypted it. Under a hand run as root there is no unit, and root
  # decrypts the claw's own credential itself. The notifier resolves the same two
  # ways for the same reason.
  tok=""
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    tok="$OP_SERVICE_ACCOUNT_TOKEN"
  elif [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -r "${CREDENTIALS_DIRECTORY}/op-service-account" ]; then
    tok="$(cat "${CREDENTIALS_DIRECTORY}/op-service-account")"
  elif [ -r "$CRED_FILE" ] && command -v systemd-creds >/dev/null 2>&1; then
    tok="$(systemd-creds decrypt --name=op-service-account "$CRED_FILE" - 2>/dev/null)" || tok=""
  fi
  [ -n "$tok" ] || { WHY="no service-account token reached this process, so ${MEMORY_ENV} could not be resolved"; return 1; }

  if v="$(OP_SERVICE_ACCOUNT_TOKEN="$tok" op read "$ref" 2>/dev/null)" && [ -n "$v" ]; then
    HEARTBEAT="$v"; SOURCE="manager"; return 0
  fi
  WHY="the manager did not return a value for the reference in ${MEMORY_ENV}"
  return 1
}

HEARTBEAT=""; SOURCE=""; WHY=""
resolve_heartbeat || true

# The shape check, on whatever came back, before anything leaves the box. A
# mistyped reference resolves to some OTHER secret in the same vault, and a
# request to whatever came back would hand it to a stranger. The value is never
# printed.
if [ -n "$HEARTBEAT" ]; then
  HEARTBEAT="${HEARTBEAT%%$'\n'*}"
  case "$HEARTBEAT" in
    *[[:space:]]*) HEARTBEAT=""; WHY="the value ${SOURCE} returned contains whitespace, so it is not a URL. It is not printed" ;;
    "${HEARTBEAT_PREFIX}"?*) : ;;
    *) HEARTBEAT=""; WHY="the value ${SOURCE} returned does not carry the prefix ${HEARTBEAT_PREFIX}, so nothing was sent. The value is not printed" ;;
  esac
  [ -n "$HEARTBEAT" ] || SOURCE=""
fi

# UNWIRED IS QUIET. A claw with no heartbeat is a claw nobody has wired one for,
# and the alarm above still ran.
if [ -z "$HEARTBEAT" ]; then
  log notice "no heartbeat check wired on this claw, so no ping was sent: ${WHY:-no source was configured}"
  exit 0
fi

ping_with_curl() {
  local url="$1" cfg rc
  # The URL never becomes an argument, for the reason the notifier's does not.
  cfg="$(umask 077; mktemp)" || { log err "could not create a request config"; return 1; }
  printf 'url = "%s"\n' "$url" > "$cfg"
  curl -fsS -m "$PING_TIMEOUT" -K "$cfg" -o /dev/null 2>/dev/null
  rc=$?
  rm -f "$cfg"
  return "$rc"
}

if [ -n "${PING_TRANSPORT:-}" ]; then
  "$PING_TRANSPORT" "$HEARTBEAT" >/dev/null 2>&1
  ping_rc=$?
else
  ping_with_curl "$HEARTBEAT"
  ping_rc=$?
fi

if [ "$ping_rc" -eq 0 ]; then
  log info "heartbeat pinged, resolved from ${SOURCE}"
  exit 0
fi

# A BROKEN HEARTBEAT MUST NOT BE SILENT EITHER. The off-box check will alarm on
# the missing ping, and that alarm says the box is gone when the box is fine. One
# note through the channel is what tells the reader which of the two it is.
log err "the heartbeat ping failed on a healthy claw (exit ${ping_rc}); the off-box check will alarm as if this box were down"
notify claw-note warn "memory-heartbeat-ping" \
  "${CLAW} is healthy and its heartbeat ping is failing, so the off-box check will alarm as if this claw were down" \
  "the ping was resolved from ${SOURCE} and the request exited ${ping_rc}" \
  "memory is fine here: ${AVAIL_PCT}% available, ${SWAP_PCT}% of swap in use"
exit 0
