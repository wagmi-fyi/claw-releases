#!/bin/bash
#
# claw-status.sh — read this claw's state from what the caller can reach.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./claw-status.sh
#
# REQUIRED ROLE: member. This script holds no privilege of its own, calls no
# sudo, and changes nothing.
#
# UNREADABLE IS NOT MISSING. A workspace directory is group-owned and closed to
# everyone else, so a caller outside the group cannot traverse it and finds
# nothing inside. Reporting that as an absent manifest turns somebody else's
# healthy workspace into a defect report. Reachability is established first,
# and absence is only claimed from inside a directory the caller can enter.
#
# SEATS ARE THE CALLER'S OWN. Another person's seat state lives in their home
# and stays there. The claw's own seat check covers every seat on its own
# schedule; this readout does not stand in for it.
#
# FINDINGS ARE DATA. The exit status reports whether the readout ran, never
# what it found. A status that goes red on any warning saturates: one accepted
# condition pins it red, and a real one then changes nothing.
#
set -uo pipefail

WORKSPACE_ROOT="/srv/workspaces"
ETC_ROOT="/etc/commonclaw"
CONVENTIONS="${ETC_ROOT}/workspace-conventions.md"
BACKUP_TIMER="commonclaw-backup.timer"
BACKUP_SERVICE="commonclaw-backup.service"
SEAT_CRON="/etc/cron.d/commonclaw-seat-check"
ROLE="claw-admin"

case "${1:-}" in
  "") : ;;
  -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'jq is required and is not installed\n' >&2; exit 1; }

FINDINGS=""
finding() { FINDINGS+="$(jq -cn --arg level "$1" --arg text "$2" '{level:$level,text:$text}')"$'\n'; }

# ---------------------------------------------------------------- the caller

ME="$(id -un)"
HOME_DIR="${HOME:-$(getent passwd "$ME" | awk -F: '{print $6}')}"
GROUPS_TEXT=" $(id -nG 2>/dev/null || true) "

case "$GROUPS_TEXT" in *" ${ROLE} "*) IS_ADMIN=true ;; *) IS_ADMIN=false ;; esac

# The journal and syslog are group-gated. Deriving access from a journalctl
# exit status would not work: an unprivileged caller gets an empty listing and
# a zero exit, so "no access" and "no runs" would read the same.
case "$GROUPS_TEXT" in
  *" systemd-journal "*|*" adm "*) JOURNAL=true ;;
  *) if [ "$(id -u)" -eq 0 ]; then JOURNAL=true; else JOURNAL=false; fi ;;
esac

caller_json="$(jq -n \
  --arg user "$ME" \
  --arg groups "$(id -nG 2>/dev/null || true)" \
  --argjson claw_admin "$IS_ADMIN" \
  --argjson journal "$JOURNAL" \
  '{user:$user, groups:($groups|split(" ")), claw_admin:$claw_admin, journal_readable:$journal}')"

# ---------------------------------------------------------------- workspaces

# A manifest field, read without a pipeline so no reader depends on another
# reader's exit status.
man_get() {
  awk -v k="$1" 'index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v); print v; exit }' "$2"
}

WORKSPACES=""
closed=0

if [ ! -d "$WORKSPACE_ROOT" ]; then
  finding warn "no workspace root at ${WORKSPACE_ROOT}: this machine is not a provisioned claw, or provisioning did not complete"
