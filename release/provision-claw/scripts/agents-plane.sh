# agents-plane.sh — the agents credential plane on one claw.
#
# SOURCED, never run. It holds one rule that three callers need: where this
# claw's agents-vault token rests, which group may read it, what tells a session
# where it is, where that loader is hooked, and the one command that reads it.
# Phase 8 of provision-claw.sh wires it for the people a build creates,
# onboard-person.sh wires it for everybody who arrives later, and
# install-agents-token.sh puts the value in.
#
# ONE FILE, ONE GROUP, and this is the shape rather than a detail of it. The
# token is a CLAW fact, not a person fact: every person here reads the same
# vault with the same broker token, so a copy per home multiplies one secret
# across every home on the box and rotation then has to reach all of them. The
# token rests in one root-owned file, `agents-cred` is the one group that may
# read it, and a person's home carries a loader and a hook and no value at all.
#
# WHERE IT RESTS IS THE CONTROL. `/var/lib/commonclaw` is outside every path
# the backup rail captures, and `cc_agents_backup_captures` below PROVES that
# against the rail's own answer rather than against a list written here.
#
# NOT UNDER /etc/commonclaw, and that is a refusal rather than a preference.
# That directory is captured by the rail, so a credential written there is in
# every snapshot for the whole retention window and deleting the file undoes
# none of it. It is also the first place somebody reaches for, which is exactly
# why the path has to be named here and read from here.
#
# NO SESSION CARRIES THE VALUE. A session is told the NAME of the file, and the
# value is read inside the one command that needs it. A credential resting in
# every session's environment is one slip away from a transcript the backup rail
# keeps, and this claw measured that slip twice in three days: a grep for the
# variable's name printed the value, and a shell default expansion printed it
# again. A burn should need a deliberate read of the file.
#
# ROTATION IS ONE WRITE, and nothing has to reconnect. The door rewrites this one
# file, and the next read takes the file as it is at that moment, in a session
# opened before the rotation as readily as in one opened after it.
#
# NO VALUE PASSES THROUGH HERE. These functions make the empty plane and read
# what is on disk. The value arrives through the door, and the door is the only
# thing on this claw that ever holds one.
#
# THE HOOK GOES ABOVE THE INTERACTIVE GUARD, and that placement is the whole
# reason the hook is not simply appended. The .bashrc a person's home starts
# with returns early for a non-interactive shell. A remote command
# (`ssh claw 'cmd'`) DOES read .bashrc and then returns at that guard, so a
# loader below it reaches a person typing and reaches nothing else.

# ------------------------------------------------------------ the claw's file

# The one token, the one group that reads it, and the directory it rests in.
# Everything on this claw that names any of the three reads it from here.
CC_AGENTS_STATE_DIR="/var/lib/commonclaw"
CC_AGENTS_TOKEN="${CC_AGENTS_STATE_DIR}/agents-token"
CC_AGENTS_GROUP="agents-cred"

# The one command a person or a session types to read a secret. It lives beside
# the claw's other programs, which are reached by their own path rather than off
# PATH: /opt/commonclaw/bin is on nobody's PATH here, and the drop-in that would
# put it there is read by a login shell and not by a remote command, which is
# the asymmetry this whole plane exists to refuse.
CC_AGENTS_BIN_DIR="/opt/commonclaw/bin"
CC_AGENTS_WRAPPER="${CC_AGENTS_BIN_DIR}/op-agents"

# What the file must be when it is there. Root writes it; the group reads it;
# nobody else sees a byte. Group-read is the whole access model, so the mode is
# stated once and every caller measures against this string.
CC_AGENTS_TOKEN_MODE="640"
CC_AGENTS_TOKEN_OWNER="root:${CC_AGENTS_GROUP}"

# 0755, because members traverse this directory to reach the session bus, and a
# tighter mode here kills the bus on a schedule. Traversal is not read: the
# token's own 0640 is what refuses a non-member, and the refusal is measured
# rather than reasoned about.
CC_AGENTS_STATE_DIR_MODE="0755"

# ------------------------------------------------------- what a person carries

