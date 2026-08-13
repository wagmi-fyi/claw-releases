#!/bin/bash
#
# manage-workspace-access.sh — grant and revoke one person's access to one
# workspace.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./manage-workspace-access.sh --grant  alice finance
#   sudo ./manage-workspace-access.sh --revoke alice finance
#   sudo ./manage-workspace-access.sh --show   finance
#
#   --dry-run    print the plan, change nothing
#
# THE DOOR EXISTS BECAUSE THE SCAFFOLD IS THE WRONG PLACE TO ASK. Re-running
# scaffold-workspace.sh with a longer member list does add somebody, which is
# how access has been granted until now. It has no way to take anybody off, so
# half of the operation had no door at all, and the half that existed was a
# side effect of a script whose name says it creates directories. Changing who
# reaches a workspace is its own act and reads as one here.
#
# ACCESS IS GROUP MEMBERSHIP, and this door does exactly that plus the one thing
# people forget.
#
# THE THING PEOPLE FORGET. A workspace directory belongs to root while its git
# directory belongs to a member, so git refuses the repository until the caller
# declares it trusts that exact path. A grant that skips the declaration hands
# somebody a workspace whose git rail refuses them; a revoke that skips it
# leaves a stale claim behind, pointing at a directory they can no longer read.
# Grant both, revoke both, in the same act. operations/lifecycle.md carries the
# rule and this door is where it is enforced.
#
# DECLARED PER PERSON AND BY EXACT PATH. Git honors an exact path, or the single
# literal star meaning every directory everywhere, and nothing between them -- a
# trailing glob matches nothing. The bare star would exempt that person from the
# guard for every repository on the claw, which is far more than membership of
# one workspace means.
#
# A GROUP CHANGE REACHES THE PERSON AT THEIR NEXT LOGIN, and this door SAYS so
# on every change rather than leaving it to be rediscovered. An existing session
# keeps the groups it started with. This is the usual reason a fresh grant looks
# like it did nothing, and the answer is to reconnect.
#
# REVOKING THE LAST MEMBER IS ALLOWED AND WARNED, NEVER REFUSED. An empty
# workspace is a state, not an error: a firm between people on a domain of work
# still owns that work, the directory keeps its manifest and its backups, and a
# later grant brings somebody back to it. A door that refused would force the
# caller to either invent a placeholder member or destroy the workspace to empty
# it, and both are worse than the state being prevented.
#
# `claw-members` IS THE FLOOR AND IS NOT TOUCHED HERE. It says a person has a
# login on this claw; it grants nothing and it owns one file. A person must
# already be in it to be granted a workspace, because a person who is not in it
# was not made by the onboarding door and is something else -- a service
# account, or half of an interrupted run. Revoking every workspace leaves it in
# place, since it is not what access is made of.
#
# --show WRITES NOTHING AND RECORDS NOTHING. Reading who reaches a workspace is
# not an act on the claw, and a log row for every question would bury the rows
# that are acts.
#
set -euo pipefail

MODE=""; PERSON=""; WORKSPACE=""; DRY_RUN=0

WORKSPACE_ROOT="/srv/workspaces"
ADMIN_LOG="/etc/commonclaw/admin-log.md"
MEMBERS_GROUP="claw-members"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

# `shift N` returns non-zero when fewer than N arguments remain, and under
# `set -e` that ends the script with status 1 and NOTHING printed. A caller who
# typed `--grant alice` and forgot the workspace would get silence and a failure
# code. So the count is checked first and the miss is named.
need() {
  [ "$1" -ge "$2" ] || { printf '%s needs %s value(s)\n' "$3" "$(( $2 - 1 ))" >&2; usage; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --grant)   need $# 3 "--grant <person> <workspace>";  MODE="grant";  PERSON="$2"; WORKSPACE="$3"; shift 3 ;;
    --revoke)  need $# 3 "--revoke <person> <workspace>"; MODE="revoke"; PERSON="$2"; WORKSPACE="$3"; shift 3 ;;
    --show)    need $# 2 "--show <workspace>";            MODE="show";   WORKSPACE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; WS_DIR=""; WS_GROUP=""; MEMBERS_AFTER=""

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
  printf '  "script": "manage-workspace-access",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "mode": "%s",\n' "$(json_esc "$MODE")"
  printf '  "person": "%s",\n' "$(json_esc "$PERSON")"
  printf '  "workspace": "%s",\n' "$(json_esc "$WORKSPACE")"
  printf '  "path": "%s",\n' "$(json_esc "$WS_DIR")"
  printf '  "group": "%s",\n' "$(json_esc "$WS_GROUP")"
  printf '  "members": "%s",\n' "$(json_esc "$MEMBERS_AFTER")"
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

members_of() { getent group "$1" 2>/dev/null | cut -d: -f4 | tr ',' ' ' | xargs || true; }

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { say "run this as root"; exit 1; }

