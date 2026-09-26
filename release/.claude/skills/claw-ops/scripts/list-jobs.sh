#!/bin/bash
#
# list-jobs.sh: what is scheduled on this claw, and what this account cannot
# see of it.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./list-jobs.sh
#   ./list-jobs.sh --help
#
# REQUIRED ROLE: member. It reads only what its caller can already reach.
#
# TWO READINGS, AND THE SECOND IS WHAT MAKES THE LIST CLAW-WIDE.
#
#   ENABLED. The caller's own account, through systemctl --user: unit, next
#   run, last result. Only timers whose definition sits under /srv/workspaces
#   are this claw's jobs; a distribution's own timers are counted and left out.
#
#   DECLARED. Every <name>.timer under /srv/workspaces the caller can read,
#   with the project directory holding it.
#
# ANOTHER ACCOUNT'S TIMERS ARE UNREADABLE, NEVER ABSENT. No member can query
# another member's service manager, so for every other account this reports
# what loginctl does answer: whether they linger and whether a manager is
# running.
#
# IS THIS OVER-ENGINEERED? The enabled reading alone would answer "my jobs",
# which is not the list that was asked for. The declared reading is a find over
# one tree. Together they are the claw-wide answer an unprivileged account can
# give.
#
# FINDINGS ARE DATA. The exit status says whether the readout ran, never what
# it found.
#
set -uo pipefail

WORKSPACE_ROOT="/srv/workspaces"
SCAN_DEPTH=6

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

# ------------------------------------------------------- the caller's timers

ENABLED=""
FOREIGN=0

if timers="$(systemctl --user list-timers --all --no-pager --legend=false 2>/dev/null)"; then
  MANAGER=true
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    frag="$(systemctl --user show "$unit" -p FragmentPath --value 2>/dev/null || true)"
    src="$(readlink -f "$frag" 2>/dev/null || printf '%s' "$frag")"
    case "${src}/" in
      "${WORKSPACE_ROOT}/"*) : ;;
      *) FOREIGN=$(( FOREIGN + 1 )); continue ;;
    esac

    svc="$(systemctl --user show "$unit" -p Unit --value 2>/dev/null || true)"
    [ -n "$svc" ] || svc="${unit%.timer}.service"

    next="$(job_timestamp_utc "$(systemctl --user show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null || true)")"
    last="$(job_timestamp_utc "$(systemctl --user show "$unit" -p LastTriggerUSec --value 2>/dev/null || true)")"
    result="$(systemctl --user show "$svc" -p Result --value 2>/dev/null || true)"
    status="$(systemctl --user show "$svc" -p ExecMainStatus --value 2>/dev/null || true)"
    handle=""
    for kv in $(systemctl --user show "$svc" -p Environment --value 2>/dev/null || true); do
      case "$kv" in COMMONCLAW_JOB_HANDLE=*) handle="${kv#COMMONCLAW_JOB_HANDLE=}" ;; esac
    done
    onfail="$(systemctl --user show "$svc" -p OnFailure --value 2>/dev/null || true)"

    ENABLED+="$(jq -cn \
      --arg owner "$ME" --arg timer "$unit" --arg service "$svc" \
      --arg definition "$src" --arg next "$next" --arg last "$last" \
      --arg result "$result" --arg status "$status" --arg handle "$handle" \
      --argjson failure_wired "$([ -n "$onfail" ] && echo true || echo false)" \
      '{account:$owner, timer:$timer, service:$service, definition:$definition,
        next_run:(if $next == "" then null else $next end),
        last_run:(if $last == "" then null else $last end),
        last_result:(if $result == "" then null else $result end),
        last_exit_status:(if $status == "" then null else $status end),
        owning_handle:(if $handle == "" then null else $handle end),
        failure_wired:$failure_wired}')"$'\n'
  done <<< "$(printf '%s\n' "$timers" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /\.timer$/) print $i}')"
else
  MANAGER=false
  finding warn "${ME} has no service manager this session can reach, so their own timers were not read. A manager runs once the person has a session or linger is on."
fi

[ "$FOREIGN" -eq 0 ] || \
  finding info "${FOREIGN} timer(s) under ${ME} are not this claw's jobs: their definitions sit outside ${WORKSPACE_ROOT} and belong to the distribution"

