#!/bin/bash
#
# scaffold-workspace.sh — create one workspace in the canonical shape.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./scaffold-workspace.sh --workspace finance --members alice,bob
#
#   --dry-run    print the plan, change nothing
#
# A workspace is a directory where an entire domain of work completes. Every
# workspace lives under /srv/workspaces, which is what makes the set of them
# readable at a glance.
#
# CREATES the workspace layout, with the symlink rule applied:
#   {workspace}/
#     .workspace.yaml                 the manifest: this is what says it is one
#     CLAUDE.md                       canonical instructions, authored
#     AGENTS.md -> CLAUDE.md          the other convention, symlinked
#     .claude/skills/                 authored skills directory
#     .agents/skills -> ../.claude/skills
#     _workpapers/                    running state
#     database/                       structured state, git-ignored
#     .venv/                          virtual environment
#     .gitignore
#     .git/                           git init --shared=group
#
# NEVER TWO COPIES OF ANYTHING. Two instruction files drift into two different
# briefings for one directory, silently. The symlink is the whole point.
#
# The directory itself: group ws-{workspace}, mode 2770 with setgid, plus
# default ACLs. Setgid makes new files inherit the group; the default ACL makes
# them group-writable. Without the ACL one member creates files the others
# cannot write.
#
# IDEMPOTENT. A re-run adds what is missing and touches nothing else. An
# existing instructions file is NEVER overwritten -- it is the workspace's real
# context and belongs to the people working there. Neither is the manifest,
# which carries the channel binding somebody else wrote.
#
set -euo pipefail

WORKSPACE=""; MEMBERS=""; DRY_RUN=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
WORKSPACE_ROOT="/srv/workspaces"

# The substitution rule lives in ONE file, sourced by this script and by
# provision-claw.sh. Provisioning reproduces an existing briefing with the same
# function that wrote it, to decide whether a member has edited it; a second
# copy of these three lines would drift and that verdict would go wrong.
# Checked before sourcing so a missing sibling says so, rather than dying on a
# source error two lines later.
[ -r "${SCRIPT_DIR}/render-template.sh" ] || {
  printf 'missing sibling: %s/render-template.sh -- copy the whole skill directory\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=render-template.sh
. "${SCRIPT_DIR}/render-template.sh"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --members) MEMBERS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0

say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  OK    %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(true); return 0; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(false); FAILED=1; return 0; }
warn() { printf '  note  %s\n' "$*" >&2; NOTES+=("$*"); return 0; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '  would run: %s\n' "$*" >&2; else "$@"; fi; }

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_json() {
  local i first
  printf '{\n'
  printf '  "script": "scaffold-workspace",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "workspace": "%s",\n' "$(json_esc "$WORKSPACE")"
  printf '  "path": "%s",\n' "$(json_esc "${WS_DIR:-}")"
  printf '  "group": "%s",\n' "$(json_esc "${WS_GROUP:-}")"
  printf '  "manifest": "%s",\n' "$(json_esc "${WS_MANIFEST:-}")"
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

for v in WORKSPACE MEMBERS; do
  [ -n "${!v}" ] || { say "missing required argument: $v"; usage; }
done

# TWO patterns, and the second one is the control. A shell case pattern is
# ANCHORED AT BOTH ENDS, so `[a-z][a-z0-9-]*` reads as a character class
# followed by ANY remaining characters -- its trailing star is not "more of the
# same class", it is "anything at all". Measured 2026-08-11: that form validates
# the FIRST TWO CHARACTERS and nothing after them, so it accepted names carrying
# a semicolon and a command substitution, and what refused them was `groupadd`
# further down. A gate whose refusal is really a downstream tool's refusal is
# narration, and the tool refusing is a property somebody can change without
# knowing it was load-bearing. The NEGATIVE match below is what decides: it
# fires when any single character falls outside the class.
case "$WORKSPACE" in
  [a-z]*) : ;;
  *) say "workspace name must start with a lowercase letter: '$WORKSPACE'"; exit 1 ;;
esac
case "$WORKSPACE" in
  *[!a-z0-9-]*) say "workspace name may hold only lowercase letters, digits and hyphen: '$WORKSPACE'"; exit 1 ;;
esac

WS_DIR="${WORKSPACE_ROOT}/${WORKSPACE}"
WS_GROUP="ws-${WORKSPACE}"
WS_MANIFEST="${WS_DIR}/.workspace.yaml"

[ -d "$WORKSPACE_ROOT" ] || { say "workspace root $WORKSPACE_ROOT does not exist -- run provision-claw.sh first"; exit 1; }

