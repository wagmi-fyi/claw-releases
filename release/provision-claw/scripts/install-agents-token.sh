#!/bin/bash
#
# install-agents-token.sh — install or rotate THIS CLAW's agents-vault
# service-account token, without it passing through a screen, a shell history,
# or an argument.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   The caller drops the token, then opens the door.
#
#     (umask 077; op read "op://{hostname}-agents/{hostname}-agents-broker-service-token/credential" \
#        > /run/user/$(id -u)/commonclaw-agents-token)
#     sudo ./install-agents-token.sh
#
#   From a machine where the manager is unlocked, which is the path that works
#   before anybody on this claw resolves anything:
#
#     op read "op://{hostname}-agents/{hostname}-agents-broker-service-token/credential" \
#       | ssh {claw} 'umask 077; cat > /run/user/$(id -u)/commonclaw-agents-token'
#     ssh {claw} 'sudo /opt/commonclaw/provision-claw/scripts/install-agents-token.sh'
#
#   --dry-run   check the drop, the group and the claw; change nothing, read no token
#
# ONE FILE FOR THE WHOLE CLAW. The token rests at the path `agents-plane.sh`
# names, root-owned, group-read by `agents-cred`, and nowhere else. It takes no
# person argument because there is nothing per-person to install: a person
# reads this file or does not, and their membership of that group is the only
# thing that decides. Rotation is therefore one write, and this door is what
# does it.
#
# WHY THIS DOOR EXISTS. Two service-account tokens live on a claw. The MACHINE
# token is walled inside the backup unit and `install-machine-token.sh` is its
# door. The AGENTS token is the one a person's own session resolves `op://`
# references with while they work, and until this door it had no path at all:
# it was wired by hand on the first claw and by nothing anywhere else. A person
# created by every other door here -- correct account, correct groups, correct
# home -- found every credential lookup in their session failing, and nothing
# in the onboarding said why. The plane the person is missing is not a fault of
# theirs to find.
#
# THE DROP PATH IS NOT AN ARGUMENT, and that is a control rather than a
# convenience. A caller-supplied path would let a member name any file root can
# read and have this script install it and then DESTROY it. The path is
# composed from the caller's own uid and nothing else.
#
# WHAT THIS DOOR REFUSES, AND THE FIRST ONE IS THE WALL.
#
# 1. A TOKEN THAT OPENS THE MACHINE VAULT IS REFUSED. The machine vault holds
#    the repository password and the object-store key, so anything holding that
#    token can delete this claw's backups. The whole justification for two
#    vaults is that a safety net must not be openable from inside the thing it
#    is catching, and a machine token installed into a person's session
#    collapses the wall completely -- silently, because everything would work.
#    This door reads the vault list the offered token can see and refuses when
#    the machine vault is in it.
#
# 2. A TOKEN THAT DOES NOT OPEN THE AGENTS VAULT IS REFUSED. A token proves
#    itself by resolving something real, never by its length or its prefix,
#    because both pass on a credential holding the wrong bytes.
#
# 3. CONVERGING WITHOUT ROTATING IS REFUSED, and this is the refusal that
#    decides whether the move to one file is real or cosmetic. A claw built
#    before this shape carried a COPY OF THE TOKEN IN EVERY HOME, and homes are
#    captured by the backup rail. Deleting those copies removes them from the
#    disk and from nothing else: every snapshot still inside the retention
#    window holds the value, and the value still opens the vault. So a claw
#    that has per-home copies may only converge onto a token it has NOT used
#    before. This door reads the digest of every copy it is about to remove and
#    refuses an offered token that matches one of them. Re-siting the old value
#    is exactly the move that looks like a fix and is not one.
#
# 4. A TOKEN PATH THE BACKUP RAIL CAPTURES IS REFUSED. Where this credential
#    rests is the control, so it is measured against the rail's OWN answer,
#    read from the rail at the moment of the write. A rail that cannot answer
#    fails the run: an unrun control is not a passed one.
#
# 5. WRITING THROUGH A SYMLINK OR A SECOND HARD LINK, at the claw path and in
#    every home this door touches.
#
# VERIFY BEFORE YOU BURN, at both ends. Gate 1 runs before this claw moves at
# all, so a wrong token dies with the previous credential untouched and the
# caller still holding their only copy. Gate 2 runs at the surface that
# CONSUMES the token: a shell start as a member of the group, taken both ways a
# session begins here, plus the manager resolving with the bytes read back off
# the disk, plus a non-member proving the group boundary is real. Only then is
# the drop copy destroyed and the superseded per-home copies removed.
#
# AND THE CONTROL THAT MAKES GATE 2 MEAN SOMETHING. Before the write, the same
# probe runs and must find something OTHER than the new token. A probe whose
# pass branch is the only one ever reached is narration.
#
# THE VALUE APPEARS NOWHERE. Not in output, not in an error, not in a log line.
# Lengths and digests only. This script's own output is a publication surface,
# so every line it prints -- including every failure path and every message
# captured from another tool -- goes through one scrubber.
#
# THE CONTRACT. Where the token rests, which group reads it, what loads it and
# where that loader is hooked belong to `agents-plane.sh` beside this script.
# Phase 8 of provision-claw.sh and onboard-person.sh make the per-person half
# of that plane and grant the group; this door fills the claw's half. None of
# the three may move a path alone, which is why there is one copy of them and
# all three source it.
#
set -euo pipefail

DRY_RUN=0