# The paths inside one home. A person's home holds a loader and a hook. It does
# NOT hold a token, and there is no per-home token path for anything to write.
cc_agents_paths() {
  local home="$1"
  CC_AP_DIR="${home}/.config/commonclaw"
  CC_AP_ENV="${CC_AP_DIR}/agent-env.sh"
  CC_AP_BASHRC="${home}/.bashrc"
}

# Where the superseded per-home token used to rest. Named ONLY so the door can
# find one and refuse to leave it there. Nothing writes this path.
cc_agents_legacy_token() {
  printf '%s/.config/commonclaw/agents-token' "$1"
}

# The hook, as one exact line. Compared with grep -qxF, so a stray space makes
# it a different line and the wiring doubles. Nobody edits this string on one
# side alone.
CC_AP_HOOK='[ -r "$HOME/.config/commonclaw/agent-env.sh" ] && . "$HOME/.config/commonclaw/agent-env.sh"'

# The loader. It carries a PATH and never a value, so it is safe to read, diff
# and compare. Every claw writes these exact bytes, and the install compares
# what is there against this text, so a loader wired by hand converges rather
# than surviving beside a second one.
#
# The `-r` test is the access model showing through. A person in `agents-cred`
# reads the file and their session resolves; a person outside it reads nothing
# and their session exports nothing. Same loader, same claw, and the group is
# the only thing that differs.
cc_agents_env_text() {
  cat <<CCENVEOF
# commonclaw: the agents credential plane for this person's sessions.
#
# Carries a PATH and never a value. The token is ONE root-owned file for the
# whole claw:
#   ${CC_AGENTS_TOKEN}   mode ${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER}
# Membership of ${CC_AGENTS_GROUP} is what makes it readable. A person outside
# that group resolves nothing here.
#
# The token is NOT copied into this home. One file rotates in one write, and a
# copy per home would put the value in every home on the box and inside the
# backup rail with it.
#
# WHAT IS EXPORTED IS THE NAME OF THE FILE, NEVER ITS CONTENTS. A credential
# sitting in every session's environment is one slip away from a transcript the
# backup rail keeps: a grep for the variable's name printed the value once, and
# a shell default expansion printed it again three days later. A burn should
# need a deliberate read of the file. This name is safe to print, grep and
# expand.
#
# TO READ A SECRET, take the token inside the one command that needs it:
#   ${CC_AGENTS_WRAPPER} read "op://<vault>/<item>/<field>"
# or, without the wrapper:
#   OP_SERVICE_ACCOUNT_TOKEN="\$(cat "\$COMMONCLAW_AGENTS_TOKEN_FILE")" \\
#     op read "op://<vault>/<item>/<field>"
# The value then lives in that one command's environment and in no shell's.
#
# Sourced from the FIRST line of ~/.bashrc, deliberately ABOVE the interactive
# guard Ubuntu ships there. A non-interactive remote command (ssh host 'cmd')
# does source .bashrc, and then returns at that guard, so anything placed below
# it reaches an interactive session only. A credential plane that works when a
# person types and fails when something automates is the failure this placement
# exists to prevent.
#
# There is nothing to reconnect after a rotation. Each read takes the file as it
# is at that moment.
__cc_token_file="${CC_AGENTS_TOKEN}"
if [ -r "\$__cc_token_file" ]; then
    COMMONCLAW_AGENTS_TOKEN_FILE="\$__cc_token_file"
    export COMMONCLAW_AGENTS_TOKEN_FILE
fi
unset __cc_token_file
CCENVEOF
}

# ------------------------------------------------------------- the refusals

