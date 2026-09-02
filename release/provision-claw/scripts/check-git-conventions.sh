#!/bin/bash
#
# check-git-conventions.sh -- measure one repository against the claw's git
# conventions.
#
# The conventions are in templates/workspace-conventions.md, sections "The
# layout", "Credentials" and "Git here". This script does not restate them. It
# tests the ones a machine can test, names each rule it applies, and says out
# loud which ones it cannot reach.
#
# READ-ONLY. It never writes into the repository it measures, and it never
# touches the network. Nothing here is a fix.
#
#   check-git-conventions.sh <repo>          measure one repository
#   check-git-conventions.sh --all <root>    measure every repository under a root
#
# Exit 0 = conforms. Exit 1 = at least one violation. Exit 2 = it could not
# measure (not a repository, unreadable, bad arguments). Exit 2 is never a pass:
# a check that could not run has found nothing, which is not the same as clean.
#
# WHICH RULES BIND WHICH REPOSITORY. The layout is the shape of a WORKSPACE
# ROOT, which is a directory one level under the workspaces root. A git
# repository nested deeper is a project inside a workspace and carries no
# manifest and no briefing, so the two layout rules are not applied to it. A
# check that applied them everywhere would report a defect for every nested
# project on the claw and train its reader to ignore it.
#
# THE RULES, and the name each violation carries:
#
#   head-born          HEAD resolves to a commit. An unborn HEAD is a session
#                      that parked without committing, and its work is
#                      invisible to the next one.
#   identity           user.name, user.email and user.useConfigOnly all resolve
#                      here. useConfigOnly is what turns an invented identity
#                      into a refusal.
#   remote-trigger     a remote is configured and the repository has no root
#                      REMOTE.md. That file is where the convention puts the
#                      statement, so its presence is what this rule tests.
#   vendored-tracked   node_modules or .venv is tracked. Dependencies belong to
#                      the project on the project's clock, never in history.
#   database-tracked   database/ exists and is tracked or not ignored. The
#                      backup rail protects it and git cannot merge it.
#   credential         a tracked file carries something shaped like a secret.
#                      The match is NEVER printed, only its file and line.
#   two-copies         AGENTS.md exists and is not a symlink to CLAUDE.md, or
#                      .agents/skills exists and is not a symlink to
#                      .claude/skills. Two files for one briefing drift.
#   manifest           workspace root only: .workspace.yaml is absent.
#   briefing           workspace root only: CLAUDE.md is absent.
#
# WHAT IT CANNOT REACH, named rather than passed over silently:
#
#   Never amend, never force-push. A rewrite leaves the same shape behind as
#   history that was never rewritten. Only a reflog or a second copy sees it,
#   and neither is here.
#
#   Stage hunks, not the tree. Batch. What a commit contains is visible; the
#   act that assembled it is not.
#
#   The Co-Authored-By trailer on an agent's commits. An agent's commit and a
#   person's commit carry the same author, deliberately, so nothing in the
#   history says which commits the rule applies to.
#
#   One worktree per concurrent editor. A lane is only wrong while two live
#   sessions share it, and liveness is not in the repository.
#
# WHAT remote-trigger READS. The convention puts the statement in a root
# REMOTE.md and says every repository with a remote carries one. This rule
# tests for that file and nothing else. It does not grade the wording, because
# a person writes the reason and a machine has no standing to mark it.
#
set -uo pipefail

TRIGGER_DOC="REMOTE.md"

# High-signal only. A pattern that fires on prose teaches its reader to ignore
# it, and the cost of a missed secret is paid once while the cost of a noisy
# one is paid every run. Each requires the full length of a real value, so a
# document naming a token prefix does not match.
#
# The PEM header is anchored to the start of a line because that is where a
# real key file puts it. A sentence that quotes the header mid-line is writing
# about keys, and this claw's own work includes writing about keys.
#
# THIS IS NOT AN ALLOWLIST AND MUST NOT BECOME ONE WITHOUT A RULING. A file
# that legitimately carries a value of the right shape -- a scanner's own test
# fixture, a vendor's published documentation placeholder -- is reported and
# dismissed by its reader. The convention names no way to mark such a file, so
# this script invents none.
SECRET_PATTERNS='^-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{12,}|sk-ant-[A-Za-z0-9_-]{24,}'

WORKSPACES_ROOT="${WORKSPACES_ROOT:-/srv/workspaces}"

usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2; }

repo_rc=0
violate() { printf 'VIOLATION %s  %s: %s\n' "$1" "$2" "$3"; repo_rc=1; }
note()    { printf 'NOTE      %s\n' "$1"; }

g() { git --no-optional-locks -C "$REPO" "$@" 2>/dev/null; }

