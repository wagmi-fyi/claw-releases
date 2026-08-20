#!/bin/bash
#
# The wrapper every granted tenant door runs behind. Installed by
# manage-claw-authority.sh, converged by the provisioning run, never edited on a
# claw.
#
# ONE FILE, BYTE-IDENTICAL FOR EVERY DOOR. It takes no substitution and carries
# no door's name. It reads its own path to learn which door it is and reads that
# door's record to learn what it may run. A wrapper rendered per door would be a
# second copy of this logic for every grant a firm makes, and the copies would
# drift silently in the one place a firm cannot afford drift.
#
# WHY A WRAPPER EXISTS AT ALL. Three obligations attach to a granted door and a
# tenant's own script owes none of them: the run is recorded in the member-plane
# log, the bytes that run are the bytes somebody approved, and the door named in
# the sudo grant is root-owned and unwritable by its caller. A tenant script
# installed straight into the grant would satisfy the third and neither of the
# others.
#
# THE APPROVED HASH IS CHECKED ON EVERY RUN, NOT ONLY AT INSTALL. An approval is
# over exact bytes. Checking those bytes once, at install, would make the
# approval a statement about a moment; checking them here makes it a statement
# about what runs. Anything that reached the installed copy afterwards, by any
# route, stops the door instead of running as root.
#
# THE ROW IS WRITTEN BEFORE THE SCRIPT RUNS. `exec` replaces this process, so
# there is no afterwards to write from. The order is also the right one: the
# record is of the decision to run, and a door that hung or took the machine
# down is exactly the run somebody needs to find.
#
# THE ROW CARRIES NO ARGUMENTS. The member-plane log is world-readable and an
# argument is caller-supplied text, so a row echoing one is a world-readable
# copy of whatever a caller typed. `sudo` already records every invocation with
# its full command line and who made it, which is where an argument belongs.
#
set -uo pipefail

# THE WRAPPER RESOLVES ITS OWN TOOLS. It calls `sed`, `stat`, `sha256sum`,
# `basename`, `dirname`, `date` and `id` by bare name, and a bare name is
# resolved through PATH. This is the file named in the sudo grant, so without
# this line the tools that decide whether the approved bytes are the bytes about
# to run come from wherever the caller's PATH points.
#
# `secure_path` in /etc/sudoers is what normally supplies one. It is set by the
# distribution rather than by any CommonClaw file, and nothing in this project
# reads it back, so a claw that lost that line would lose every check below with
# no release reporting anything.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

ADMIN_LOG="/etc/commonclaw/admin-log.md"
AUTHORITY_ROOT="/etc/commonclaw/authority"
DOORS_DIR="${AUTHORITY_ROOT}/doors"
TENANT_DOOR_ROOT="/opt/commonclaw/tenant-doors"

refuse() { printf 'tenant door refused: %s\n' "$*" >&2; exit 1; }

# The wrapper's own path decides which door this is, and it is read from
# BASH_SOURCE rather than from $0. `$0` is argv[0] and a caller can set it to
# anything; BASH_SOURCE is the path the shell opened. Under the sudo grant the
# two agree, because the grant names an exact path and sudo executes that path.
# The check below does not depend on which of them a future caller arranges.
SELF="${BASH_SOURCE[0]}"
case "$SELF" in
  /*) : ;;
  *) refuse "this wrapper was invoked through a relative path. It runs from its installed location or not at all." ;;
esac
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
[ "$SELF_DIR" = "$TENANT_DOOR_ROOT" ] || refuse "this wrapper is running from ${SELF_DIR}, not from ${TENANT_DOOR_ROOT}. A copy of it somewhere else is not a granted door."

NAME="$(basename "$SELF")"
case "$NAME" in
  [a-z]*) : ;;
  *) refuse "'${NAME}' is not a door name: it must start with a lowercase letter." ;;
esac
case "$NAME" in
  *[!a-z0-9-]*) refuse "'${NAME}' is not a door name: lowercase letters, digits and hyphen only." ;;
esac

RECORD="${DOORS_DIR}/${NAME}.json"
SCRIPT="${TENANT_DOOR_ROOT}/${NAME}.script"

[ -f "$RECORD" ] || refuse "no approval on this claw for a door called '${NAME}'. The registry at ${DOORS_DIR} decides what runs, and it holds no record of this one."

WANT="$(sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p' "$RECORD" | head -1)"
case "$WANT" in
  [0-9a-f]*) : ;;
  *) refuse "the record at ${RECORD} carries no usable sha256. The approval cannot be checked, so the door does not open." ;;
esac
[ "${#WANT}" -eq 64 ] || refuse "the record at ${RECORD} carries a sha256 of ${#WANT} characters. The approval cannot be checked, so the door does not open."

# The symlink test comes first and it is the only one here that does not follow
# the link. `-f` resolves what a symlink points at, so a link installed in place
# of the script would pass a check written the other way round and the wrapper
# would run whatever it pointed at.
[ ! -L "$SCRIPT" ] || refuse "${SCRIPT} is a symlink. The approved bytes are a file, and a link is a name for bytes that can change under it."
[ -f "$SCRIPT" ] || refuse "${SCRIPT} is missing. The grant is here and the approved script is not, which is what a restored claw looks like before a provisioning run converges it."
[ "$(stat -c '%a %U:%G' "$SCRIPT")" = "750 root:root" ] || refuse "${SCRIPT} is $(stat -c '%a %U:%G' "$SCRIPT"), not 750 root:root. A script its caller can edit is a grant of everything."

GOT="$(sha256sum "$SCRIPT" | cut -d' ' -f1)"
[ "$GOT" = "$WANT" ] || refuse "the installed bytes of '${NAME}' are not the bytes anybody approved. Approved ${WANT}, found ${GOT}. Nothing ran."

[ -f "$ADMIN_LOG" ] || refuse "no member-plane record at ${ADMIN_LOG}, so this run has nowhere to be written down."

BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac

printf '| %s | %s | ran a tenant door | %s |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BY" "$NAME" >> "$ADMIN_LOG" \
  || refuse "the member-plane row could not be written, so this run stops before it starts."

exec "$SCRIPT" "$@"