else
  for dir in "$WORKSPACE_ROOT"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    group="ws-${name}"
    manifest="${dir}/.workspace.yaml"

    # The ladder that keeps a permission wall from reading as a defect.
    if [ ! -x "$dir" ]; then
      state="unreadable"; closed=$((closed + 1))
    elif [ ! -e "$manifest" ]; then
      state="missing"
      finding warn "workspace directory ${name} carries no manifest: unfinished work rather than a workspace"
    elif [ ! -r "$manifest" ]; then
      state="unreadable"; closed=$((closed + 1))
    else
      state="present"
    fi

    m_name=""; m_group=""; m_claw=""; m_created=""; m_channel=""
    if [ "$state" = "present" ]; then
      m_name="$(man_get name "$manifest")"
      m_group="$(man_get group "$manifest")"
      m_claw="$(man_get claw "$manifest")"
      m_created="$(man_get created "$manifest")"
      m_channel="$(man_get channel "$manifest")"
      for f in name group claw created; do
        v="m_${f}"
        [ -n "${!v}" ] || finding warn "workspace ${name}: the manifest carries no ${f}"
      done
      # The group a workspace declares and the group its directory takes from
      # its name are the same group. A divergence means the directory was
      # renamed under the manifest, and the access it grants is no longer the
      # access it declares.
      [ -z "$m_group" ] || [ "$m_group" = "$group" ] || \
        finding warn "workspace ${name}: the manifest declares group ${m_group}, the directory name implies ${group}"
    fi

    # Group rosters are world-readable, so this answers for every workspace
    # including the closed ones. It lists secondary members, which is the whole
    # roster here, because each person's primary group is their own account.
    gline="$(getent group "$group" 2>/dev/null || true)"
    if [ -z "$gline" ]; then
      members=""
      [ "$state" = "unreadable" ] || \
        finding warn "workspace ${name}: no group ${group} exists, so nobody reaches it"
    else
      members="${gline##*:}"
    fi
    case "$GROUPS_TEXT" in *" ${group} "*) mine=true ;; *) mine=false ;; esac

    WORKSPACES+="$(jq -cn \
      --arg name "$name" --arg path "$dir" --arg manifest "$state" \
      --arg group "$group" --arg members "$members" --argjson mine "$mine" \
      --arg m_name "$m_name" --arg m_group "$m_group" --arg m_claw "$m_claw" \
      --arg m_created "$m_created" --arg m_channel "$m_channel" \
      '{name:$name, path:$path, manifest:$manifest, group:$group,
        members: ($members | if . == "" then [] else split(",") end),
        caller_is_member: $mine,
        declared: (if $m_name == "" then null else
          {name:$m_name, group:$m_group, claw:$m_claw, created:$m_created,
           channel: (if $m_channel == "" then null else $m_channel end)} end)}')"$'\n'
  done
  [ "$closed" -eq 0 ] || \
    finding info "${closed} workspace(s) are closed to ${ME}: their state is not observable at this role"
fi

# ---------------------------------------------------------------- the rail

# Unit state is readable without privilege, and it carries the fact that
# matters: when the rail last ran and how it ended.
unit_prop() { systemctl show "$1" -p "$2" --value 2>/dev/null || true; }

if command -v systemctl >/dev/null 2>&1; then RAIL_OBSERVABLE=true; else RAIL_OBSERVABLE=false; fi

timer_load="$(unit_prop "$BACKUP_TIMER" LoadState)"
svc_load="$(unit_prop "$BACKUP_SERVICE" LoadState)"
timer_enabled="$(systemctl is-enabled "$BACKUP_TIMER" 2>/dev/null || true)"
last_trigger="$(unit_prop "$BACKUP_TIMER" LastTriggerUSec)"
next_trigger="$(unit_prop "$BACKUP_TIMER" NextElapseUSecRealtime)"
last_start="$(unit_prop "$BACKUP_SERVICE" ExecMainStartTimestamp)"
last_exit="$(unit_prop "$BACKUP_SERVICE" ExecMainExitTimestamp)"
last_result="$(unit_prop "$BACKUP_SERVICE" Result)"
active="$(unit_prop "$BACKUP_SERVICE" ActiveState)"

if [ "$RAIL_OBSERVABLE" = false ]; then
  # Not observed is not the same as not installed.
  finding info "no systemctl on this machine: the rail's state was not observed"
elif [ "$timer_load" != "loaded" ]; then
  finding warn "the backup rail timer is not installed on this claw: nothing takes work off the machine on a schedule"
else
  [ "$timer_enabled" = "enabled" ] || \
    finding warn "the backup rail timer is installed but not enabled (${timer_enabled:-unknown})"
  case "$last_trigger" in
    ""|"n/a"|0) finding warn "the backup rail has never run" ;;
  esac
fi
case "$last_result" in
  ""|success) : ;;
  *) finding warn "the backup rail's last run ended with result ${last_result}" ;;
esac

rail_json="$(jq -n \
  --arg timer "$BACKUP_TIMER" --arg service "$BACKUP_SERVICE" \
  --arg timer_load "$timer_load" --arg svc_load "$svc_load" \
  --arg enabled "$timer_enabled" --arg last_trigger "$last_trigger" \
  --arg next_trigger "$next_trigger" --arg last_start "$last_start" \
  --arg last_exit "$last_exit" --arg result "$last_result" --arg active "$active" \
  --argjson journal "$JOURNAL" \
  --argjson observable "$RAIL_OBSERVABLE" \
  '{timer:$timer, service:$service, observed:$observable,
    installed:($timer_load=="loaded"),
    service_installed:($svc_load=="loaded"), enabled:$enabled,
    last_trigger:$last_trigger, next_trigger:$next_trigger,
    last_run_start:$last_start, last_run_end:$last_exit,
    last_result:$result, active_state:$active,
    source:"systemd unit state", journal_readable:$journal}')"