# The caller's environment decides nothing here. A claw-admin running this door
# has an agents token of their own exported into their session, and a gate that
# resolved with it would prove the offered token good whatever it holds.
unset OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_ACCOUNT || true
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ETC_ROOT="/etc/commonclaw"
PROVISION_CONF="${ETC_ROOT}/provision.conf"
ADMIN_LOG="${ETC_ROOT}/admin-log.md"
MEMBERS_GROUP="claw-members"
DROP_NAME="commonclaw-agents-token"
BACKUP_RAIL="${SCRIPT_DIR}/commonclaw-backup.sh"

# Root-only scratch, memory-backed, for the same reason the drop is: what passes
# through here must not reach the disk and must not survive a reboot.
WORKDIR="/run/commonclaw-agents"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; TOKEN=""; DROP=""; AGENTS_VAULT=""; MACHINE_VAULT=""
PROBE_PERSON=""; PROBE_HOME=""; CONVERGED=0
LEGACY_HOMES=(); LEGACY_PEOPLE=()

# ---------------------------------------------------------------- the scrubber
#
# One function, applied to every line this script emits. A redaction placed per
# call site is a redaction somebody adds a call site past; the failure paths are
# where a value most often escapes, and they are the paths written last.
scrub() {
  local s="$1"
  [ -n "$TOKEN" ] && s="${s//"$TOKEN"/<redacted>}"
  printf '%s' "$s"
}

say()  { printf '%s\n' "$(scrub "$*")" >&2; }
ok()   { local m; m="$(scrub "$*")"; printf '  OK    %s\n' "$m" >&2; CHK_DESC+=("$m"); CHK_OK+=(true); return 0; }
bad()  { local m; m="$(scrub "$*")"; printf '  FAIL  %s\n' "$m" >&2; CHK_DESC+=("$m"); CHK_OK+=(false); FAILED=1; return 0; }
warn() { local m; m="$(scrub "$*")"; printf '  note  %s\n' "$m" >&2; NOTES+=("$m"); return 0; }
refuse() { say "$*"; exit 1; }

json_esc() {
  local s
  s="$(scrub "$1")"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_json() {
  local i first
  printf '{\n'
  printf '  "script": "install-agents-token",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "token_path": "%s",\n' "$(json_esc "${CC_AGENTS_TOKEN:-}")"
  printf '  "group": "%s",\n' "$(json_esc "${CC_AGENTS_GROUP:-}")"
  printf '  "agents_vault": "%s",\n' "$(json_esc "$AGENTS_VAULT")"
  printf '  "drop_path": "%s",\n' "$(json_esc "$DROP")"
  printf '  "probed_member": "%s",\n' "$(json_esc "$PROBE_PERSON")"
  printf '  "converged": %s,\n' "$([ "$CONVERGED" -eq 1 ] && echo true || echo false)"
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

# Whatever happens, the token leaves this process's memory and the scratch tree
# goes with it. The drop copy is NOT removed here: burning it is a decision the
# success path takes, and an exit on any other path must leave the caller
# holding their only copy.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() { TOKEN=""; rm -rf -- "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { printf 'run this as root\n' >&2; exit 1; }

# shellcheck source=agents-plane.sh
[ -r "${SCRIPT_DIR}/agents-plane.sh" ] \
  || { printf 'no agents-plane.sh beside this script -- a missing sibling fails the run rather than being skipped\n' >&2; exit 1; }
. "${SCRIPT_DIR}/agents-plane.sh"

for t in op jq sha256sum install stat runuser; do
  command -v "$t" >/dev/null 2>&1 || refuse "this claw has no ${t}, which this door needs"
done

[ -r "$PROVISION_CONF" ] \
  || refuse "no ${PROVISION_CONF}: this claw does not know its own name, so the vault this token must open cannot be composed. Run the provisioning plane first."
[ -f "$ADMIN_LOG" ] \
  || refuse "no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down. The log is seeded by provisioning."

# The claw's own name, from the box's own record. Never from an argument and
# never from the environment: identity belongs to a build, and a passed name
# would let a caller aim this door's proof at a vault nobody chose.
BOX_HOSTNAME="$(sed -n 's/^BOX_HOSTNAME=//p' "$PROVISION_CONF" | head -1)"
case "$BOX_HOSTNAME" in
  ''|*[!a-z0-9.-]*) refuse "${PROVISION_CONF} carries no usable BOX_HOSTNAME, so the vault name cannot be composed" ;;
esac
AGENTS_VAULT="${BOX_HOSTNAME}-agents"
MACHINE_VAULT="${BOX_HOSTNAME}-machine"

# The group, refused rather than created. Groups belong to provisioning, and a
# door that made one would be a second owner of the claw's access model.
getent group "$CC_AGENTS_GROUP" >/dev/null 2>&1 \
  || refuse "no ${CC_AGENTS_GROUP} group on this claw. That group IS the read boundary on this token, so this door will not write the file without it. Run the provisioning plane, which creates it."
getent group "$MEMBERS_GROUP" >/dev/null 2>&1 \
  || refuse "no ${MEMBERS_GROUP} group on this claw, so nothing here says who the people are. Run the provisioning plane first."

if unsafe="$(cc_agents_token_unsafe)"; then :; else
  refuse "REFUSED: ${unsafe}"
fi

# THE DIRECTORY'S MODE BELONGS TO PROVISIONING, so this door reads it and
# refuses rather than repairing it. Two writers of one mode is how the two
# disagree, and the other writer's reason is the session bus, which lives under
# the same root and dies when that mode tightens.
#
# An ABSENT directory is different: there is no other writer to disagree with,
# so this door creates it at the mode provisioning asserts.
if [ -d "$CC_AGENTS_STATE_DIR" ]; then
  dir_now="$(stat -c '%a %U:%G' "$CC_AGENTS_STATE_DIR")"
  [ "$dir_now" = "755 root:root" ] \
    || refuse "${CC_AGENTS_STATE_DIR} is ${dir_now}, not 755 root:root. A member cannot traverse it, so a token written inside it would be unreadable to everybody in ${CC_AGENTS_GROUP}. That mode belongs to the provisioning run, which also puts the session bus under this root; run provisioning rather than having this door change it."
fi

# ---- the caller, and therefore the drop path ----
#
# From the uid sudo recorded, never from the environment: XDG_RUNTIME_DIR is
# caller-settable, and a caller-settable drop path is the hole this door must
# not have.
CALLER_UID="${SUDO_UID:-$(id -u)}"
case "$CALLER_UID" in ''|*[!0-9]*) refuse "cannot determine the calling uid" ;; esac
# Two patterns, because a shell case pattern is anchored at both ends and a
# trailing star therefore means "anything at all" rather than more of the class
# before it. The negative match is the one that decides. This value is written
# into a world-readable record.
BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z_]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac

DROP_DIR="/run/user/${CALLER_UID}"
DROP="${DROP_DIR}/${DROP_NAME}"

# ---- who this claw's people are, and which of them read the token ----
#
# The member probe is a REAL person, because the leg it serves is a session
# start and a system account has none. The first one in the group with a wired
# plane is enough: the file is one file, so a second member proves nothing the
# first did not.
while IFS=: read -r u _ uid _ _ home _; do
  [ "$uid" -ge 1000 ] 2>/dev/null || continue
  [ "$uid" -lt 65000 ] 2>/dev/null || continue
  [ -d "$home" ] || continue
  if [ -f "$(cc_agents_legacy_token "$home")" ]; then
    LEGACY_HOMES+=("$home"); LEGACY_PEOPLE+=("$u")
  fi
  [ -n "$PROBE_PERSON" ] && continue
  cc_agents_reads "$u" || continue
  [ "$(cc_agents_plane_state "$home")" = "wired" ] || continue
  PROBE_PERSON="$u"; PROBE_HOME="$home"
done < <(getent passwd)

# ---- the drop ----

if [ ! -d "$DROP_DIR" ]; then
  say "no runtime directory at ${DROP_DIR}."
  say "It exists while you have a live login session. Reconnect, then drop the token and run this again."
  exit 1
fi

# tmpfs is the whole guarantee that this path never reaches the disk, so assert
# it rather than assume it. It also closes a quieter hole: tmpfs is a SEPARATE
# filesystem, so a hard link from the drop path to a root-owned file elsewhere
# is impossible, and symlinks are refused outright below.
DROP_FS="$(stat -f -c '%T' "$DROP_DIR" 2>/dev/null || echo unknown)"
[ "$DROP_FS" = "tmpfs" ] \
  || refuse "${DROP_DIR} is on ${DROP_FS}, not tmpfs. Refusing: a token dropped there could reach the disk."
[ "$(stat -c '%u' "$DROP_DIR")" = "$CALLER_UID" ] \
  || refuse "${DROP_DIR} does not belong to the calling uid"

if [ ! -e "$DROP" ]; then
  say "no token at ${DROP}."
  say "Drop the token first, then run this again. From a machine where your manager is"
  say "unlocked, because a session on this claw cannot reach one until this door has run:"
  say ""
  say "  op read \"op://${AGENTS_VAULT}/${AGENTS_VAULT}-broker-service-token/credential\" \\"
  say "    | ssh $(hostname) 'umask 077; cat > ${DROP}'"
  say ""
  say "The path is fixed and the file must be yours, regular, and unreadable by anyone else."
  exit 1
fi

# The path checks, then the same checks again on the OPEN file, so a swap
# between the two cannot decide what gets read. The second set is the one that
# counts; the first only produces a better message.
[ ! -L "$DROP" ] || refuse "${DROP} is a symlink. Refusing: this door reads a file you wrote, not a file you pointed at."
[ -f "$DROP" ]   || refuse "${DROP} is not a regular file"

exec 9<"$DROP"
# Everything below reads the descriptor, never the name. /proc/self/fd/9
# resolves to the inode that was actually opened, so a path swapped after the
# checks above cannot change what is read.
[ -f /proc/self/fd/9 ] || refuse "the opened drop is not a regular file"
FD_UID="$(stat -L -c '%u' /proc/self/fd/9 2>/dev/null || echo "")"
FD_MODE="$(stat -L -c '%a' /proc/self/fd/9 2>/dev/null || echo "")"
FD_SIZE="$(stat -L -c '%s' /proc/self/fd/9 2>/dev/null || echo "")"
[ -n "$FD_UID" ] && [ -n "$FD_MODE" ] && [ -n "$FD_SIZE" ] \
  || refuse "cannot inspect the opened drop file"

[ "$FD_UID" = "$CALLER_UID" ] \
  || refuse "the opened drop belongs to uid ${FD_UID}, not to you. Refusing: this door installs your token, not somebody else's file."