for t in workspace-instructions.md workspace-gitignore; do
  [ -r "${TEMPLATE_DIR}/${t}" ] || { say "template missing: ${TEMPLATE_DIR}/${t}"; exit 1; }
done

IFS=',' read -r -a MEMBER_LIST <<< "$MEMBERS"
[ "${#MEMBER_LIST[@]}" -gt 0 ] || { say "--members needs at least one user"; exit 1; }
for m in "${MEMBER_LIST[@]}"; do
  getent passwd "$m" >/dev/null 2>&1 || { say "no such unix user: '$m'"; exit 1; }
done
FIRST_MEMBER="${MEMBER_LIST[0]}"

say ""
say "=== workspace ${WORKSPACE} ==="
say "  directory: ${WS_DIR}"
say "  group:     ${WS_GROUP}"
say "  members:   ${MEMBER_LIST[*]}"
say ""

# ---------------------------------------------------------------- group + dir

run groupadd -f "$WS_GROUP"
for m in "${MEMBER_LIST[@]}"; do run gpasswd -a "$m" "$WS_GROUP" >/dev/null; done

# A workspace directory belongs to root while its git directory belongs to a
# member, so git refuses the repository until the caller declares it trusts it.
# Declare it per MEMBER and by EXACT path: git honors an exact path or the
# single literal star meaning everywhere, and nothing in between -- no trailing
# glob. The star would exempt that person from the guard for every repository on
# the box, which is far more than membership of one workspace means. root is
# deliberately left out: members can write repository config, and root is the
# only account here with anything to escalate to.
# Run git from a directory the member can read; it stats its working directory
# before doing anything, and this script runs from a root-only place.
declare_git_safe() {
  local user="$1" have
  have="$(sudo -u "$user" -H git -C / config --global --get-all safe.directory 2>/dev/null || true)"
  case $'\n'"${have}"$'\n' in
    *$'\n'"${WS_DIR}"$'\n'*) : ;;
    *) sudo -u "$user" -H git -C / config --global --add safe.directory "$WS_DIR" ;;
  esac
}
for m in "${MEMBER_LIST[@]}"; do
  if [ "$DRY_RUN" -eq 1 ]; then say "  would declare ${WS_DIR} a safe git directory for ${m}"
  else declare_git_safe "$m"; fi
done

# mkdir then chmod, rather than install -d -m 2770, so the setgid bit is set by
# a command that is unambiguous about it
run mkdir -p "$WS_DIR"
run chgrp "$WS_GROUP" "$WS_DIR"
run chmod 2770 "$WS_DIR"
run setfacl -d -m u::rwx "$WS_DIR"
run setfacl -d -m g::rwx "$WS_DIR"
run setfacl -d -m o::--- "$WS_DIR"

# state directories, per the workspace layout
for d in _workpapers database .claude/skills; do
  run mkdir -p "${WS_DIR}/${d}"
done
run chgrp -R "$WS_GROUP" "${WS_DIR}/_workpapers" "${WS_DIR}/database" "${WS_DIR}/.claude"
run chmod -R g+w "${WS_DIR}/_workpapers" "${WS_DIR}/database" "${WS_DIR}/.claude"

# ---------------------------------------------------------------- the manifest

# The declarative anchor. Inside the root, this file is what makes the directory
# a governed workspace rather than a directory somebody made. The channel field
# is written later by whoever binds the workspace, so a re-run never rewrites it.
if [ -e "$WS_MANIFEST" ]; then
  say "  keeping existing .workspace.yaml"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  would write .workspace.yaml"
else
  cat > "$WS_MANIFEST" <<MANEOF
# Workspace manifest. This file is what says this directory is a workspace.
name: ${WORKSPACE}
group: ${WS_GROUP}
claw: $(hostname)
created: $(date -I)
# The chat channel bound to this workspace. Empty until somebody binds it.
channel:
MANEOF
  chgrp "$WS_GROUP" "$WS_MANIFEST"; chmod 0660 "$WS_MANIFEST"
fi

# ---------------------------------------------------------------- the symlinks

# The other harness convention points AT the authored one. Never a second copy.
if [ "$DRY_RUN" -eq 1 ]; then
  say "  would link: .agents/skills -> ../.claude/skills"
  say "  would link: AGENTS.md -> CLAUDE.md"
else
  mkdir -p "${WS_DIR}/.agents"
  chgrp "$WS_GROUP" "${WS_DIR}/.agents"; chmod 2770 "${WS_DIR}/.agents"
  if [ -e "${WS_DIR}/.agents/skills" ] && [ ! -L "${WS_DIR}/.agents/skills" ]; then
    bad ".agents/skills exists as a real directory -- that is a second copy; resolve it by hand"
  else
    ln -sfn ../.claude/skills "${WS_DIR}/.agents/skills"
  fi