# ---------------------------------------------------------------- seats

# The warning threshold belongs to the claw's own seat check. Read it from
# where that check gets it rather than keeping a second copy here.
THRESHOLD=""
if [ -r "$SEAT_CRON" ]; then
  THRESHOLD="$(awk 'match($0, /WARN_DAYS=[0-9]+/) { print substr($0, RSTART + 10, RLENGTH - 10); exit }' "$SEAT_CRON")"
fi
[ -n "$THRESHOLD" ] || finding info "no seat-check threshold found at ${SEAT_CRON}: days remaining are reported without a verdict"

SEATS=""
seat() {
  SEATS+="$(jq -cn --arg core "$1" --arg state "$2" --arg detail "$3" \
    --argjson days "${4:-null}" \
    '{core:$core, state:$state, detail:$detail, days_remaining:$days}')"$'\n'
}

# The persistent-session core. Keyed on the directory, the same way the claw's
# seat check keys it: a seat that was never established is still a seat this
# claw expects, and keying on the credentials file would hide exactly that.
if [ -d "${HOME_DIR}/.claude" ]; then
  cred="${HOME_DIR}/.claude/.credentials.json"
  if [ ! -r "$cred" ]; then
    seat claude not-active "no active login for ${ME}"
    finding warn "claude login for ${ME} is not active"
  else
    # Expiry field only. No token value is read, printed, or logged.
    exp="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$cred" 2>/dev/null || true)"
    case "$exp" in *[!0-9]*) exp="" ;; esac
    if [ -z "$exp" ]; then
      seat claude unknown "credentials carry no refresh-expiry field"
      finding warn "claude credentials for ${ME} carry no refresh-expiry field"
    else
      now="$(date +%s)"
      days=$(( (exp / 1000 - now) / 86400 ))
      seat claude active "expires in ${days}d" "$days"
      if [ -n "$THRESHOLD" ] && [ "$days" -lt "$THRESHOLD" ]; then
        finding warn "claude login for ${ME} expires in ${days}d (threshold ${THRESHOLD}d)"
      fi
    fi
  fi
fi

# The per-task core. Match the output string rather than the exit code, the
# same way the claw's seat check does.
if [ -d "${HOME_DIR}/.codex" ]; then
  codex_bin="$(command -v codex 2>/dev/null || true)"
  [ -n "$codex_bin" ] || { [ -x /usr/local/bin/codex ] && codex_bin=/usr/local/bin/codex; }
  if [ -z "$codex_bin" ]; then
    # Not observed is not the same as not active, and a core is absent from a
    # non-login PATH on a claw.
    seat codex unknown "the codex binary is not on this session's PATH"
    finding info "codex seat for ${ME} was not observed: the binary is not on this session's PATH"
  else
    out="$("$codex_bin" login status </dev/null 2>&1 || true)"
    case "$out" in
      *"Logged in"*) seat codex active "logged in" ;;
      *) seat codex not-active "no active login for ${ME}"
         finding warn "codex login for ${ME} is not active" ;;
    esac
  fi
fi

[ -n "$SEATS" ] || finding info "no core directories in ${HOME_DIR}: this account expects no seat"

# ---------------------------------------------------------------- emit

jq -n \
  --arg host "$(hostname)" \
  --argjson conventions "$([ -r "$CONVENTIONS" ] && echo true || echo false)" \
  --argjson caller "$caller_json" \
  --argjson workspaces "$(printf '%s' "$WORKSPACES" | jq -s .)" \
  --argjson rail "$rail_json" \
  --argjson seats "$(printf '%s' "$SEATS" | jq -s .)" \
  --argjson threshold "${THRESHOLD:-null}" \
  --argjson findings "$(printf '%s' "$FINDINGS" | jq -s .)" \
  '{script:"claw-status", ok:true, claw:$host,
    conventions_readable:$conventions, caller:$caller,
    workspaces:$workspaces, rail:$rail,
    seats:$seats, seat_threshold_days:$threshold,
    findings:$findings}'