[ $(( 8#${FD_MODE} & 8#077 )) -eq 0 ] \
  || refuse "the drop file is mode ${FD_MODE}, readable beyond you. Drop it under umask 077 and mint a fresh token: this one was exposed."
case "$FD_SIZE" in ''|*[!0-9]*) refuse "cannot size the opened drop file" ;; esac
[ "$FD_SIZE" -gt 0 ] || refuse "the drop file is empty"
[ "$FD_SIZE" -le 65536 ] || refuse "the drop file is ${FD_SIZE} bytes, far larger than a token. Refusing rather than guessing what it is."

WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TOKEN_STATE="$(cc_agents_token_state)"

say ""
say "=== install the agents token for this claw ==="
say "  drop:    ${DROP}  (${FD_SIZE} bytes, tmpfs, ${FD_MODE}, uid ${FD_UID})"
say "  target:  ${CC_AGENTS_TOKEN}  (${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER})"
say "  reads:   members of ${CC_AGENTS_GROUP}, and nobody else"
say "  vault:   ${AGENTS_VAULT}   (and ${MACHINE_VAULT} must NOT open)"
say "  on disk: ${TOKEN_STATE}"
say "  by:      ${BY}"
if [ "${#LEGACY_HOMES[@]}" -gt 0 ]; then
  say ""
  say "  CONVERGING. ${#LEGACY_HOMES[@]} home(s) still carry a per-home copy of this claw's token:"
  say "    ${LEGACY_PEOPLE[*]}"
  say "  Homes are captured by the backup rail, so those copies are inside every snapshot"
  say "  still in retention and deleting them changes none of that. This run therefore"
  say "  requires a token this claw has NOT used before, and refuses one that matches a"
  say "  copy it is about to remove."
fi
say ""

if [ "$DRY_RUN" -eq 1 ]; then
  exec 9<&-
  ACTION="would-install"
  say "  would prove the offered token opens ${AGENTS_VAULT} and does NOT open ${MACHINE_VAULT}"
  if [ "${#LEGACY_HOMES[@]}" -gt 0 ]; then
    say "  would refuse an offered token matching the live file or any of the ${#LEGACY_HOMES[@]} per-home copies"
  fi
  say "  would write ${CC_AGENTS_TOKEN} at ${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER}"
  say "  would refuse outright if ${CC_AGENTS_STATE_DIR} were not 755 root:root, because a member could not traverse it"
  say "  would prove that path is captured by NO backup target, asked of ${BACKUP_RAIL} itself"
  if [ -n "$PROBE_PERSON" ]; then
    say "  would prove a session start as ${PROBE_PERSON} (in ${CC_AGENTS_GROUP}) exports it, both ways a session begins here"
  else
    say "  would find NO member of ${CC_AGENTS_GROUP} with a wired plane to probe, and say so rather than skip it"
  fi
  say "  would prove a non-member reads nothing from that path"
  say "  would prove the bytes read back off the disk still open ${AGENTS_VAULT}"
  if [ "${#LEGACY_HOMES[@]}" -gt 0 ]; then
    say "  would then remove the ${#LEGACY_HOMES[@]} per-home copies and rewrite those loaders"
  fi
  say "  would destroy ${DROP} only after all of that"
  warn "dry run: the token was not read, and nothing was written"
  finish
fi

# ---------------------------------------------------------------- the token

# Read from the verified descriptor, not from the path. Command substitution
# strips the trailing newline a shell redirect leaves.
TOKEN="$(cat <&9)"
exec 9<&-

[ -n "$TOKEN" ] || refuse "the drop file holds no token once its trailing newline is removed"
case "$TOKEN" in
  *[[:space:]]*) refuse "the token carries whitespace, so it is not a service-account token. Check what was piped in." ;;
esac
case "$TOKEN" in
  ops_*) : ;;
  *) refuse "this is not a 1Password service-account token: those begin with ops_. Nothing was installed." ;;
esac
if [ "${#TOKEN}" -lt 100 ] || [ "${#TOKEN}" -gt 4096 ]; then
  refuse "the token is ${#TOKEN} characters, outside the range a service-account token occupies. Nothing was installed."
fi

TOKEN_SHA="$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)"
say "  offered token: ${#TOKEN} bytes, sha256 ${TOKEN_SHA:0:16}"

install -d -m 0700 -o root -g root "$WORKDIR"

# ------------------------------------------------------- gate R: the rotation
#
# CONVERGING IS A MOVE PLUS A ROTATION. The per-home copies this run is about to
# remove are in snapshots, and a snapshot is not editable. Removing the file
# ends nothing: the value in it still opens the vault for as long as any
# snapshot holding it is still inside retention. So the ONLY convergence that
# changes anything is one that also retires the value, and that is a re-mint at
# the manager rather than a move on this disk.
#
# This gate is what makes that mechanical instead of remembered. It reads the
# digest of every copy it would remove -- and of the live file -- and refuses an
# offered token matching any of them. A caller who copies the old value into the
# new path is stopped by a measurement rather than by a paragraph.
LIVE_SHA=""
if [ -s "$CC_AGENTS_TOKEN" ]; then
  LIVE_SHA="$(sha256sum "$CC_AGENTS_TOKEN" | cut -d' ' -f1)"
  install -m 0600 -o root -g root "$CC_AGENTS_TOKEN" "${WORKDIR}/previous.token"
  say "  live token: $(stat -c '%s' "$CC_AGENTS_TOKEN") bytes, sha256 ${LIVE_SHA:0:16}"
fi