# Refuse to write through anything the person could have pointed elsewhere.
#
# Every path this plane touches sits inside a home its owner controls, so each
# one is checked with -L, which does NOT follow the link, before anything is
# written. `-e` and `-d` resolve what a symlink points at, so a dangling link
# passes them and a live one passes them by answering for its target.
#
# Prints the reason and returns 1 when a path is unsafe. Prints nothing and
# returns 0 otherwise.
cc_agents_plane_unsafe() {
  local person="$1" home="$2" p owner
  cc_agents_paths "$home"

  if [ -L "$home" ]; then
    printf '%s is a symlink. This plane will not be written through one.\n' "$home"; return 1
  fi
  if [ ! -d "$home" ]; then
    printf 'no home at %s\n' "$home"; return 1
  fi
  owner="$(stat -c '%U' "$home" 2>/dev/null || echo '')"
  if [ "$owner" != "$person" ]; then
    printf '%s belongs to %s, not to %s\n' "$home" "${owner:-nobody}" "$person"; return 1
  fi

  for p in "${home}/.config" "$CC_AP_DIR" "$CC_AP_ENV" "$CC_AP_BASHRC"; do
    [ -L "$p" ] || continue
    printf '%s is a symlink. This plane will not be written through one.\n' "$p"; return 1
  done
  return 0
}

# Refuse the claw's own token path when it is not what it must be. The file is
# root-owned in a root-owned directory, so the risks here are different from a
# home's: a symlink placed by root, or a second hard link naming the same bytes
# under a path none of these checks cover.
#
# Prints the reason and returns 1 when the path is unsafe. Silent, 0 otherwise.
cc_agents_token_unsafe() {
  local dir_owner links

  # THE DIRECTORY FIRST, and only the two readings that decide what the paths
  # below even resolve to. A symlinked directory would make every -L test under
  # it answer for somewhere else, so it has to be refused before anything asks
  # about the file.
  if [ -L "$CC_AGENTS_STATE_DIR" ]; then
    printf '%s is a symlink. The claw token will not be written through one.\n' "$CC_AGENTS_STATE_DIR"; return 1
  fi
  if [ -e "$CC_AGENTS_STATE_DIR" ] && [ ! -d "$CC_AGENTS_STATE_DIR" ]; then
    printf '%s exists and is not a directory\n' "$CC_AGENTS_STATE_DIR"; return 1
  fi

  # THEN THE FILE. These come before the ownership reading below so that the
  # message names what is actually wrong with the token: an operator whose token
  # file is a symlink is told that, rather than being told something about a
  # directory that is also true.
  if [ -L "$CC_AGENTS_TOKEN" ]; then
    printf '%s is a symlink. The claw token will not be written through one.\n' "$CC_AGENTS_TOKEN"; return 1
  fi
  if [ -e "$CC_AGENTS_TOKEN" ] && [ ! -f "$CC_AGENTS_TOKEN" ]; then
    printf '%s exists and is not a regular file\n' "$CC_AGENTS_TOKEN"; return 1
  fi
  if [ -f "$CC_AGENTS_TOKEN" ]; then
    links="$(stat -c '%h' "$CC_AGENTS_TOKEN" 2>/dev/null || echo 1)"
    if [ "$links" != "1" ]; then
      printf '%s carries %s hard links, so another path on this claw is the same bytes\n' "$CC_AGENTS_TOKEN" "$links"; return 1
    fi
  fi

  # AND WHO OWNS THE DIRECTORY, last. This is not a path-resolution question, so
  # it does not have to run before the readings above; it is the question of
  # whether anybody but root could have put something here.
  if [ -d "$CC_AGENTS_STATE_DIR" ]; then
    dir_owner="$(stat -c '%U' "$CC_AGENTS_STATE_DIR" 2>/dev/null || echo '')"
    if [ "$dir_owner" != "root" ]; then
      printf '%s belongs to %s, not to root\n' "$CC_AGENTS_STATE_DIR" "${dir_owner:-nobody}"; return 1
    fi
  fi
  return 0
}

# -------------------------------------------------- where a secret may not rest

