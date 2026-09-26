#!/bin/bash
#
# schedule-job.sh: put one project's job on a timer under the caller's own
# account.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./schedule-job.sh --project <dir> --job <name> --handle <bus handle>
#   ./schedule-job.sh --project <dir> --job <name> --handle <name> --dry-run
#
#   --project   a directory holding <job>.service and <job>.timer. This script
#               links those two files and never edits them.
#   --handle    the bus handle a failure is reported to.
#
# REQUIRED ROLE: member. It calls no sudo.
#
# THE OWNING HANDLE IS RECORDED IN A DROP-IN under
# ~/.config/systemd/user/<job>.service.d/, with the OnFailure wiring. The
# failure unit needs the handle at the moment the job fails, and systemd hands
# it only the failed unit's name. And a job whose author forgot the wiring
# would fail silently forever, so this installs it.
#
# IS THIS OVER-ENGINEERED? It installs four things: the failure sender, the
# shared failure unit, the drop-in, and the two links. The first two go in once
# per account and every job shares them; the drop-in and the links are what one
# job costs. One failure unit per job would multiply and drift. None at all
# leaves a failed job silent, which is what this exists to end.
#
# THE FOUR REFUSALS, each on a state that ships a fault:
#
#   NOT ONESHOT. A unit that stays running holds the timer's next elapse
#   against a job that never ended.
#
#   A PATH OUTSIDE THE TREE. A home, /tmp and /run are refused by name. A job
#   writes into /srv/workspaces, so removing an account loses no work. The
#   system prefixes a program is reached by are allowed, and ExecStart must still name something under
#   /srv/workspaces, so a unit that only runs a system program is refused too.
#
#   A CREDENTIAL SHAPE. The patterns are the git conventions check's, plus
#   the 1Password service-account token. An op:// reference is a NAME and is
#   what a job carries: the value is read inside the one process at run time.
#
#   LINGER OFF. Without it the account's service manager stops with the last
#   session, and the timer with it. Provisioning turns it on at onboarding. On
#   an older claw the claw's own admin runs loginctl enable-linger.
#
# WHAT A RE-RUN DOES. It converges. A link already pointing at the same file is
# left alone, one pointing elsewhere is replaced, and the drop-in is rewritten
# so a changed handle takes effect.
#
set -uo pipefail

PROJECT=""; JOB=""; HANDLE=""; DRY_RUN=0

WORKSPACE_ROOT="/srv/workspaces"
BUS="/opt/commonclaw/bin/bus"
USER_UNIT_DIR="${HOME}/.config/systemd/user"
CC_DIR="${HOME}/.config/commonclaw"
FAILURE_SENDER="${CC_DIR}/job-failure.sh"
FAILURE_UNIT="commonclaw-job-failure@.service"
DROPIN_NAME="commonclaw-job.conf"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The one reading of a timer's timestamps. A missing sibling fails the run.
# shellcheck source=job-lib.sh
[ -r "${SCRIPT_DIR}/job-lib.sh" ] \
  || { printf 'no job-lib.sh beside this script\n' >&2; exit 1; }
. "${SCRIPT_DIR}/job-lib.sh"

# The allow list the PATH refusal above names. Every job here reaches its
# program through a system prefix, and the one already running this way names
# the claw bus, so a tree-only rule would refuse every job.
ALLOWED_PREFIXES=("${WORKSPACE_ROOT}/" "/usr/" "/bin/" "/sbin/"
                  "/opt/commonclaw/" "/etc/commonclaw/" "/var/lib/commonclaw/")
DENIED_PREFIXES=("/home/" "/root/" "/tmp/" "/var/tmp/" "/run/" "/dev/shm/")

# The conventions check's patterns, character for character, plus the
# 1Password service-account token. Each needs the full length of a real value,
# so a document naming a prefix does not match.
SECRET_PATTERNS='^-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{12,}|sk-ant-[A-Za-z0-9_-]{24,}|ops_[A-Za-z0-9]{40,}'

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

need() {
  [ "$1" -ge "$2" ] || { printf '%s needs a value\n' "$3" >&2; usage; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) need $# 2 "--project"; PROJECT="$2"; shift 2 ;;
    --job)     need $# 2 "--job";     JOB="$2";     shift 2 ;;
    --handle)  need $# 2 "--handle";  HANDLE="$2";  shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; NEXT_RUN=""; SERVICE_FILE=""; TIMER_FILE=""