if [ "${#LEGACY_HOMES[@]}" -gt 0 ]; then
  say ""
  say "=== GATE R: converging means rotating, so this token must be one this claw has not used ==="
  resited=""
  for i in "${!LEGACY_HOMES[@]}"; do
    lt="$(cc_agents_legacy_token "${LEGACY_HOMES[$i]}")"
    [ -s "$lt" ] || continue
    if [ "$(sha256sum "$lt" | cut -d' ' -f1)" = "$TOKEN_SHA" ]; then
      resited="${resited} ${LEGACY_PEOPLE[$i]}"
    fi
  done
  if [ -n "$LIVE_SHA" ] && [ "$LIVE_SHA" = "$TOKEN_SHA" ]; then
    resited="${resited} (the live file)"
  fi
  if [ -n "$resited" ]; then
    bad "gate R: the offered token is the value already sitting in:${resited}. REFUSED."
    say ""
    say "  Moving that value to ${CC_AGENTS_TOKEN} would change where it rests and nothing else."
    say "  It is in every snapshot inside the rail's retention window, it still opens"
    say "  ${AGENTS_VAULT}, and no delete on this box reaches a snapshot. Converging onto it"
    say "  is the move that looks like a fix and is not one."
    say ""
    say "  Re-mint the ${AGENTS_VAULT}-broker service-account token at the manager, revoke the"
    say "  old one there, and drop the NEW value:"
    say ""
    say "    op read \"op://${AGENTS_VAULT}/${AGENTS_VAULT}-broker-service-token/credential\" \\"
    say "      | ssh $(hostname) 'umask 077; cat > ${DROP}'"
    say ""
    warn "nothing on this claw was touched, and ${DROP} was NOT destroyed"
    ACTION="refused-before-write"
    finish
  fi
  ok "gate R: the offered token matches none of the ${#LEGACY_HOMES[@]} per-home copies this run removes, nor the live file -- this convergence carries a real rotation"
fi

# ---------------------------------------------------------------- the control
#
# Before the write, what a member's session resolves. On a claw that already has
# a token this is the OLD value, and the gate below decides on the NEW one's own
# digest rather than on something merely being set.
PROBE_ENV=(env -i PATH=/usr/local/bin:/usr/bin:/bin SHELL=/bin/bash)

probe_len() {
  local mode="$1" out=""
  [ -n "$PROBE_PERSON" ] || { printf '0'; return 0; }
  case "$mode" in
    automated)
      out="$(runuser -u "$PROBE_PERSON" -- "${PROBE_ENV[@]}" "USER=${PROBE_PERSON}" "LOGNAME=${PROBE_PERSON}" "HOME=${PROBE_HOME}" \
               bash -c '. "$HOME/.bashrc" >/dev/null 2>&1; printf %s "${#OP_SERVICE_ACCOUNT_TOKEN}"' 2>/dev/null || true)" ;;
    typed)
      out="$(runuser -u "$PROBE_PERSON" -- "${PROBE_ENV[@]}" "USER=${PROBE_PERSON}" "LOGNAME=${PROBE_PERSON}" "HOME=${PROBE_HOME}" TERM=dumb \
               bash -ic 'printf %s "${#OP_SERVICE_ACCOUNT_TOKEN}"' 2>/dev/null || true)" ;;
  esac
  case "$out" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$out" ;; esac
}

# The same empty start, for the leg that proves the session holds the RIGHT
# token and not merely one of the right length.
#
# THE PROBE STARTS FROM AN EMPTY ENVIRONMENT, and `env -i` is the whole control
# rather than tidiness. Two ways this probe lies without it, and the first one
# was measured on a hand-run of exactly this code:
#   the caller's OWN agents token is exported in their session, `runuser` keeps
#     the environment it was called with, and the probe then reports a working
#     plane by reading the value the operator brought with them;
#   this script exports HOME=/root so the manager reads no member's config, so
#     the probe would source ROOT's .bashrc and answer for the wrong person.
probe_sha() {
  [ -n "$PROBE_PERSON" ] || return 0
  runuser -u "$PROBE_PERSON" -- "${PROBE_ENV[@]}" "USER=${PROBE_PERSON}" "LOGNAME=${PROBE_PERSON}" "HOME=${PROBE_HOME}" \
    bash -c '. "$HOME/.bashrc" >/dev/null 2>&1; printf %s "$OP_SERVICE_ACCOUNT_TOKEN" | sha256sum | cut -d" " -f1' 2>/dev/null || true
}

say ""
say "=== THE CONTROL: what a member's session resolves before this run ==="
if [ -n "$PROBE_PERSON" ]; then
  PRE_AUTO="$(probe_len automated)"
  PRE_TYPED="$(probe_len typed)"
  PRE_SHA="$(probe_sha)"
  if [ "$PRE_SHA" = "$TOKEN_SHA" ]; then
    bad "control: ${PROBE_PERSON}'s session ALREADY exports the token this run is installing. Gate 2 would then pass without this run having done anything, so it decides nothing."
    warn "nothing was written, and ${DROP} was NOT destroyed"
    ACTION="refused-before-write"
    finish
  fi
  ok "control: ${PROBE_PERSON}'s session does not export the new token before this run (automated ${PRE_AUTO} bytes, typed ${PRE_TYPED}), so gate 2 has a failing branch to pass from"
else
  warn "NO member of ${CC_AGENTS_GROUP} has a wired plane on this claw, so the session legs of gate 2 cannot run. An unrun control is not a passed one: this run installs the file and proves the file, and says plainly that no session was measured."
fi