[ -n "$MODE" ] || { say "pick one: --grant, --revoke or --show"; usage; }
[ -n "$WORKSPACE" ] || { say "missing the workspace name"; usage; }
if [ "$MODE" != "show" ]; then
  [ -n "$PERSON" ] || { say "missing the person"; usage; }
fi

# ---- the workspace name ----
#
# The same two patterns as the other two workspace doors, character for
# character. The negative match is the control: a shell case pattern is anchored
# at both ends, so a trailing star reads as "anything at all" rather than "more
# of the same class", and the positive form alone validates the first character
# and nothing after it. This is also what keeps the target inside the workspace
# root, since a name carrying a slash or a dot cannot survive it.
case "$WORKSPACE" in
  [a-z]*) : ;;
  *) say "workspace name must start with a lowercase letter: '${WORKSPACE}'"; exit 1 ;;
esac
case "$WORKSPACE" in
  *[!a-z0-9-]*) say "workspace name may hold only lowercase letters, digits and hyphen: '${WORKSPACE}'"; exit 1 ;;
esac

WS_DIR="${WORKSPACE_ROOT}/${WORKSPACE}"
WS_GROUP="ws-${WORKSPACE}"
WS_MANIFEST="${WS_DIR}/.workspace.yaml"

[ -d "$WORKSPACE_ROOT" ] || { say "no workspace root at ${WORKSPACE_ROOT} -- run the provisioning plane first"; exit 1; }
[ -d "$WS_DIR" ] || { say "no workspace '${WORKSPACE}' at ${WS_DIR}"; exit 1; }

# No manifest means not a workspace, which means not this door's business. The
# same declarative rule the rest of the claw reads by.
[ -f "$WS_MANIFEST" ] || {
  say "REFUSED: ${WS_DIR} carries no .workspace.yaml, so it is not a workspace."
  say "Access to a directory somebody made by hand is not this door's to grant."
  exit 1
}

# ---------------------------------------------------------------- show

if [ "$MODE" = "show" ]; then
  ACTION="showed"
  MEMBERS_AFTER="$(members_of "$WS_GROUP")"
  say ""
  say "=== ${WORKSPACE} ==="
  say "  directory: ${WS_DIR}"
  say "  group:     ${WS_GROUP}"
  say "  members:   ${MEMBERS_AFTER:-none}"
  say ""
  if getent group "$WS_GROUP" >/dev/null 2>&1; then
    ok "the ${WS_GROUP} group exists"
  else
    bad "no ${WS_GROUP} group, so this workspace's directory is owned by a group that does not exist"
  fi
  [ -n "$MEMBERS_AFTER" ] || warn "nobody reaches ${WORKSPACE} today. That is a state, not a fault."
  finish
fi

# ---------------------------------------------------------------- the person

# Constrain the same way the onboarding door does. This value is written into a
# world-readable record and into commands that change system state.
case "$PERSON" in
  [a-z]*) : ;;
  *) say "'${PERSON}' is not a usable username: it must start with a lowercase letter."; exit 1 ;;
esac
case "$PERSON" in
  *[!a-z0-9_-]*) say "'${PERSON}' is not a usable username: use lowercase letters, digits, hyphen and underscore only."; exit 1 ;;
esac

getent passwd "$PERSON" >/dev/null 2>&1 || {
  say "no such person on this claw: '${PERSON}'."
  say "This door grants an existing account access to a directory. It does not create anybody -- that is the onboarding door."
  exit 1
}

# A person the onboarding door made is in the members group. One that is not is
# something else: a service account, or half of a run that stopped. Granting a
# workspace to it would be granting the firm's work to something nobody
# onboarded.
case " $(id -nG "$PERSON" 2>/dev/null || true) " in
  *" ${MEMBERS_GROUP} "*) : ;;
  *) say "'${PERSON}' is not in ${MEMBERS_GROUP}, so they are not a person this claw onboarded."
     say "Run the onboarding door first, or resolve the account by hand if it is a service account."
     exit 1 ;;
esac

[ -f "$ADMIN_LOG" ] || {
  say "REFUSED: no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down."
  say "The log is seeded by provisioning. Run the provisioning plane rather than creating it here."
  exit 1
}

getent group "$WS_GROUP" >/dev/null 2>&1 || {
  say "no ${WS_GROUP} group on this claw, so there is nothing to join."
  say "The workspace directory exists without the group that owns it. Re-run the scaffold rather than creating the group here."
  exit 1
}

BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z_]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac
WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

BEFORE="$(members_of "$WS_GROUP")"

say ""
say "=== ${MODE} ${PERSON} ${WORKSPACE} ==="
say "  group:   ${WS_GROUP}"
say "  members: ${BEFORE:-none}"
say "  by:      ${BY}"
say ""

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-${MODE}"
  MEMBERS_AFTER="$BEFORE"
  if [ "$MODE" = "grant" ]; then
    say "  would add ${PERSON} to ${WS_GROUP}"
    say "  would declare ${WS_DIR} a safe git directory for ${PERSON}"
  else
    say "  would remove ${PERSON} from ${WS_GROUP}"
    say "  would drop ${PERSON}'s git safe-directory claim on ${WS_DIR}"
  fi
  say "  would append one row to ${ADMIN_LOG}"
  warn "dry run: nothing was changed"
  finish