say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  OK    %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(true); return 0; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(false); FAILED=1; return 0; }
warn() { printf '  note  %s\n' "$*" >&2; NOTES+=("$*"); return 0; }

emit_json() {
  local checks notes i
  checks="$(for i in "${!CHK_DESC[@]}"; do
              jq -cn --arg c "${CHK_DESC[$i]}" --argjson o "${CHK_OK[$i]}" '{check:$c, ok:$o}'
            done | jq -s .)"
  notes="$(for i in "${NOTES[@]:-}"; do [ -n "$i" ] && jq -n --arg t "$i" '$t'; done | jq -s .)"
  jq -n \
    --arg script "schedule-job" \
    --argjson ok "$([ "$FAILED" -eq 0 ] && echo true || echo false)" \
    --argjson dry "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)" \
    --arg project "$PROJECT" --arg job "$JOB" --arg handle "$HANDLE" \
    --arg service "$SERVICE_FILE" --arg timer "$TIMER_FILE" \
    --arg action "$ACTION" --arg next "$NEXT_RUN" \
    --argjson checks "$checks" --argjson notes "$notes" \
    '{script:$script, ok:$ok, dry_run:$dry,
      project:$project, job:$job, owning_handle:$handle,
      units:{service:$service, timer:$timer},
      action:$action,
      next_run:(if $next == "" then null else $next end),
      checks:$checks,
      failed_checks:[$checks[] | select(.ok == false) | .check],
      notes:$notes}'
}

finish() { emit_json; [ "$FAILED" -eq 0 ] || exit 1; exit 0; }
refuse() { say "REFUSED: $*"; exit 1; }

# ---------------------------------------------------------------- preflight

command -v jq >/dev/null 2>&1 || { printf 'jq is required and is not installed\n' >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { printf 'systemctl is required and is not installed\n' >&2; exit 1; }

[ -n "$PROJECT" ] || { say "missing required argument: --project"; usage; }
[ -n "$JOB" ]     || { say "missing required argument: --job"; usage; }
[ -n "$HANDLE" ]  || { say "missing required argument: --handle"; usage; }

[ "$(id -u)" -ne 0 ] || refuse "run this as the person the job belongs to, never as root. A job under root belongs to no account, so removing an account would not clear it."

# Constrain, do not escape. Both values land in file paths and in unit names.
case "$JOB" in
  [a-z]*) : ;;
  *) refuse "'${JOB}' is not a usable job name: it must start with a lowercase letter." ;;
esac
case "$JOB" in
  *[!a-z0-9-]*) refuse "'${JOB}' is not a usable job name: use lowercase letters, digits and hyphen only." ;;
esac
[ "${#JOB}" -le 48 ] || refuse "'${JOB}' is longer than 48 characters."

# The handle lands in an environment line the failure sender word-splits.
case "$HANDLE" in
  [a-z]*) : ;;
  *) refuse "'${HANDLE}' is not a usable bus handle: it must start with a lowercase letter." ;;
esac
case "$HANDLE" in
  *[!a-z0-9_-]*) refuse "'${HANDLE}' is not a usable bus handle: use lowercase letters, digits, hyphen and underscore only." ;;
esac
[ "${#HANDLE}" -le 64 ] || refuse "'${HANDLE}' is longer than 64 characters."

# Resolved, because that is what catches a symlink pointing out of the tree.
PROJECT_ABS="$(cd -- "$PROJECT" 2>/dev/null && pwd -P || true)"
[ -n "$PROJECT_ABS" ] || refuse "no such project directory: ${PROJECT}"
case "${PROJECT_ABS}/" in
  "${WORKSPACE_ROOT}/"*) : ;;
  *) refuse "${PROJECT_ABS} is outside ${WORKSPACE_ROOT}. A job's definition lives in the project directory it belongs to, which is tracked and backed up." ;;
esac

SERVICE_FILE="${PROJECT_ABS}/${JOB}.service"
TIMER_FILE="${PROJECT_ABS}/${JOB}.timer"

say ""
say "=== schedule ${JOB} ==="
say "  project: ${PROJECT_ABS}"
say "  owner:   ${HANDLE}"
say "  account: $(id -un)"
say ""

# ---------------------------------------------------------------- the checks

for f in "$SERVICE_FILE" "$TIMER_FILE"; do
  if [ -r "$f" ]; then
    ok "$(basename "$f") is there and readable"
  else
    bad "$(basename "$f") is missing or unreadable at ${f}"
  fi