# ---------------------------------------------------------------- gate 1
#
# Resolve something real, before this claw moves at all. The vault listing is
# what the token can actually reach, read from the manager rather than claimed.
say ""
say "=== GATE 1: the offered token opens ${AGENTS_VAULT}, and does not open ${MACHINE_VAULT} ==="

# stdout carries vault NAMES and nothing else. The manager's own words go to a
# file and come back scrubbed and truncated.
vaults_with() {
  OP_SERVICE_ACCOUNT_TOKEN="$1" op vault list --format=json 2>"${WORKDIR}/manager.err" \
    | jq -r '.[].name' 2>/dev/null
}
manager_said() { tr '\n' ' ' < "${WORKDIR}/manager.err" 2>/dev/null | cut -c1-300; }

g1_out=""; g1_rc=0
g1_out="$(vaults_with "$TOKEN")" || g1_rc=$?
if [ "$g1_rc" -ne 0 ] || [ -z "$g1_out" ]; then
  bad "gate 1: the offered token opens nothing (manager exit ${g1_rc})"
  say ""
  say "  the manager said: $(manager_said)"
  say ""
  warn "nothing on this claw was touched, and ${DROP} was NOT destroyed -- you still hold the only copy"
  ACTION="refused-before-write"
  finish
fi

# THE WALL, and it is the check this door exists to carry. A machine token
# installed into a person's session works perfectly and destroys the reason two
# vaults exist, so it is refused on its own line and named as what it is.
if printf '%s\n' "$g1_out" | grep -qxF "$MACHINE_VAULT"; then
  bad "gate 1: the offered token opens ${MACHINE_VAULT}. REFUSED."
  say ""
  say "  That vault holds this claw's repository password and its object-store key, so a"
  say "  session holding this token could delete the backups. A safety net must not be"
  say "  openable from inside the thing it is catching. Mint a token for the"
  say "  ${AGENTS_VAULT}-broker service account, which reads ${AGENTS_VAULT} alone."
  say ""
  warn "nothing on this claw was touched, and ${DROP} was NOT destroyed"
  ACTION="refused-before-write"
  finish
fi
ok "gate 1a: the offered token does NOT open ${MACHINE_VAULT} -- the wall between the two planes holds"

if printf '%s\n' "$g1_out" | grep -qxF "$AGENTS_VAULT"; then
  ok "gate 1b: the offered token opens ${AGENTS_VAULT}, read from the manager"
else
  bad "gate 1b: the offered token does not open ${AGENTS_VAULT}"
  say ""
  say "  it opens: $(printf '%s' "$g1_out" | tr '\n' ' ')"
  say "  This claw's people resolve op://${AGENTS_VAULT}/... references, so a token that"
  say "  opens something else resolves nothing they ask for."
  say ""
  warn "nothing on this claw was touched, and ${DROP} was NOT destroyed -- you still hold the only copy"
  ACTION="refused-before-write"
  finish
fi

# ---------------------------------------------------------------- the write

# Restore what this run found. Called on every failure path after the write, so
# a bad install never outlives this run. The per-home copies are NOT removed
# until every gate has passed, so nothing here has to put one back.
restore_previous() {
  local now h saved
  for h in "${LEGACY_HOMES[@]:-}"; do
    [ -n "$h" ] || continue
    saved="${WORKDIR}/loader.$(printf '%s' "$h" | tr '/' '_')"
    [ -f "$saved" ] || continue
    cc_agents_paths "$h"
    cat "$saved" > "$CC_AP_ENV" 2>/dev/null || true
  done
  if [ -n "$LIVE_SHA" ]; then
    install -m "$CC_AGENTS_TOKEN_MODE" -o root -g "$CC_AGENTS_GROUP" "${WORKDIR}/previous.token" "$CC_AGENTS_TOKEN"
    now="$(sha256sum "$CC_AGENTS_TOKEN" | cut -d' ' -f1)"
    if [ "$now" = "$LIVE_SHA" ]; then
      ok "restored: ${CC_AGENTS_TOKEN} is byte-identical to the one this run found (sha256 ${now:0:16})"
    else
      bad "RESTORE FAILED: ${CC_AGENTS_TOKEN} is sha256 ${now:0:16}, not the ${LIVE_SHA:0:16} this run found. The copy is at ${WORKDIR}/previous.token and this run has NOT removed it."
      trap - EXIT   # leave the scratch copy in place; a broken plane beats a tidy one
    fi
  else
    rm -f -- "$CC_AGENTS_TOKEN"
    ok "removed the token this run wrote: this claw held none before, and holds none now"
  fi
}

say ""
say "=== the write ==="

[ -d "$CC_AGENTS_STATE_DIR" ] || install -d -m "$CC_AGENTS_STATE_DIR_MODE" -o root -g root "$CC_AGENTS_STATE_DIR"

# Composed in the target directory, so the move below is a rename on one
# filesystem and no reader ever sees a half-written token. The temp file is
# root-owned and 0600 while it is being written, then given its group in the
# same act that names it.
NEW_TOKEN="$(mktemp "${CC_AGENTS_STATE_DIR}/.agents-token.XXXXXX")"
chmod 0600 "$NEW_TOKEN"
printf '%s' "$TOKEN" > "$NEW_TOKEN"
chown "root:${CC_AGENTS_GROUP}" "$NEW_TOKEN"
chmod "$CC_AGENTS_TOKEN_MODE" "$NEW_TOKEN"
mv -f "$NEW_TOKEN" "$CC_AGENTS_TOKEN"
ACTION="installed"
say "  wrote ${CC_AGENTS_TOKEN}: $(stat -c '%s' "$CC_AGENTS_TOKEN") bytes, $(stat -c '%a %U:%G' "$CC_AGENTS_TOKEN")"