# ------------------------------------------------------------ other accounts
#
# loginctl answers for everybody. It says who has a manager and who lingers,
# and it says nothing at all about what those managers run.

OTHERS=""
WHY="this account cannot query another account's service manager, and a home here is 0750 and theirs. Only that account, or root, lists their timers."
while read -r uid user linger state; do
  case "$uid" in ''|*[!0-9]*) continue ;; esac
  [ "$user" != "$ME" ] || continue
  OTHERS+="$(jq -cn --arg account "$user" --arg linger "$linger" --arg state "$state" --arg why "$WHY" \
    '{account:$account, linger:$linger, session_state:$state,
      timers:"unreadable", why:$why}')"$'\n'
done <<< "$(loginctl list-users --no-pager --no-legend 2>/dev/null || true)"

others_count="$(printf '%s' "$OTHERS" | jq -s 'length')"
[ "${others_count:-0}" -eq 0 ] || \
  finding info "${others_count} other account(s) on this claw hold timers this readout cannot see. Only that account, or root, can list them."

# ------------------------------------------------------- the declared timers
#
# A find over one tree. Directories the caller cannot enter are named rather
# than skipped silently, because a workspace closed to this caller is not a
# workspace holding no jobs.

DECLARED=""
CLOSED=""
if [ -d "$WORKSPACE_ROOT" ]; then
  for ws in "$WORKSPACE_ROOT"/*; do
    [ -d "$ws" ] || continue
    if [ ! -x "$ws" ] || [ ! -r "$ws" ]; then
      CLOSED="${CLOSED} $(basename "$ws")"
      continue
    fi
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      job="$(basename "$t" .timer)"
      dir="$(dirname "$t")"
      svc="${dir}/${job}.service"
      linked="$(readlink "${HOME}/.config/systemd/user/${job}.timer" 2>/dev/null || true)"
      DECLARED+="$(jq -cn --arg workspace "$(basename "$ws")" --arg job "$job" \
        --arg project "$dir" --argjson service_present "$([ -f "$svc" ] && echo true || echo false)" \
        --argjson linked_here "$([ "$linked" = "$t" ] && echo true || echo false)" \
        '{workspace:$workspace, job:$job, project:$project,
          service_present:$service_present, linked_under_caller:$linked_here}')"$'\n'
    done <<< "$(find "$ws" -maxdepth "$SCAN_DEPTH" \
                  \( -name .git -o -name node_modules -o -name .venv \
                     -o -name __pycache__ -o -name .claude \) -prune \
                  -o -type f -name '*.timer' -print 2>/dev/null || true)"
  done
else
  finding warn "no workspace root at ${WORKSPACE_ROOT}, so no job definition was read"
fi

[ -z "$CLOSED" ] || \
  finding info "workspace(s) closed to ${ME}:${CLOSED}. Their job definitions were not read. Closed is not empty."

# A declared job nobody here has linked is worth naming. It is not a fault: the
# person who runs it may be another account, whose timers this readout cannot
# see.
unlinked="$(printf '%s' "$DECLARED" | jq -s '[.[] | select(.linked_under_caller == false)] | length')"
[ "${unlinked:-0}" -eq 0 ] || \
  finding info "${unlinked} declared job(s) are not linked under ${ME}. Another account may run them, or nobody does yet."

# ---------------------------------------------------------------- emit

jq -n \
  --arg script "list-jobs" \
  --arg host "$(hostname -s)" \
  --arg me "$ME" \
  --arg root "$WORKSPACE_ROOT" \
  --argjson manager "$MANAGER" \
  --argjson enabled "$(printf '%s' "$ENABLED" | jq -s .)" \
  --argjson others "$(printf '%s' "$OTHERS" | jq -s .)" \
  --argjson declared "$(printf '%s' "$DECLARED" | jq -s .)" \
  --argjson findings "$(printf '%s' "$FINDINGS" | jq -s .)" \
  '{script:$script, ok:true, claw:$host, caller:$me, workspace_root:$root,
    caller_manager_readable:$manager,
    enabled_under_caller:$enabled,
    other_accounts:$others,
    declared_in_workspaces:$declared,
    findings:$findings}'
