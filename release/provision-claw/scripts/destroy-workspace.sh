#!/bin/bash
#
# destroy-workspace.sh — remove one workspace from this claw.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./destroy-workspace.sh --workspace finance --confirm finance
#
#   --dry-run    report what it would remove, change nothing
#
# THE DOOR EXISTS BECAUSE ITS ABSENCE WAS READING AS A REFUSAL. A claw-admin
# could create a workspace and could not remove one, so a firm reorganising its
# own directories had to ask the vendor to delete an empty directory on their
# own machine. Nobody decided that. In a default-deny plane an unbuilt door and
# a considered prohibition look identical from the outside, which is why the
# doors have to be built for the whole lifecycle rather than the half of it that
# creates things. Tenants manage their own workspaces.
#
# IT IS NOT PRECIOUS, AND THAT IS THE RULING. Everything under a workspace is
# in the backup rail, so this act reverts. A door guarded like an amputation
# teaches its caller that the vendor did not really mean the grant, and the
# ceremony costs more than it protects. What survives below is not guardrails:
#
#   THE TYPED NAME is a confirmation, not a gate. It is spelled as a repeated
#   argument rather than an interactive y/n prompt because BOTH kinds of caller
#   have to be able to answer it deliberately. A prompt reading from a terminal
#   is unanswerable by an agent session, so the door would either be closed to
#   the caller it was built for or answered by a blind `yes |`, which is not a
#   confirmation at all. Re-typing the name is one deliberate act either kind of
#   caller performs the same way.
#
#   THE ADMIN-LOG ROW is record-keeping under the law every granted door obeys,
#   not friction. The firm's own account of what it did to its own machine.
#
#   TARGET VALIDATION is correctness. A door that can remove a path outside the
#   workspace root is a defect wearing a safety feature's clothes. Four refusals
#   below, and each one is proven rather than asserted.
#
# WHAT IT REFUSES: a bad name, a target that resolves outside the workspace
# root, a directory with no manifest, and a missing member-plane log.
#
# A WORKSPACE WITH REAL WORK IN IT IS NOT SPECIAL-CASED INTO REFUSAL. A firm may
# retire a full workspace deliberately, and a door that refused the full ones
# would be a door for empty directories, which is not the operation anybody
# needs. The rail is the protection, and the closing sentence states exactly
# what that protection is worth rather than implying it is total.
#
# NO MANIFEST MEANS NOT A WORKSPACE, which means not this door's business. That
# is the same rule the whole claw reads by: inside the workspace root a manifest
# governs, and outside it, or inside it with no manifest, nothing does. A
# directory somebody made by hand is theirs to remove by hand.
#
# THE GROUP AND THE MEMBERSHIPS GO WITH IT. Leaving `ws-{workspace}` behind
# after its directory is gone leaves every member carrying a group that grants
# nothing, and leaves the next workspace of that name inheriting a roster
# nobody chose. The stale git safe-directory claim comes off in the same act,
# for the reason operations/lifecycle.md gives: grant both, revoke both.
#
set -euo pipefail

WORKSPACE=""; CONFIRM=""; DRY_RUN=0

WORKSPACE_ROOT="/srv/workspaces"
ADMIN_LOG="/etc/commonclaw/admin-log.md"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

# `shift N` returns non-zero when fewer than N arguments remain, and under
# `set -e` that ends the script with status 1 and NOTHING printed. A caller who
# typed a flag with no value after it would get silence and a failure code. So
# the count is checked first and the miss is named.
need() {
  [ "$1" -ge "$2" ] || { printf '%s needs a value\n' "$3" >&2; usage; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) need $# 2 "--workspace"; WORKSPACE="$2"; shift 2 ;;
    --confirm)   need $# 2 "--confirm";   CONFIRM="$2";   shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; WS_DIR=""; WS_GROUP=""; REMOVED_MEMBERS=""; BOUND_CHANNEL=""

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
  printf '  "script": "destroy-workspace",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "workspace": "%s",\n' "$(json_esc "$WORKSPACE")"
  printf '  "path": "%s",\n' "$(json_esc "$WS_DIR")"
  printf '  "group": "%s",\n' "$(json_esc "$WS_GROUP")"
  printf '  "members_released": "%s",\n' "$(json_esc "$REMOVED_MEMBERS")"
  printf '  "bound_channel": "%s",\n' "$(json_esc "$BOUND_CHANNEL")"
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

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { say "run this as root"; exit 1; }

[ -n "$WORKSPACE" ] || { say "missing required argument: --workspace"; usage; }

# ---- refusal 1: the name ----
#
# Constrain, do not escape, and match scaffold-workspace.sh character for
# character. The two doors have to agree on what a workspace name is, or one of
# them creates a name the other cannot address.
#
# TWO patterns, and the second one is the control. A shell case pattern is
# anchored at both ends, so `[a-z][a-z0-9-]*` reads as a character class
# followed by ANY remaining characters -- its trailing star is not "more of the
# same class", it is "anything at all", and that form validates the first two
# characters and nothing after them. The NEGATIVE match is what decides: it
# fires when any single character falls outside the class.
#
# This is also the first half of keeping the target inside the workspace root. A
# name carrying a slash or a dot cannot survive the negative match, so `..` and
# an absolute path are both refused here, by the name rule, before any path is
# built out of them.
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