# The loaders in the homes that still name a per-home token. Rewritten HERE and
# not after the gates, because gate 2's session leg measures what a loader
# actually loads: leaving the old one in place would measure the old path and
# report the new file working when it is not being read at all. The old loader
# is copied aside first, so a failing gate restores the home exactly.
if [ "${#LEGACY_HOMES[@]}" -gt 0 ]; then
  for i in "${!LEGACY_HOMES[@]}"; do
    h="${LEGACY_HOMES[$i]}"; p="${LEGACY_PEOPLE[$i]}"
    cc_agents_paths "$h"
    [ -f "$CC_AP_ENV" ] && cp -p "$CC_AP_ENV" "${WORKDIR}/loader.$(printf '%s' "$h" | tr '/' '_')"
    if cc_agents_plane_unsafe "$p" "$h" >/dev/null; then
      cc_agents_plane_install "$p" "$h" \
        || bad "could not rewrite ${p}'s loader to name ${CC_AGENTS_TOKEN}"
    else
      bad "${p}'s home refused the loader rewrite: $(cc_agents_plane_unsafe "$p" "$h")"
    fi
  done
  say "  rewrote ${#LEGACY_HOMES[@]} loader(s) to read ${CC_AGENTS_TOKEN}"
fi

# ---------------------------------------------------------------- gate 2
#
# At the surface that consumes the token, because a file holding what was
# written to it is not the same claim as a plane that works.
say ""
say "=== GATE 2: the installed token, at the surface that consumes it ==="

RB_SHA="$(sha256sum "$CC_AGENTS_TOKEN" | cut -d' ' -f1)"
if [ "$RB_SHA" = "$TOKEN_SHA" ]; then
  ok "gate 2a: the file on disk is exactly what went in ($(stat -c '%s' "$CC_AGENTS_TOKEN") bytes, sha256 ${RB_SHA:0:16})"
else
  bad "gate 2a: the file on disk is sha256 ${RB_SHA:0:16}, not the ${TOKEN_SHA:0:16} that went in"
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi

# Unix permissions are the ONLY protection this credential has. The machine
# token is encrypted by the host's own key; this one rests as bytes behind a
# group-read file in a traversable directory, so the mode and the group are the
# whole boundary and each is read separately.
perm_ok=1
tok_stat="$(stat -c '%a %U:%G' "$CC_AGENTS_TOKEN")"
[ "$tok_stat" = "${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER}" ] \
  || { bad "gate 2b: the token file is ${tok_stat}, wanted ${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER}"; perm_ok=0; }
dir_stat="$(stat -c '%a %U' "$CC_AGENTS_STATE_DIR")"
[ "$dir_stat" = "755 root" ] \
  || { bad "gate 2b: ${CC_AGENTS_STATE_DIR} is ${dir_stat}, wanted 755 root. That directory is also how members reach the session bus, so both readings depend on it."; perm_ok=0; }
if [ "$perm_ok" -eq 1 ]; then
  ok "gate 2b: ${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER} inside a 0755 root directory -- group membership is the whole read boundary and nothing else is"
else
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi

# WHERE IT RESTS, asked of the rail rather than asserted. This is the check that
# says the path was chosen and not merely typed, and it is the one that will
# still be right on the day somebody adds a target.
cap=""; cap_rc=0
cap="$(cc_agents_backup_captures "$BACKUP_RAIL")" || cap_rc=$?
case "$cap_rc" in
  1) ok "gate 2c: ${CC_AGENTS_TOKEN} is captured by NO backup target, asked of ${BACKUP_RAIL} itself" ;;
  0) bad "gate 2c: ${CC_AGENTS_TOKEN} is INSIDE a backup target: $(printf '%s' "$cap" | tr '\n' ' '). Every snapshot would carry this credential for the whole retention window, and no delete on this box reaches a snapshot."
     restore_previous
     warn "${DROP} was NOT destroyed -- you still hold the only copy"
     finish ;;
  *) bad "gate 2c: ${BACKUP_RAIL} could not say what it captures, so where this credential rests was NOT measured. An unrun control is not a passed one."
     restore_previous
     warn "${DROP} was NOT destroyed -- you still hold the only copy"
     finish ;;
esac

# THE GROUP BOUNDARY, DRIVEN BOTH WAYS. A read that succeeds proves the file is
# reachable; only a read that FAILS proves the mode is doing anything. `nobody`
# is the non-member every Linux box already has, it is in no group of ours, and
# it needs no home to try to read a file.
if getent passwd nobody >/dev/null 2>&1 && ! cc_agents_reads nobody; then
  if runuser -u nobody -- cat "$CC_AGENTS_TOKEN" >/dev/null 2>&1; then
    bad "gate 2d: 'nobody', which is in no group on this claw, READ ${CC_AGENTS_TOKEN}. The mode is protecting nothing."
    restore_previous
    warn "${DROP} was NOT destroyed -- you still hold the only copy"
    finish
  fi
  ok "gate 2d: a non-member ('nobody') cannot read ${CC_AGENTS_TOKEN} -- the refusal is measured, not assumed"
else
  warn "gate 2d did NOT run: this claw has no 'nobody' account outside ${CC_AGENTS_GROUP} to refuse with, so the non-member half of the boundary was not measured here"
fi