fi

# ---------------------------------------------------------------- templates

if [ -e "${WS_DIR}/CLAUDE.md" ]; then
  say "  keeping existing CLAUDE.md"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  would write CLAUDE.md from template"
else
  render "${TEMPLATE_DIR}/workspace-instructions.md" "${WS_DIR}/CLAUDE.md"
  chgrp "$WS_GROUP" "${WS_DIR}/CLAUDE.md"; chmod 0660 "${WS_DIR}/CLAUDE.md"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ -e "${WS_DIR}/AGENTS.md" ] && [ ! -L "${WS_DIR}/AGENTS.md" ]; then
    bad "AGENTS.md exists as a real file -- that is a second briefing; merge it into CLAUDE.md and symlink"
  else
    ln -sfn CLAUDE.md "${WS_DIR}/AGENTS.md"
  fi
fi

if [ -e "${WS_DIR}/.gitignore" ]; then
  say "  keeping existing .gitignore"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  would write .gitignore from template"
else
  render "${TEMPLATE_DIR}/workspace-gitignore" "${WS_DIR}/.gitignore"
  chgrp "$WS_GROUP" "${WS_DIR}/.gitignore"; chmod 0660 "${WS_DIR}/.gitignore"
fi

# ---------------------------------------------------------------- venv + git

if [ -x "${WS_DIR}/.venv/bin/python" ]; then
  say "  keeping existing .venv"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  would create .venv as ${FIRST_MEMBER}"
else
  sudo -u "$FIRST_MEMBER" -H bash -c "umask 002 && python3 -m venv '${WS_DIR}/.venv'" </dev/null
fi

# --shared=group is required: a workspace has several writers, and a default
# init creates objects only the first writer can rewrite
if [ -d "${WS_DIR}/.git" ]; then
  say "  keeping existing git repository"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  would run git init --shared=group as ${FIRST_MEMBER}"
else
  sudo -u "$FIRST_MEMBER" -H bash -c \
    "umask 002 && git init --shared=group -q '${WS_DIR}'" </dev/null
fi

# ---------------------------------------------------------------- verify

say ""
say "=== VERIFY ==="
[ "$DRY_RUN" -eq 1 ] && { say "  dry run: nothing to verify"; finish; }

if [ "$(stat -c '%a %U:%G' "$WS_DIR")" = "2770 root:${WS_GROUP}" ]; then
  ok "directory is 2770 root:${WS_GROUP} (setgid set)"
else
  bad "directory is $(stat -c '%a %U:%G' "$WS_DIR"), wanted 2770 root:${WS_GROUP}"
fi

# Read the ACLs once, then match against the text. Piping into `grep -q` would
# make this check depend on the producer's exit status: grep stops at the first
# match, the producer takes SIGPIPE, and under `pipefail` a correct ACL reads as
# a missing one.
acl_ok=1
acl_text="$(getfacl -p "$WS_DIR" 2>/dev/null || true)"
for want in 'default:user::rwx' 'default:group::rwx' 'default:other::---'; do
  grep -qxF "$want" <<< "$acl_text" || { bad "default ACL missing: $want"; acl_ok=0; }
done
[ "$acl_ok" -eq 1 ] && ok "default ACLs set (new files are group-writable)"