# Which backup targets, if any, capture the claw token. Prints one target per
# line and returns 0 when the path is captured; prints nothing and returns 1
# when it is not.
#
# THE ANSWER COMES FROM THE RAIL, never from a list written here. The rail names
# its own targets and prints them on demand without touching a credential, so
# this check reads what is actually captured on the day it runs. A copy of the
# list kept here would be right until somebody adds a fifth target, and then it
# would be wrong in the direction that hides a credential inside every snapshot.
#
# AN UNREADABLE RAIL IS NOT A PASS. Returns 2 and prints nothing when the rail
# cannot answer. A caller that treats 2 as "not captured" has replaced a
# measurement with a hope; every caller here fails loudly instead.
cc_agents_backup_captures() {
  local rail="${1:-}" targets t hit=""
  [ -n "$rail" ] || rail="${SCRIPT_DIR:-.}/commonclaw-backup.sh"
  [ -r "$rail" ] || return 2

  targets="$(bash "$rail" targets 2>/dev/null)" || return 2
  [ -n "$targets" ] || return 2

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in /*) : ;; *) continue ;; esac
    # Trailing slashes stripped so /home and /home/ are the one target they are.
    while [ "${t}" != "/" ] && [ "${t%/}" != "$t" ]; do t="${t%/}"; done
    case "$CC_AGENTS_TOKEN" in
      "$t"|"$t"/*) hit="${hit}${t}"$'\n' ;;
    esac
  done <<< "$targets"

  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
  return 0
}

# ------------------------------------------------------------- making it

# Make the empty plane in one home: the directory, the loader, and the hook.
# Idempotent, and it holds no value. Returns 0 when the plane is in place.
#
# Sets CC_AP_MADE to what this call changed, for a caller that reports.
#
# THE CONVERGE WORD IS PRINTED HERE, on stderr, as one line. It was set into
# CC_AP_MADE and no caller read it: phase 8, the onboarding door and the token
# door each report the plane in their own words, and the 1.5.2 apply that
# converged staging's member printed nothing saying so. Found on 2026-09-12.
# One line here reaches all three callers and any later one. It goes to stderr
# because each caller's stdout is its JSON result. No caller runs this function
# inside a command substitution, so the line does not hide CC_AP_MADE from one.
cc_agents_plane_install() {
  local person="$1" home="$2" tmp made=""
  cc_agents_paths "$home"

  [ -d "${home}/.config" ] || { install -d -m 0700 -o "$person" -g "$person" "${home}/.config" || return 1; made="${made} .config"; }
  [ -d "$CC_AP_DIR" ] || { install -d -m 0700 -o "$person" -g "$person" "$CC_AP_DIR" || return 1; made="${made} dir"; }
  chmod 0700 "$CC_AP_DIR" || return 1
  chown "$person":"$person" "$CC_AP_DIR" || return 1

  # The loader, written only when what is there is not these bytes. A person
  # whose loader still names a per-home token gets this one, which is how a
  # claw converges onto the shared file.
  if ! { [ -f "$CC_AP_ENV" ] && cc_agents_env_text | cmp -s - "$CC_AP_ENV"; }; then
    # WHICH LOADER IS BEING REPLACED, read before the write and reported as its
    # own word. A loader that still exports the token VALUE puts a credential in
    # every session this person starts, and replacing it is the convergence this
    # shape exists for. Folded into a plain "loader" it would be invisible in the
    # one run that matters. The reading names the variable and opens nothing.
    if [ -f "$CC_AP_ENV" ] && grep -q 'export OP_SERVICE_ACCOUNT_TOKEN' "$CC_AP_ENV" 2>/dev/null; then
      made="${made} loader-converged"
    else
      made="${made} loader"
    fi
    tmp="$(mktemp "${CC_AP_DIR}/.agent-env.XXXXXX")" || return 1
    cc_agents_env_text > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chown "$person":"$person" "$tmp" && chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f "$tmp" "$CC_AP_ENV" || { rm -f -- "$tmp"; return 1; }
    # Printed once the new loader is in place, so the line never claims a
    # convergence that did not land.
    case "$made" in
      *loader-converged*)
        printf '  loader-converged: %s exported the token value into every session %s started. It now exports the name of %s alone\n' \
          "$CC_AP_ENV" "$person" "$CC_AGENTS_TOKEN" >&2 ;;
    esac
  fi
  chmod 0600 "$CC_AP_ENV" || return 1
  chown "$person":"$person" "$CC_AP_ENV" || return 1

  # The hook, at the TOP of .bashrc rather than appended, because the guard it
  # has to sit above is near the top of the file every home starts with.
  #
  # The new content is composed in root-only scratch and then written back
  # THROUGH the existing file, never renamed onto it. A rename would carry the
  # temp file's own ownership in and leave .bashrc owned by root, which locks
  # the person out of their own shell configuration. A redirect into the file
  # that is already there changes the bytes and touches neither owner nor mode.
  if [ ! -e "$CC_AP_BASHRC" ]; then
    install -m 0644 -o "$person" -g "$person" /dev/null "$CC_AP_BASHRC" || return 1
  fi
  if ! grep -qxF "$CC_AP_HOOK" "$CC_AP_BASHRC" 2>/dev/null; then
    tmp="$(mktemp)" || return 1
    { printf '%s\n' "$CC_AP_HOOK"; cat "$CC_AP_BASHRC"; } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat "$tmp" > "$CC_AP_BASHRC" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    made="${made} hook"
  fi

  CC_AP_MADE="${made# }"
  return 0
}

# ------------------------------------------------------------ the one command

# The wrapper's bytes. It holds no value: it reads the claw's file inside its
# own process and becomes `op`, so the caller's shell never carries the token
# and no expansion of the caller's can print one.
#
# ITS REFUSAL NAMES THE CAUSE IT MEASURED. It said "membership of agents-cred is
# what makes it readable" on staging, where the member was in the group and the
# file had never existed. Found on 2026-09-12. It now tests existence and
# readability apart.
#
# Every claw writes these exact bytes and the install compares against this
# text, for the same reason the loader does.
cc_agents_wrapper_text() {
  cat <<CCWRAPEOF
#!/bin/bash
# commonclaw: read this claw's agents vault.
#
# THE TOKEN IS TAKEN FROM THE CLAW'S OWN FILE INSIDE THIS ONE COMMAND. It goes
# into this process's environment and this process becomes \`op\`. Your shell
# never holds the value, so nothing you type in that shell can print it.
#
#   ${CC_AGENTS_WRAPPER} read "op://<vault>/<item>/<field>"
#
# Every argument is handed to \`op\` unchanged.
#
# Reached by this path and not off PATH, like the other programs in
# ${CC_AGENTS_BIN_DIR}. A PATH drop-in is read by a login shell and not by a
# remote command, and a credential plane that works when a person types and
# fails when something automates is the failure this plane refuses.
set -u

__f="\${COMMONCLAW_AGENTS_TOKEN_FILE:-${CC_AGENTS_TOKEN}}"
# ABSENT AND UNREADABLE ARE TWO CAUSES, and each has its own sentence. Absent is
# said only when the directory can be searched, because only then is the
# absence measured.
if [ ! -e "\$__f" ] && [ -x "\$(dirname -- "\$__f")" ]; then
    printf 'op-agents: this claw has no agents token at %s, so nothing here resolves\\n' "\$__f" >&2
    printf 'op-agents: a person with root installs one for the whole claw with install-agents-token.sh. Joining a group changes nothing until it is there\\n' >&2
    exit 1
fi
if [ ! -r "\$__f" ]; then
    printf 'op-agents: you cannot read the agents token at %s\\n' "\$__f" >&2
    printf 'op-agents: membership of ${CC_AGENTS_GROUP} is what makes it readable, and a group added reaches only a process that starts after it. /etc/commonclaw/workspace-conventions.md says what ends the old ones, under Access\\n' >&2
    exit 1
fi

OP_SERVICE_ACCOUNT_TOKEN="\$(cat "\$__f")"
export OP_SERVICE_ACCOUNT_TOKEN
if [ -z "\${OP_SERVICE_ACCOUNT_TOKEN:+set}" ]; then
    printf 'op-agents: the agents token at %s is empty, so this claw resolves nothing\\n' "\$__f" >&2
    exit 1
fi
unset __f

exec op "\$@"
CCWRAPEOF
}

# Put the one command on the claw. Idempotent, root-owned, world-executable
# because every member runs it and none of them may rewrite it.
#
# Sets CC_AGENTS_WRAPPER_MADE to 'wrapper' when this call changed the bytes, and
# CC_AGENTS_WRAPPER_WHY to the reason when it returns 1.
#
# IT PRINTS NOTHING, and that is what lets a caller read those two. A caller that
# had to take the reason off stdout would run this in a command substitution,
# which is a subshell, and the variables would never reach it.
cc_agents_wrapper_install() {
  local tmp
  CC_AGENTS_WRAPPER_MADE=""
  CC_AGENTS_WRAPPER_WHY=""

  if [ -L "$CC_AGENTS_BIN_DIR" ] || [ -L "$CC_AGENTS_WRAPPER" ]; then
    CC_AGENTS_WRAPPER_WHY="${CC_AGENTS_BIN_DIR} or ${CC_AGENTS_WRAPPER} is a symlink, and the one command will not be written through one"
    return 1
  fi

  install -d -m 0755 -o root -g root "$CC_AGENTS_BIN_DIR" 2>/dev/null || {
    CC_AGENTS_WRAPPER_WHY="could not make ${CC_AGENTS_BIN_DIR}"; return 1; }

  if [ -f "$CC_AGENTS_WRAPPER" ] && cc_agents_wrapper_text | cmp -s - "$CC_AGENTS_WRAPPER"; then
    chown root:root "$CC_AGENTS_WRAPPER" 2>/dev/null && chmod 0755 "$CC_AGENTS_WRAPPER" 2>/dev/null || {
      CC_AGENTS_WRAPPER_WHY="the bytes at ${CC_AGENTS_WRAPPER} are right and its owner or mode could not be set"; return 1; }
    return 0
  fi

  tmp="$(mktemp "${CC_AGENTS_BIN_DIR}/.op-agents.XXXXXX" 2>/dev/null)" || {
    CC_AGENTS_WRAPPER_WHY="could not make scratch in ${CC_AGENTS_BIN_DIR}"; return 1; }
  cc_agents_wrapper_text > "$tmp" 2>/dev/null || {
    rm -f -- "$tmp"; CC_AGENTS_WRAPPER_WHY="could not write the wrapper bytes"; return 1; }
  chown root:root "$tmp" 2>/dev/null && chmod 0755 "$tmp" 2>/dev/null || {
    rm -f -- "$tmp"; CC_AGENTS_WRAPPER_WHY="could not set owner or mode on the new wrapper"; return 1; }
  mv -f "$tmp" "$CC_AGENTS_WRAPPER" 2>/dev/null || {
    rm -f -- "$tmp"; CC_AGENTS_WRAPPER_WHY="could not move the new wrapper into place"; return 1; }
  CC_AGENTS_WRAPPER_MADE="wrapper"
  return 0
}

# What the claw's one command is, in one word.
#
#   absent   nothing there: a session has only the long form
#   stale    something there, and it is not what this release writes
#   current  the bytes this release writes
cc_agents_wrapper_state() {
  if [ -f "$CC_AGENTS_WRAPPER" ] && cc_agents_wrapper_text | cmp -s - "$CC_AGENTS_WRAPPER"; then
    printf 'current'; return 0
  fi
  [ -e "$CC_AGENTS_WRAPPER" ] && { printf 'stale'; return 0; }
  printf 'absent'
}

# --------------------------------------------------------------- reading it

# What one person's home holds, in one word. This says nothing about whether
# they can READ the token: that is group membership, and `cc_agents_reads`
# answers it.
#
#   absent  no loader and no hook: this person has no plane
#   wired   the loader is there and hooked
cc_agents_plane_state() {
  local home="$1"
  cc_agents_paths "$home"
  if [ -f "$CC_AP_ENV" ] && grep -qxF "$CC_AP_HOOK" "$CC_AP_BASHRC" 2>/dev/null; then
    printf 'wired'; return 0
  fi
  printf 'absent'
}

# Whether this person is in the group that reads the token. The claw's own
# record decides, never an argument and never a file mode read twice.
cc_agents_reads() {
  local person="$1" groups
  groups=" $(id -nG "$person" 2>/dev/null || true) "
  case "$groups" in
    *" ${CC_AGENTS_GROUP} "*) return 0 ;;
    *) return 1 ;;
  esac
}

# What the claw's token file holds, in one word. It opens nothing and prints no
# byte of the file.
#
#   absent   no token on this claw: nobody here resolves anything
#   present  a token is there
cc_agents_token_state() {
  [ -s "$CC_AGENTS_TOKEN" ] && { printf 'present'; return 0; }
  printf 'absent'
}