# ---- refusal 2: the target resolves outside the root ----
#
# The name rule above refuses a traversal spelled into the argument. It cannot
# refuse a SYMLINK, because the name is clean and the path is built correctly;
# what moves is where the directory actually lands. So resolve both sides and
# require the target to still sit directly under the resolved root. Without
# this, a link at /srv/workspaces/finance pointing at /etc passes every name
# check and hands `rm -rf` the wrong tree.
#
# The root is resolved too, rather than compared as a literal, so a claw whose
# /srv is itself a link does not fail this for the wrong reason.
REAL_ROOT="$(readlink -f "$WORKSPACE_ROOT" 2>/dev/null || true)"
REAL_DIR="$(readlink -f "$WS_DIR" 2>/dev/null || true)"
[ -n "$REAL_ROOT" ] && [ -n "$REAL_DIR" ] || { say "cannot resolve ${WS_DIR}"; exit 1; }
# ONE check, not two. An earlier draft carried a separate `-L` refusal beside
# this one, and it could never fire: a symlink either resolves somewhere else,
# which this catches, or it resolves to its own canonical path, which is a loop
# that `readlink -f` refuses above. A check whose failure branch cannot be
# reached is not a check, and its pass is an unexamined claim, so the redundant
# one came out rather than staying as decoration that reads like depth.
if [ "$REAL_DIR" != "${REAL_ROOT}/${WORKSPACE}" ]; then
  say "REFUSED: ${WS_DIR} resolves to ${REAL_DIR}, which is not a workspace directly under ${REAL_ROOT}."
  say "A symlink in the workspace root is the usual cause. A workspace is a directory, and removing a link is not removing a workspace."
  say "A door that can remove a path outside the workspace root is a defect. Nothing was changed."
  exit 1
fi

# ---- refusal 3: no manifest, so not a workspace ----
#
# The declarative rule the whole claw reads by. Inside the root a manifest
# governs; inside it with no manifest, nothing does. A directory somebody made
# by hand under the root is not this door's business, and a door that swept it
# up would be removing things nobody declared.
[ -f "$WS_MANIFEST" ] || {
  say "REFUSED: ${WS_DIR} carries no .workspace.yaml, so it is not a workspace."
  say "A directory with no manifest is somebody's own, and this door does not remove it."
  exit 1
}

# ---- refusal 4: no member-plane log, so the act has nowhere to be recorded ----
#
# Provisioning seeds this file and nothing else creates it. The doors and the
# log arrive in the same run, so an absence means somebody removed it, and an
# act with nowhere to be written down should not happen quietly.
[ -f "$ADMIN_LOG" ] || {
  say "REFUSED: no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down."
  say "The log is seeded by provisioning. Run the provisioning plane rather than creating it here."
  exit 1
}

# ---- the confirmation ----
#
# Not a guardrail and not a gate on the state of the workspace. It exists so the
# caller names the target twice, which is what separates the workspace they meant
# from the one beside it in a list.
if [ "$CONFIRM" != "$WORKSPACE" ]; then
  say ""
  say "This removes ${WS_DIR}, the ${WS_GROUP} group, and every membership of it."
  say "Confirm by naming the workspace again:"
  say ""
  say "  sudo $0 --workspace ${WORKSPACE} --confirm ${WORKSPACE}"
  say ""
  exit 1
fi

# The caller behind sudo, never root. A record of who decided is the point, and
# "root" records nothing.
BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z_]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac
WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- what goes with it, read BEFORE anything is removed ----
#
# The member list has to be captured while the group still exists, because the
# safe-directory cleanup below is per person and there is no way to ask a group
# that has been deleted who was in it.
MEMBERS=""
if getent group "$WS_GROUP" >/dev/null 2>&1; then
  MEMBERS="$(getent group "$WS_GROUP" | cut -d: -f4 | tr ',' ' ')"
fi

# The channel binding lives in the manifest, so it dies with the directory and
# there is no separate registry to clean. It is READ here and reported, because
# whoever bound a channel bound people: everyone who reaches that channel
# reached this work, and the caller should see which binding just went away.
BOUND_CHANNEL="$(sed -n 's/^channel:[[:space:]]*//p' "$WS_MANIFEST" 2>/dev/null | head -1 || true)"