fi

# ---------------------------------------------------------------- the change

# Run git from a directory the caller can read. Git stats its working directory
# before doing anything, and a granted script runs from a root-only place.
if [ "$MODE" = "grant" ]; then
  gpasswd -a "$PERSON" "$WS_GROUP" >/dev/null
  have="$(sudo -u "$PERSON" -H git -C / config --global --get-all safe.directory 2>/dev/null || true)"
  case $'\n'"${have}"$'\n' in
    *$'\n'"${WS_DIR}"$'\n'*) : ;;
    *) sudo -u "$PERSON" -H git -C / config --global --add safe.directory "$WS_DIR" ;;
  esac
  ACTION="granted"
  LOG_ACTION="granted workspace access"
else
  gpasswd -d "$PERSON" "$WS_GROUP" >/dev/null 2>&1 || true
  sudo -u "$PERSON" -H git -C / config --global --unset-all safe.directory "^${WS_DIR}$" 2>/dev/null || true
  ACTION="revoked"
  LOG_ACTION="revoked workspace access"
fi

MEMBERS_AFTER="$(members_of "$WS_GROUP")"

# ---------------------------------------------------------------- the record

printf '| %s | %s | %s | %s on %s |\n' "$WHEN" "$BY" "$LOG_ACTION" "$PERSON" "$WORKSPACE" >> "$ADMIN_LOG"

# ---------------------------------------------------------------- verify

say ""
say "=== VERIFY ==="

# Read the group's own member list rather than trusting the command took.
in_group=0
case " ${MEMBERS_AFTER} " in *" ${PERSON} "*) in_group=1 ;; esac

if [ "$MODE" = "grant" ]; then
  if [ "$in_group" -eq 1 ]; then
    ok "${PERSON} is in ${WS_GROUP}"
  else
    bad "${PERSON} is not in ${WS_GROUP} after the grant"
  fi
else
  if [ "$in_group" -eq 0 ]; then
    ok "${PERSON} is not in ${WS_GROUP}"
  else
    bad "${PERSON} is still in ${WS_GROUP} after the revoke"
  fi
fi

# The git claim, read back from the person's own config. Both halves matter:
# a grant without it hands over a workspace whose git rail refuses them, and a
# revoke without it leaves a claim on a directory they cannot read.
claims="$(sudo -u "$PERSON" -H git -C / config --global --get-all safe.directory 2>/dev/null || true)"
has_claim=0
case $'\n'"${claims}"$'\n' in *$'\n'"${WS_DIR}"$'\n'*) has_claim=1 ;; esac

if [ "$MODE" = "grant" ]; then
  if [ "$has_claim" -eq 1 ]; then
    ok "${PERSON} declares ${WS_DIR} a safe git directory"
  else
    bad "${PERSON} holds no safe-directory claim on ${WS_DIR} -- their git rail will refuse the workspace"
  fi
else
  if [ "$has_claim" -eq 0 ]; then
    ok "${PERSON}'s safe-directory claim on ${WS_DIR} is gone"
  else
    bad "${PERSON} still declares ${WS_DIR} a safe git directory"
  fi
fi

# The claim is declared by exact path and never as the bare star. A star would
# exempt this person from the guard for every repository on the claw, which is
# not what membership of one workspace means, so it is checked rather than
# trusted -- including against a star that arrived some other way.
case $'\n'"${claims}"$'\n' in
  *$'\n'"*"$'\n'*) bad "${PERSON} declares the bare star, exempting them from the git guard everywhere on this claw" ;;
  *) ok "${PERSON} holds no blanket safe-directory star" ;;
esac

# claw-members is the floor and neither mode touches it.
case " $(id -nG "$PERSON" 2>/dev/null || true) " in
  *" ${MEMBERS_GROUP} "*) ok "${PERSON} is still in ${MEMBERS_GROUP}: this door does not touch the floor" ;;
  *) bad "${PERSON} left ${MEMBERS_GROUP} -- a workspace change must not touch the claw's own membership" ;;
esac

if [ "$(tail -1 "$ADMIN_LOG")" = "| ${WHEN} | ${BY} | ${LOG_ACTION} | ${PERSON} on ${WORKSPACE} |" ]; then
  ok "one row appended to ${ADMIN_LOG}"
else
  bad "the member-plane log does not end with this act's row"
fi

if [ -z "$MEMBERS_AFTER" ]; then
  warn "nobody reaches ${WORKSPACE} now. An empty workspace is a state, not an error: it keeps its manifest and its backups, and a later grant brings somebody back to it."
fi

say ""
say "  A group change takes effect at ${PERSON}'s NEXT login. An existing session keeps"
say "  the groups it started with, so tell them to reconnect. This is the usual reason a"
say "  fresh grant looks like it did nothing."

finish