done
[ "$FAILED" -eq 0 ] || { warn "nothing was installed: the definition is incomplete"; finish; }

# -- Type=oneshot --
if grep -Eq '^[[:space:]]*Type[[:space:]]*=[[:space:]]*oneshot[[:space:]]*$' "$SERVICE_FILE"; then
  ok "the service is Type=oneshot"
else
  bad "the service is not Type=oneshot. A timer's unit runs and ends; one that stays running holds the next elapse against a job that never finished."
fi

# -- ExecStart --
EXECSTART="$(grep -E '^[[:space:]]*ExecStart[[:space:]]*=' "$SERVICE_FILE" | head -1 || true)"
if [ -n "$EXECSTART" ]; then
  ok "the service carries an ExecStart line"
else
  bad "the service carries no ExecStart line, so it would start nothing"
fi

# -- the [Install] section on the timer --
if grep -Eq '^[[:space:]]*WantedBy[[:space:]]*=[[:space:]]*timers\.target[[:space:]]*$' "$TIMER_FILE"; then
  ok "the timer is WantedBy=timers.target, so enabling it means something"
else
  bad "the timer has no WantedBy=timers.target in an [Install] section, so enabling it would wire it to nothing"
fi

# -- every path in both files --
#
# A specifier resolving into a home is refused by name rather than expanded:
# expanding it answers for this account, and the unit may later run under
# another.
paths_bad=""
specifier_bad=""
while IFS= read -r word; do
  case "$word" in
    '%h'*|'~'*|'$HOME'*|'${HOME}'*) specifier_bad="${specifier_bad} ${word}"; continue ;;
  esac
  case "$word" in /*) : ;; *) continue ;; esac
  for p in "${DENIED_PREFIXES[@]}"; do
    case "$word" in "${p}"*) paths_bad="${paths_bad} ${word}"; continue 2 ;; esac
  done
  allowed=0
  for p in "${ALLOWED_PREFIXES[@]}"; do
    case "$word" in "${p}"*) allowed=1; break ;; esac
  done
  [ "$allowed" -eq 1 ] || paths_bad="${paths_bad} ${word}"
done < <(sed -e 's/^[[:space:]]*#.*$//' -e 's/^[[:space:]]*;.*$//' "$SERVICE_FILE" "$TIMER_FILE" \
         | tr ' \t=",' '\n\n\n\n\n' | sed 's/[[:space:]]*$//' | grep -v '^$' || true)

if [ -n "$specifier_bad" ]; then
  bad "the units name a home through a specifier:${specifier_bad}. A job writes into ${WORKSPACE_ROOT} and nowhere else, so removing an account loses no work."
else
  ok "the units name no home through a specifier"
fi
if [ -n "$paths_bad" ]; then
  bad "the units carry path(s) outside the workspace tree and the system prefixes:${paths_bad}"
else
  ok "every absolute path in both units lies under ${WORKSPACE_ROOT} or a system prefix"
fi

# ExecStart must reach INTO the tree.
if printf '%s' "$EXECSTART" | grep -qF "${WORKSPACE_ROOT}/"; then
  ok "ExecStart names a program or an argument under ${WORKSPACE_ROOT}"
else
  bad "ExecStart names nothing under ${WORKSPACE_ROOT}, so this is not a job of ${PROJECT_ABS}"
fi

# -- no credential shape --
#
# The hit is counted and located, never printed. The line is the value.
cred_hits=""
for f in "$SERVICE_FILE" "$TIMER_FILE"; do
  while IFS= read -r n; do
    [ -n "$n" ] && cred_hits="${cred_hits} $(basename "$f"):${n}"
  done < <(grep -nE "$SECRET_PATTERNS" "$f" 2>/dev/null | cut -d: -f1 || true)
done
if [ -n "$cred_hits" ]; then
  bad "a line carries a credential shape:${cred_hits}. The line is not printed. A job names an op:// reference and the value is read inside the one process at run time."
else
  ok "no line in either unit carries a credential shape"
fi

# -- linger --
LINGER="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
if [ "$LINGER" = "yes" ]; then
  ok "linger is on for $(id -un), so the timer survives the last session ending"
else
  bad "linger is off for $(id -un) (loginctl reads '${LINGER:-nothing}'), so a timer enabled here would stop when their last session ends. Provisioning turns it on at onboarding. On a claw provisioned before that, the claw's own admin runs: sudo loginctl enable-linger $(id -un)"
fi

# -- the bus the failure line goes to --
if [ -x "$BUS" ]; then
  ok "the bus is at ${BUS}, so a failure has somewhere to be reported"
else
  bad "no bus at ${BUS}, so a failed job could tell ${HANDLE} nothing"
fi

if [ "$FAILED" -ne 0 ]; then
  warn "nothing was installed: a check refused."
  finish
fi

# ---------------------------------------------------------------- the plan

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-schedule"
  say "  would install ${FAILURE_SENDER} and ${USER_UNIT_DIR}/${FAILURE_UNIT}"
  say "  would write ${USER_UNIT_DIR}/${JOB}.service.d/${DROPIN_NAME} naming ${HANDLE}"
  say "  would link ${SERVICE_FILE} and ${TIMER_FILE} into ${USER_UNIT_DIR}"
  say "  would daemon-reload and enable --now ${JOB}.timer"
  warn "dry run: nothing was installed"
  finish
fi

# ---------------------------------------------------------------- install

install -d -m 0700 "$CC_DIR"
install -d -m 0755 "$USER_UNIT_DIR"

# The failure sender. One per account, shared by every job.
cat > "${FAILURE_SENDER}.part" <<'SENDER'
#!/bin/bash
#
# job-failure.sh: tell one scheduled job's owner that it failed. Installed and
# started by claw-ops schedule-job's failure unit, with the failed unit's name.
# The handle comes from that unit's own environment; a unit carrying none says
# so in the journal rather than sending the line somewhere nobody chose. The
# error stays in the journal.
#
set -u

UNIT="${1:-}"
[ -n "$UNIT" ] || { printf 'job-failure: no unit name was passed\n' >&2; exit 1; }

BUS="/opt/commonclaw/bin/bus"
export SESSION_BUS_DIR="/var/lib/commonclaw/bus"
[ -x "$BUS" ] || { printf 'job-failure: no bus at %s, so %s failed unheard\n' "$BUS" "$UNIT" >&2; exit 1; }

HANDLE=""
for kv in $(systemctl --user show "$UNIT" -p Environment --value 2>/dev/null || true); do
  case "$kv" in COMMONCLAW_JOB_HANDLE=*) HANDLE="${kv#COMMONCLAW_JOB_HANDLE=}" ;; esac
done
[ -n "$HANDLE" ] || {
  printf 'job-failure: %s names no owning handle, so nobody was told. Re-run claw-ops schedule-job for it.\n' "$UNIT" >&2
  exit 1
}

RESULT="$(systemctl --user show "$UNIT" -p Result --value 2>/dev/null || true)"
STATUS="$(systemctl --user show "$UNIT" -p ExecMainStatus --value 2>/dev/null || true)"

exec "$BUS" send "commonclaw-job" "$HANDLE" \
  "scheduled job failed: ${UNIT}" \
  "The unit ${UNIT} failed under account $(id -un) on $(hostname -s). Result ${RESULT:-unknown}, exit status ${STATUS:-unknown}. The error is in that account's journal: journalctl --user -u ${UNIT} -n 50"
SENDER
chmod 0700 "${FAILURE_SENDER}.part"
mv -f "${FAILURE_SENDER}.part" "$FAILURE_SENDER"
say "  sender:  ${FAILURE_SENDER}"

cat > "${USER_UNIT_DIR}/${FAILURE_UNIT}.part" <<SENDERUNIT
# Written by claw-ops schedule-job. Do not edit: a re-run replaces it.
[Unit]
Description=Tell a scheduled job's owner that %i failed

[Service]
Type=oneshot
ExecStart=${FAILURE_SENDER} %i
SENDERUNIT
mv -f "${USER_UNIT_DIR}/${FAILURE_UNIT}.part" "${USER_UNIT_DIR}/${FAILURE_UNIT}"
say "  failure: ${USER_UNIT_DIR}/${FAILURE_UNIT}"

DROPIN_DIR="${USER_UNIT_DIR}/${JOB}.service.d"
install -d -m 0755 "$DROPIN_DIR"
cat > "${DROPIN_DIR}/${DROPIN_NAME}.part" <<DROPIN
# Written by claw-ops schedule-job. Do not edit: a re-run replaces it.
[Unit]
OnFailure=commonclaw-job-failure@%n.service

[Service]
Environment=COMMONCLAW_JOB_HANDLE=${HANDLE}
DROPIN
mv -f "${DROPIN_DIR}/${DROPIN_NAME}.part" "${DROPIN_DIR}/${DROPIN_NAME}"
say "  drop-in: ${DROPIN_DIR}/${DROPIN_NAME}"

link_one() { # link_one <source file>
  local src="$1" name dest cur
  name="$(basename "$src")"
  dest="${USER_UNIT_DIR}/${name}"
  if [ -L "$dest" ]; then
    cur="$(readlink "$dest")"
    if [ "$cur" = "$src" ]; then
      say "  link:    ${name} already points at ${src}"
      return 0
    fi
    say "  link:    ${name} pointed at ${cur}, replacing"
    rm -f "$dest"
  elif [ -e "$dest" ]; then
    bad "${dest} exists and is not a symlink. A unit file copied into the account is a second copy of the definition; remove it and re-run."
    return 1
  fi
  ln -s "$src" "$dest"
  say "  link:    ${name} -> ${src}"
}

link_one "$SERVICE_FILE" || finish
link_one "$TIMER_FILE"   || finish

systemctl --user daemon-reload
systemctl --user enable --now "${JOB}.timer" >/dev/null
ACTION="scheduled"

# ---------------------------------------------------------------- verify

say ""
say "=== VERIFY ==="

for name in "${JOB}.service" "${JOB}.timer"; do
  want="${PROJECT_ABS}/${name}"
  got="$(readlink "${USER_UNIT_DIR}/${name}" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    ok "${name} is linked to ${want}"
  else
    bad "${name} points at '${got}', wanted ${want}"
  fi
done

state="$(systemctl --user is-enabled "${JOB}.timer" 2>/dev/null || true)"
case "$state" in
  enabled|enabled-runtime) ok "${JOB}.timer is ${state}" ;;
  *) bad "${JOB}.timer reads '${state}', wanted enabled" ;;
esac

active="$(systemctl --user is-active "${JOB}.timer" 2>/dev/null || true)"
if [ "$active" = "active" ]; then
  ok "${JOB}.timer is active"
else
  bad "${JOB}.timer reads '${active}', wanted active"
fi

# Read back from the unit systemd assembled rather than the file this script
# wrote. A drop-in in the wrong directory writes correctly and reaches
# nothing.
onfail="$(systemctl --user show "${JOB}.service" -p OnFailure --value 2>/dev/null || true)"
if [ "$onfail" = "commonclaw-job-failure@${JOB}.service.service" ]; then
  ok "${JOB}.service fails onto ${onfail}"
else
  bad "${JOB}.service reads OnFailure '${onfail}', so a failure would tell ${HANDLE} nothing"
fi

env_read=""
for kv in $(systemctl --user show "${JOB}.service" -p Environment --value 2>/dev/null || true); do
  case "$kv" in COMMONCLAW_JOB_HANDLE=*) env_read="${kv#COMMONCLAW_JOB_HANDLE=}" ;; esac
done
if [ "$env_read" = "$HANDLE" ]; then
  ok "systemd reads the owning handle as ${HANDLE}"
else
  bad "systemd reads the owning handle as '${env_read}', wanted ${HANDLE}"
fi

# The known-answer control. The four reads above returned what this script
# wrote, and a read-back answering whatever it was asked would too. This asks
# for a property nothing sets.
probe="$(systemctl --user show "${JOB}.service" -p RootDirectory --value 2>/dev/null || true)"
if [ -z "$probe" ]; then
  ok "known-answer: RootDirectory reads empty, so the reads above are reads"
else
  bad "known-answer FAILED: RootDirectory returned '${probe}' and nothing set it"
fi

NEXT_RUN="$(job_timestamp_utc "$(systemctl --user show "${JOB}.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)")"
if [ -n "$NEXT_RUN" ]; then
  say ""
  say "  next run: ${NEXT_RUN}"
else
  warn "${JOB}.timer names no next run. A timer with only a monotonic schedule and no OnCalendar reads this way, and so does one whose calendar has passed."
fi

say ""
say "  ${JOB} runs under $(id -un)'s own account. Its definition is in ${PROJECT_ABS},"
say "  which the workspace repository tracks. A failure sends one line to ${HANDLE}"
say "  and the error stays in the journal: journalctl --user -u ${JOB}.service"

finish