# ------------------------------------------------------------------ one repo
check_repo() {
  REPO="$1"

  [ -d "$REPO" ] || { printf 'CANNOT   %s: no such directory\n' "$REPO"; return 2; }
  [ -d "$REPO/.git" ] || { printf 'CANNOT   %s: not a git repository (no .git directory)\n' "$REPO"; return 2; }
  if ! g rev-parse --git-dir >/dev/null; then
    printf 'CANNOT   %s: git refuses to read it (ownership, permissions, or a damaged repository)\n' "$REPO"
    return 2
  fi

  repo_rc=0
  local abs parent kind
  abs="$(cd "$REPO" && pwd -P)"
  parent="$(dirname "$abs")"
  if [ "$parent" = "$(cd "$WORKSPACES_ROOT" 2>/dev/null && pwd -P || echo "$WORKSPACES_ROOT")" ]; then
    kind="workspace root"
  else
    kind="project"
  fi
  printf '\n== %s  (%s)\n' "$abs" "$kind"

  # -- head-born
  if ! g rev-parse --verify HEAD >/dev/null; then
    violate head-born "HEAD" "no commit exists; a session parked without committing"
  fi

  # -- identity
  local k
  for k in user.name user.email user.useConfigOnly; do
    if [ -z "$(g config --get "$k")" ]; then
      violate identity "$k" "not set for this repository"
    fi
  done

  # -- remote-trigger
  local r url
  for r in $(g remote); do
    url="$(g remote get-url "$r")"
    if [ -f "$REPO/$TRIGGER_DOC" ]; then
      note "remote '$r' -> $url; trigger stated in $TRIGGER_DOC"
    else
      violate remote-trigger "$r -> $url" \
        "a remote is configured and there is no root $TRIGGER_DOC. The convention says the statement lives in that file and that every repository with a remote carries one"
    fi
  done

  # -- vendored-tracked
  local hit
  for hit in node_modules .venv; do
    if g ls-files -- "$hit" "*/$hit" | head -1 | grep -q .; then
      violate vendored-tracked "$hit" "tracked in git; dependencies belong to the project, not to history"
    fi
  done

  # -- database-tracked
  if [ -d "$REPO/database" ]; then
    if g ls-files -- database | head -1 | grep -q .; then
      violate database-tracked "database/" "tracked in git"
    elif ! g check-ignore -q database; then
      violate database-tracked "database/" "exists and is not git-ignored"
    fi
  fi

  # -- two-copies
  if [ -e "$REPO/AGENTS.md" ] && [ ! -L "$REPO/AGENTS.md" ]; then
    violate two-copies "AGENTS.md" "a regular file, not a symlink to CLAUDE.md"
  fi
  if [ -e "$REPO/.agents/skills" ] && [ ! -L "$REPO/.agents/skills" ]; then
    violate two-copies ".agents/skills" "a regular directory, not a symlink to .claude/skills"
  fi

  # -- credential. The matching value is never printed.
  #
  # -e is not optional. The pattern set begins with a dash, so without it git
  # reads the pattern as an option, refuses, and the rule passes having
  # searched nothing. That silence is why the exit status is inspected below:
  # git grep answers 1 for "no match" and 2 or more for "could not look", and
  # a check that cannot look has not found the repository clean.
  local line rest file lno grc
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"; rest="${line#*:}"; lno="${rest%%:*}"
    violate credential "$file:$lno" "a tracked line matches a secret pattern (value withheld)"
  done < <(g grep -n -I -E -e "$SECRET_PATTERNS" -- . | cut -d: -f1,2)
  g grep -q -I -E -e "$SECRET_PATTERNS" -- . ; grc=$?
  if [ "$grc" -gt 1 ]; then
    violate credential "(the scan)" "git grep could not run, so nothing was searched"
  fi

  # -- workspace-root-only rules
  if [ "$kind" = "workspace root" ]; then
    [ -f "$REPO/.workspace.yaml" ] || violate manifest ".workspace.yaml" "absent from a workspace root"
    [ -f "$REPO/CLAUDE.md" ] || violate briefing "CLAUDE.md" "absent from a workspace root"
  fi

  [ "$repo_rc" -eq 0 ] && printf 'PASS      %s\n' "$abs"
  return "$repo_rc"
}

# --------------------------------------------------------------------- entry
case "${1:-}" in
  -h|--help|"") usage ;;
  --all)
    root="${2:-}"
    [ -n "$root" ] || usage
    [ -d "$root" ] || { printf 'CANNOT   %s: no such directory\n' "$root" >&2; exit 2; }
    rc=0; seen=0
    while IFS= read -r d; do
      seen=$((seen+1))
      check_repo "$d"; r=$?
      [ "$r" -eq 0 ] || rc=1
    done < <(find "$root" -name .git -type d -prune 2>/dev/null | sed 's|/\.git$||' | sort)
    printf '\n-- %s repositories measured under %s\n' "$seen" "$root"
    if [ "$seen" -eq 0 ]; then
      printf 'CANNOT   no repository found under %s -- nothing was measured\n' "$root" >&2
      exit 2
    fi
    exit "$rc"
    ;;
  -*) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  *)
    check_repo "$1"; exit $?
    ;;
esac