missing=""
for f in .workspace.yaml CLAUDE.md AGENTS.md .gitignore _workpapers database .claude/skills .agents/skills .venv .git; do
  [ -e "${WS_DIR}/${f}" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then ok "all workspace entries present"; else bad "missing:$missing"; fi

# the manifest carries the fields a sweep reads; a file that exists but says
# nothing is the failure this checks for
man_missing=""
for key in name group claw created channel; do
  grep -qE "^${key}:" "$WS_MANIFEST" 2>/dev/null || man_missing="$man_missing $key"
done
if [ -z "$man_missing" ]; then
  ok "manifest carries every field (name, group, claw, created, channel)"
else
  bad "manifest is missing field(s):$man_missing"
fi

# the symlink rule, verified as links rather than assumed
if [ -L "${WS_DIR}/AGENTS.md" ] && [ "$(readlink "${WS_DIR}/AGENTS.md")" = "CLAUDE.md" ]; then
  ok "AGENTS.md is a symlink to CLAUDE.md (one briefing, not two)"
else
  bad "AGENTS.md is not a symlink to CLAUDE.md"
fi
if [ -L "${WS_DIR}/.agents/skills" ] \
   && [ "$(readlink -f "${WS_DIR}/.agents/skills")" = "$(readlink -f "${WS_DIR}/.claude/skills")" ]; then
  ok ".agents/skills resolves to .claude/skills (one skills tree, not two)"
else
  bad ".agents/skills does not resolve to .claude/skills"
fi

check_db_ignored() { sudo -u "$FIRST_MEMBER" -H git -C "$WS_DIR" check-ignore -q database/x.db </dev/null 2>/dev/null; }
if check_db_ignored; then ok "database/ is git-ignored"; else bad "database/ is not git-ignored"; fi

if sudo -u "$FIRST_MEMBER" -H "${WS_DIR}/.venv/bin/python" -c 'pass' </dev/null 2>/dev/null; then
  ok "venv runs as ${FIRST_MEMBER}"
else
  bad "venv does not run as ${FIRST_MEMBER}"
fi

# git normalizes --shared=group to the value 1; it does not store the word
# "group". Accept every encoding that means group-shared, then check the
# property that actually matters rather than the config string.
shared_val="$(sudo -u "$FIRST_MEMBER" -H git -C "$WS_DIR" config core.sharedRepository </dev/null 2>/dev/null || true)"
case "$shared_val" in
  1|group|true) ok "git is group-shared (core.sharedRepository=${shared_val})" ;;
  *) bad "git is not group-shared (core.sharedRepository='${shared_val}') -- several writers will collide" ;;
esac

# the behaviour behind the setting: a second writer must be able to rewrite
# objects the first one created. Read the GROUP digit specifically -- a
# substring match would accept 755 on the strength of its owner digit.
if [ -d "${WS_DIR}/.git/objects" ]; then
  obj_mode="$(stat -c '%a' "${WS_DIR}/.git/objects" 2>/dev/null || true)"
  obj_group_digit="${obj_mode: -2:1}"
  case "$obj_group_digit" in
    2|3|6|7) ok "git objects directory is group-writable (mode ${obj_mode})" ;;
    *) bad "git objects directory is not group-writable (mode ${obj_mode}) -- the second writer will fail" ;;
  esac
fi

# --- control 1: shared write. The property the whole model rests on. ---
if [ "${#MEMBER_LIST[@]}" -ge 2 ]; then
  SECOND="${MEMBER_LIST[1]}"
  TESTFILE="${WS_DIR}/.scaffold-acl-test"
  rm -f "$TESTFILE"
  if sudo -u "$FIRST_MEMBER" -H bash -c "touch '$TESTFILE'" </dev/null 2>/dev/null \
     && sudo -u "$SECOND" -H bash -c "echo x >> '$TESTFILE'" </dev/null 2>/dev/null; then
    ok "shared write: ${SECOND} wrote a file ${FIRST_MEMBER} created (mode $(stat -c %a "$TESTFILE"), group $(stat -c %G "$TESTFILE"))"
  else
    bad "shared write FAILED -- setgid or the ACLs are wrong; this workspace will become one person's directory"
  fi
  rm -f "$TESTFILE"
else
  warn "only one member: the shared-write control did NOT run. An unrun control is not a passed one -- re-run after adding a second member."
fi

# --- control 2: exclusion. Without it the group buys nothing. ---
NONMEMBER=""
while IFS= read -r candidate; do
  case " ${MEMBER_LIST[*]} " in *" $candidate "*) continue ;; esac
  cand_groups=" $(id -nG "$candidate" 2>/dev/null || true) "
  case "$cand_groups" in *" ${WS_GROUP} "*) continue ;; esac
  NONMEMBER="$candidate"; break
done < <(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd)

if [ -n "$NONMEMBER" ]; then
  # Judge the exit status, never the message.
  #
  # Piping into `grep -q` made this check unable to PASS. Under `pipefail` the
  # refused `ls` exits 2, so the pipeline was non-zero exactly when the wall was
  # working, and `ok` was unreachable — a check whose PASS branch cannot be
  # reached carries no information, which is the mirror of the rule about fail
  # branches. It went unseen because it needs a non-member to run at all, and
  # every claw so far has carried one person.
  #
  # Matching the status also drops a dependency on the English text of `ls`.
  if ! sudo -u "$NONMEMBER" -H bash -c "ls '$WS_DIR'" </dev/null >/dev/null 2>&1; then
    ok "exclusion: ${NONMEMBER} is refused"
  else
    bad "exclusion FAILED -- ${NONMEMBER} can read the workspace; stop before putting work here"
  fi
else
  warn "every unix user is a member: the exclusion control did NOT run. An unrun control is not a passed one."
fi

say ""
say "  Next: replace CLAUDE.md with the workspace's real context; each member opens"
say "  the workspace once in each core. A group change takes effect on next login."

finish