# The session start, both ways, measured against the control taken before the
# write. A length alone would pass on a token holding the wrong bytes, so the
# automated surface hands back a digest of what it actually loaded.
if [ -n "$PROBE_PERSON" ]; then
  POST_AUTO="$(probe_len automated)"
  POST_TYPED="$(probe_len typed)"
  session_ok=1
  [ "$POST_AUTO" = "${#TOKEN}" ] || { bad "gate 2e: an automated session start as ${PROBE_PERSON} exports ${POST_AUTO} bytes, not ${#TOKEN}. The loader is hooked BELOW .bashrc's interactive guard, so a remote command resolves nothing."; session_ok=0; }
  [ "$POST_TYPED" = "${#TOKEN}" ] || { bad "gate 2e: an interactive session start as ${PROBE_PERSON} exports ${POST_TYPED} bytes, not ${#TOKEN}"; session_ok=0; }
  if [ "$session_ok" -eq 1 ]; then
    SESS_SHA="$(probe_sha)"
    if [ "$SESS_SHA" = "$TOKEN_SHA" ]; then
      ok "gate 2e: a session start as ${PROBE_PERSON}, who is in ${CC_AGENTS_GROUP}, exports the token this run installed, automated and typed alike (${POST_AUTO} bytes, sha256 ${SESS_SHA:0:16})"
    else
      bad "gate 2e: the session exports ${POST_AUTO} bytes whose digest is ${SESS_SHA:0:16}, not the ${TOKEN_SHA:0:16} that went in"
      session_ok=0
    fi
  fi
  if [ "$session_ok" -eq 0 ]; then
    restore_previous
    warn "${DROP} was NOT destroyed -- you still hold the only copy"
    finish
  fi
else
  warn "gate 2e did NOT run: no member of ${CC_AGENTS_GROUP} has a wired plane, so no session was measured on this claw"
fi

# The manager, with the bytes read back off this disk rather than the ones still
# in memory. This is the leg that says the plane works, not merely that a file
# holds what was written to it.
DISK_TOKEN="$(cat "$CC_AGENTS_TOKEN")"
g2_out=""; g2_rc=0
g2_out="$(vaults_with "$DISK_TOKEN")" || g2_rc=$?
DISK_TOKEN=""
if [ "$g2_rc" -ne 0 ] || ! printf '%s\n' "$g2_out" | grep -qxF "$AGENTS_VAULT"; then
  bad "gate 2f: the token read back off this disk does not open ${AGENTS_VAULT} (manager exit ${g2_rc})"
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi
ok "gate 2f: the token on this claw's disk opens ${AGENTS_VAULT} through the manager"

# ------------------------------------------------------------ the convergence

# Only here, and only because every gate passed. The per-home copies come out
# LAST, so a failing run leaves the claw exactly as it found it.
if [ "${#LEGACY_HOMES[@]}" -gt 0 ]; then
  say ""
  say "=== the per-home copies this shape replaces ==="
  left=""
  for i in "${!LEGACY_HOMES[@]}"; do
    lt="$(cc_agents_legacy_token "${LEGACY_HOMES[$i]}")"
    rm -f -- "$lt"
    [ -e "$lt" ] && left="${left} ${LEGACY_PEOPLE[$i]}"
  done
  if [ -n "$left" ]; then
    bad "these homes still carry a per-home token after removal:${left}"
  else
    CONVERGED=1
    ok "the ${#LEGACY_HOMES[@]} per-home copy/copies are gone from disk, and every one of those homes now reads ${CC_AGENTS_TOKEN}"
  fi
fi

# ---------------------------------------------------------------- the burn

# On tmpfs an unlink frees the pages; there is no on-disk remnant to overwrite,
# which is why the drop path was chosen rather than shredded.
rm -f -- "$DROP"
if [ -e "$DROP" ]; then
  bad "the drop copy at ${DROP} is still there after removal"
else
  ok "the drop copy is destroyed: ${DROP} is gone"
fi
rm -f -- "${WORKDIR}/previous.token"

# ---------------------------------------------------------------- the record

# The event, never the value: no length and no digest reaches this file, because
# it is world-readable and its readers are the firm's own people.
if [ "$CONVERGED" -eq 1 ]; then
  printf '| %s | %s | rotated the agents broker token and removed %s per-home copies | claw |\n' \
    "$WHEN" "$BY" "${#LEGACY_HOMES[@]}" >> "$ADMIN_LOG"
else
  printf '| %s | %s | installed the agents broker token | claw |\n' "$WHEN" "$BY" >> "$ADMIN_LOG"
fi

say ""
say "  Every member of ${CC_AGENTS_GROUP} resolves op://${AGENTS_VAULT}/... from their next"
say "  session onward. A session already open does not pick this up: it holds the"
say "  environment it started with. They reconnect."
say "  Somebody outside that group resolves nothing, which is the boundary and not a fault."

if [ "$CONVERGED" -eq 1 ]; then
  warn "REVOKE THE OLD TOKEN AT THE MANAGER NOW. The value those per-home copies held is inside every snapshot still in the rail's retention window, and no delete on this box reaches a snapshot. Until it is revoked at the manager it opens ${AGENTS_VAULT} for anybody who can restore one."
elif [ -n "$LIVE_SHA" ]; then
  warn "the token this replaced (sha256 ${LIVE_SHA:0:16}) is superseded on this claw. Revoke it at the manager: rewriting a file revokes nothing. It rested outside every backup target, so no snapshot carries it."
fi

finish