say ""
say "=== destroy ${WORKSPACE} ==="
say "  directory: ${WS_DIR}"
say "  group:     ${WS_GROUP}"
say "  members:   ${MEMBERS:-none}"
[ -n "$BOUND_CHANNEL" ] && say "  channel:   ${BOUND_CHANNEL} (this binding goes with it)"
say "  by:        ${BY}"
say ""

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-destroy"

  # A dry run's whole job is to report, so it is the one place a measurement of
  # the workspace belongs. It gates nothing, changes nothing, and is not the
  # evidence ceremony this door deliberately does not perform before acting.
  #
  # THE COUNT NEEDS A PINNED safe.directory FOR EXACTLY THIS INVOCATION. The
  # workspace directory is root's and its git directory is a member's, so git
  # stops root with a dubious-ownership refusal. What that guard protects
  # against is root EXECUTING configuration a member wrote. A read-only
  # rev-list, with the exception pinned on the command line for one invocation,
  # executes none of theirs. Pinning it here rather than writing root's global
  # config is the difference: the global write would widen root's git trust
  # permanently to buy one number, which is a patch on a check rather than a
  # use of it.
  commits="n/a (not a git repository)"
  if [ -d "${WS_DIR}/.git" ]; then
    commits="$(git -c safe.directory="$REAL_DIR" -C "$WS_DIR" rev-list --all --count 2>/dev/null || echo "unreadable")"
  fi
  files="$(find "$WS_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
  size="$(du -sh "$WS_DIR" 2>/dev/null | cut -f1)"

  say "  it holds ${commits} commit(s), ${files} filesystem entries, ${size} on disk"
  say ""
  say "  would remove the directory ${WS_DIR}"
  say "  would remove the group ${WS_GROUP}"
  say "  would release ${MEMBERS:-nobody} from it, and drop each stale git safe-directory claim"
  say "  would append one row to ${ADMIN_LOG}"
  warn "dry run: nothing was removed"
  finish
fi

# ---------------------------------------------------------------- remove

# The safe-directory claims come off FIRST, while the path still exists to be
# matched against. Doing it after the delete would work here, but it would
# depend on the claim being stored as a literal string rather than a resolved
# path, which is a property of git rather than a decision this door gets to
# make.
for m in $MEMBERS; do
  getent passwd "$m" >/dev/null 2>&1 || continue
  sudo -u "$m" -H git -C / config --global --unset-all safe.directory "^${WS_DIR}$" 2>/dev/null || true
  REMOVED_MEMBERS="${REMOVED_MEMBERS}${REMOVED_MEMBERS:+ }${m}"
done

rm -rf "$WS_DIR"
ACTION="destroyed"

# groupdel refuses a group that is somebody's PRIMARY group, and it is right to.
# On this claw a ws- group is never primary -- every person gets their own -- so
# the refusal means something unusual is true and the caller has to see it
# rather than have it forced through.
if getent group "$WS_GROUP" >/dev/null 2>&1; then
  if ! groupdel "$WS_GROUP" 2>/dev/null; then
    warn "the ${WS_GROUP} group could not be removed; it is some account's primary group. The directory is gone. Resolve the account, then remove the group by hand."
  fi
fi

# ---------------------------------------------------------------- the record

# One row, one append, one call. Nobody reads this file and writes it back, so
# no concurrent writer can lose a row to this one.
printf '| %s | %s | destroyed a workspace | %s |\n' "$WHEN" "$BY" "$WORKSPACE" >> "$ADMIN_LOG"

# ---------------------------------------------------------------- verify

say ""
say "=== VERIFY ==="

if [ ! -e "$WS_DIR" ]; then
  ok "${WS_DIR} is gone"
else
  bad "${WS_DIR} still exists"
fi

if getent group "$WS_GROUP" >/dev/null 2>&1; then
  bad "the ${WS_GROUP} group still exists"
else
  ok "the ${WS_GROUP} group is gone"
fi

# The group is gone, so nobody can still be carrying it. This reads each former
# member's own group list, which is what access is actually made of, rather than
# trusting that removing the group removed the memberships.
dangling=""
for m in $MEMBERS; do
  getent passwd "$m" >/dev/null 2>&1 || continue
  case " $(id -nG "$m" 2>/dev/null || true) " in
    *" ${WS_GROUP} "*) dangling="${dangling} ${m}" ;;
  esac
done
if [ -z "$dangling" ]; then
  ok "no account still carries ${WS_GROUP}"
else
  bad "still carrying ${WS_GROUP}:${dangling}"
fi

stale=""
for m in $MEMBERS; do
  getent passwd "$m" >/dev/null 2>&1 || continue
  claims="$(sudo -u "$m" -H git -C / config --global --get-all safe.directory 2>/dev/null || true)"
  case $'\n'"${claims}"$'\n' in
    *$'\n'"${WS_DIR}"$'\n'*) stale="${stale} ${m}" ;;
  esac
done
if [ -z "$stale" ]; then
  ok "no stale git safe-directory claim for ${WS_DIR} remains"
else
  bad "stale git safe-directory claim still held by:${stale}"
fi

if [ "$(tail -1 "$ADMIN_LOG")" = "| ${WHEN} | ${BY} | destroyed a workspace | ${WORKSPACE} |" ]; then
  ok "one row appended to ${ADMIN_LOG}"
else
  bad "the member-plane log does not end with this act's row"
fi

# The one true sentence. It is here because it is useful and because the rail's
# retention is a real bound rather than an unlimited one, and a caller who has
# just removed a directory deserves the actual shape of what can come back.
say ""
say "  Everything here that was older than the last backup snapshot can be restored"
say "  from the rail for as long as retention keeps that snapshot. Anything written"
say "  since that snapshot is gone for good."

finish
