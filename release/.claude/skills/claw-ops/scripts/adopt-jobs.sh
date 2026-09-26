#!/bin/bash
#
# adopt-jobs.sh: take over a departed account's scheduled jobs.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./adopt-jobs.sh --from <account> --project <dir> --handle <bus handle> \
#                   --job <name> [--job <name> ...]
#   ./adopt-jobs.sh --from <account> --project <dir> --handle <name> \
#                   --job <name> --dry-run
#
# REQUIRED ROLE: member. It runs from the ADOPTING account and schedules under
# it, so it calls no sudo.
#
# WHAT IT REFUSES. Relinking a job while the departed account still runs it
# means two copies of the same work on one claw. No member may read another
# account's service manager, so what is measured is whether that account can
# run a timer at all: whether it still exists, whether it lingers, and whether
# its manager is active. Any of those refuses the adoption. Say what was
# measured rather than claiming their timers are gone.
#
# IS THIS OVER-ENGINEERED? The adoption is the schedule-job operation with a
# check in front of it, so that is how it is built: the check is here and the
# install is schedule-job's, run once per job. There is no second copy of the
# checks, the drop-in or the links.
#
set -uo pipefail

FROM=""; PROJECT=""; HANDLE=""; DRY_RUN=0; JOBS=()

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULE="${SCRIPT_DIR}/schedule-job.sh"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

need() {
  [ "$1" -ge "$2" ] || { printf '%s needs a value\n' "$3" >&2; usage; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from)    need $# 2 "--from";    FROM="$2";    shift 2 ;;
    --project) need $# 2 "--project"; PROJECT="$2"; shift 2 ;;
    --handle)  need $# 2 "--handle";  HANDLE="$2";  shift 2 ;;
    --job)     need $# 2 "--job";     JOBS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

say()    { printf '%s\n' "$*" >&2; }
refuse() { say "REFUSED: $*"; exit 1; }

command -v jq >/dev/null 2>&1 || { printf 'jq is required and is not installed\n' >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { printf 'systemctl is required and is not installed\n' >&2; exit 1; }

[ -n "$FROM" ]    || { say "missing required argument: --from"; usage; }
[ -n "$PROJECT" ] || { say "missing required argument: --project"; usage; }
[ -n "$HANDLE" ]  || { say "missing required argument: --handle"; usage; }
[ "${#JOBS[@]}" -gt 0 ] || { say "missing required argument: --job"; usage; }

[ -x "$SCHEDULE" ] || refuse "no schedule-job.sh beside this script at ${SCHEDULE}. Adoption is that operation with a check in front of it, and there is no second copy of it here."

ME="$(id -un)"
[ "$FROM" != "$ME" ] || refuse "--from names this account. Re-scheduling your own job is the schedule-job operation."

case "$FROM" in
  [a-z]*) : ;;
  *) refuse "'${FROM}' is not a usable account name: it must start with a lowercase letter." ;;
esac
case "$FROM" in
  *[!a-z0-9_-]*) refuse "'${FROM}' is not a usable account name: use lowercase letters, digits, hyphen and underscore only." ;;
esac

say ""
say "=== adopt ${#JOBS[@]} job(s) from ${FROM} ==="
say "  adopting account: ${ME}"
say "  project:          ${PROJECT}"
say "  owner:            ${HANDLE}"
say ""

# ------------------------------------------------- can the departed still run

ACCOUNT_EXISTS=false; LINGER="none"; MANAGER="none"; UID_FROM=""
if getent passwd "$FROM" >/dev/null 2>&1; then
  ACCOUNT_EXISTS=true
  UID_FROM="$(id -u "$FROM" 2>/dev/null || true)"
  LINGER="$(loginctl show-user "$FROM" -p Linger --value 2>/dev/null || echo "none")"
  [ -n "$LINGER" ] || LINGER="none"
  if [ -n "$UID_FROM" ]; then
    MANAGER="$(systemctl show "user@${UID_FROM}.service" -p ActiveState --value 2>/dev/null || true)"
    [ -n "$MANAGER" ] || MANAGER="none"
  fi
fi

say "  ${FROM}: account $([ "$ACCOUNT_EXISTS" = true ] && echo exists || echo gone), linger ${LINGER}, service manager ${MANAGER}"
say ""

BLOCK=""
if [ "$ACCOUNT_EXISTS" = true ]; then
  [ "$LINGER" != "yes" ] || BLOCK="${BLOCK} linger is on for ${FROM}, so their service manager runs with no session and their timers fire."
  case "$MANAGER" in
    active|activating|reloading)
      BLOCK="${BLOCK} ${FROM}'s service manager reads ${MANAGER}, so any timer they have enabled is live right now." ;;
  esac
fi

if [ -n "$BLOCK" ]; then
  say "REFUSED:${BLOCK}"
  say ""
  say "  Two copies of one job would run. Their timers cannot be read from here: no member may query"
  say "  another account's service manager. End ${FROM}'s side first, then re-run this."
  say "  Either ${FROM} disables their own timers, or the claw's own admin turns their linger off and"
  say "  ends their service manager."
  jq -n --arg script "adopt-jobs" --arg from "$FROM" --arg me "$ME" \
        --argjson exists "$ACCOUNT_EXISTS" --arg linger "$LINGER" --arg manager "$MANAGER" \
        --arg why "${BLOCK# }" \
        --arg note "the departed account's timers were not listed: no member may query another account's service manager. What was measured is whether that account can run a timer at all." \
    '{script:$script, ok:false, stage:"departed-account", adopting_account:$me,
      departed:{account:$from, exists:$exists, linger:$linger, service_manager:$manager},
      adopted:[], refused_because:$why, notes:[$note]}'
  exit 1
fi

# ----------------------------------------------------------------- the links

RESULTS=""
FAILED=0
for job in "${JOBS[@]}"; do
  say "--- ${job}"
  args=(--project "$PROJECT" --job "$job" --handle "$HANDLE")
  [ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
  if out="$("$SCHEDULE" "${args[@]}")"; then
    rc=0
  else
    rc=$?
    FAILED=1
  fi
  # schedule-job emits JSON on every path it reaches. A run that died before
  # emitting any is recorded as such rather than as a parse failure.
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    RESULTS+="$(printf '%s' "$out" | jq -c --argjson rc "$rc" '. + {exit_status:$rc}')"$'\n'
  else
    FAILED=1
    RESULTS+="$(jq -cn --arg job "$job" --argjson rc "$rc" \
      '{script:"schedule-job", job:$job, ok:false, exit_status:$rc,
        failed_checks:["schedule-job produced no result document"]}')"$'\n'
  fi
done

jq -n --arg script "adopt-jobs" --arg from "$FROM" --arg me "$ME" \
      --argjson ok "$([ "$FAILED" -eq 0 ] && echo true || echo false)" \
      --argjson dry "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)" \
      --argjson exists "$ACCOUNT_EXISTS" --arg linger "$LINGER" --arg manager "$MANAGER" \
      --argjson adopted "$(printf '%s' "$RESULTS" | jq -s .)" \
  '{script:$script, ok:$ok, dry_run:$dry, adopting_account:$me,
    departed:{account:$from, exists:$exists, linger:$linger, service_manager:$manager},
    adopted:$adopted,
    failed_checks:[$adopted[] | select(.ok == false) | .job]}'

[ "$FAILED" -eq 0 ] || exit 1
exit 0
