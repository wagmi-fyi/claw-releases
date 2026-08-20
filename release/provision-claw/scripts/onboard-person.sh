#!/bin/bash
#
# onboard-person.sh — create one person on this claw.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./onboard-person.sh --person alice --key "ssh-ed25519 AAAA... alice@laptop"
#   sudo ./onboard-person.sh --person alice --key-file ./alice.pub
#
#   --email             the git address for this person. Defaults to person@hostname.
#   --full-name         the name their commits carry. Defaults to the username.
#   --no-agents-cred    make a person who resolves no credentials, deliberately
#   --dry-run           print the plan, change nothing
#
# WHAT IT MAKES. The seven things provisioning gives a person who was in the keys
# file at build time, so somebody arriving later gets the same claw:
#   the unix account, with a home and a shell
#   the home at 0750, .ssh at 0700, authorized_keys at 0600 carrying their key
#   the workspaces symlink, one hop from home to every workspace
#   the convention pointer in each core's global instructions file, and the
#     claw-briefing pointer in the per-task core's file alone
#   membership of the claw's members group, which owns the claw-wide briefing
#   the agents credential plane: membership of the credential group, plus the
#     loader and the hook that starts it, so their sessions resolve op://
#   their git identity, so their first commit is theirs
#
# THE SIXTH THING IS A GROUP GRANT AND A LOADER, and neither is a secret, so
# this door does both and holds no value at any point. The claw's agents token
# is ONE root-owned file that `install-agents-token.sh` writes; what makes it
# readable is membership of the credential group, and what turns it into an
# exported variable is the loader in this person's own home.
#
# THE GRANT IS AN EXPLICIT STEP, NOT A SIDE EFFECT. It is made here, said out
# loud, read back, and written into the admin log as its own act. A grant folded
# into some other step is a grant a person can silently lack: that is exactly
# how somebody has arrived here with an account, a home, correct keys, and every
# credential lookup in their session failing with nothing in their onboarding
# saying why.
#
# AND IT IS NEVER THE MEMBERS GROUP. Two groups, two meanings, and collapsing
# them would put credential read on everybody who can read the briefing. The
# members group owns the briefing and nothing else; the credential group's one
# meaning is who may read the token.
#
# THE GIT IDENTITY IS PART OF MAKING A PERSON, not a thing they configure later.
# Every workspace on this claw is a git repository the group shares, so a person
# with no identity either cannot commit or commits as a guess. Both cost more
# than setting it here: git history is the one record on the claw that the
# conventions forbid rewriting, so a wrong name in it is wrong permanently.
#
# THE DEFAULT IS DERIVED AND IT IS TRUE. person@hostname says which person, on
# which claw. It resolves to no mailbox, and nothing here pretends it does: the
# address is git's identity key, and the claw is the system of record. Somebody
# who wants their commits attributed on a mirror passes --email and gets that
# instead. There is no claw-wide default address, because inventing one means
# inventing a domain this claw does not own.
#
# useConfigOnly IS SET WITH IT. Without it git invents an identity from the
# hostname when none is configured, so a person whose config is later emptied
# starts committing under a name nobody chose and nothing announces. With it,
# git refuses instead. A refusal is recoverable and a wrong commit is not.
#
# THE MEMBERS GROUP IS NOT ACCESS. It carries no grant and owns one file: the
# briefing at the workspace root that every session on this claw reads. Joining
# it is what makes that file the new person's as much as anybody else's. This
# script proves the group is still empty of privilege after the join, rather
# than saying so.
#
# IT IS NOT CREATED HERE. Provisioning makes it, in the same phase that makes
# the file it owns, so a claw whose door exists and whose group does not was
# provisioned in pieces. That is refused, exactly as a missing member-plane log
# is: the absence means a phase was skipped, and a person created without it
# would quietly be unable to write the claw's own briefing forever.
#
# WHAT IT DOES NOT MAKE: workspace access. Creating a person and deciding what
# that person may reach are two decisions, so they stay two doors. A person made
# here is in no ws- group, and this script PROVES that rather than saying it. It
# grants no sudo and no claw-admin either; both stay provisioning's.
#
# THE INPUT IS THE WHOLE RISK SURFACE. A username arrives from a human and lands
# in commands that create system state, so it is CONSTRAINED to a safe shape and
# refused otherwise, never escaped. A refused name gives the caller something to
# act on. An escaped one hides a rule nobody can read.
#
# A PRIVATE KEY OFFERED HERE IS REFUSED, and refusing it takes more than asking
# the key tool. `ssh-keygen -l -f` prints a fingerprint for a PRIVATE key and
# exits 0 -- measured on 2026-08-11, not assumed -- so a script that trusts that
# exit status installs a private key and writes a secret into a file every
# session on the claw can read. The refusal that works is structural, and each
# leg covers what the others miss:
#   one line only, because every private key format is multi-line
#   no PEM armor and no vendor key header anywhere in the line
#   a leading key type from a named set
# Only then does the key tool run, and what it adds is that the blob really is a
# public key of the type the line claims.
#
# A COLLIDING NAME IS REFUSED, never converged onto. Every other script here is
# idempotent and this one is not, which is deliberate: converging onto a name
# that already exists would graft a new key onto somebody else's login. That is
# the exact failure this door has to prevent, so a re-run says so and stops.
# Adding a second device to a person who already exists is a different act and
# has its own door: `manage-person-keys.sh --add-key`. That door adds and revokes
# keys and creates nobody, which is the same split this one keeps by refusing.
#
# THE CONTRACT WITH PROVISIONING. The home mode, the symlink target, the two
# pointer sentences and the git identity below belong to phase 8 of
# provision-claw.sh. Both sides name them and neither may move one alone. A
# pointer written in different words is a SECOND pointer, and the next
# provisioning run leaves the claw carrying both. The same contract covers WHERE
# each one goes: the conventions pointer in both cores' files, the claw-briefing
# pointer in the per-task core's file only, with its absence from the other
# asserted on both sides.
#
# The identity half of that contract has one asymmetry, and it is not drift.
# Phase 8 takes its people from a keys file or from a group, neither of which
# carries an address, so it can only write the derived default. This door takes
# arguments, so it can write what somebody chose. BOTH SIDES WRITE ONLY INTO AN
# ABSENCE. That is what makes them agree: a person the door gave a chosen address
# keeps it through every later provisioning run, and a person created any other
# way gets the derived one from whichever side reaches them first.
#
set -euo pipefail

PERSON=""; KEY=""; KEY_FILE=""; DRY_RUN=0; AGENTS_CRED=1; EMAIL=""; FULL_NAME=""

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Where the claw's token rests, which group reads it, and what loads it, in one
# copy that phase 8, this door and the token door all read. A missing sibling
# fails the run rather than being skipped.
# shellcheck source=agents-plane.sh
[ -r "${SCRIPT_DIR}/agents-plane.sh" ] \
  || { printf 'no agents-plane.sh beside this script\n' >&2; exit 1; }
. "${SCRIPT_DIR}/agents-plane.sh"

TOKEN_DOOR="${SCRIPT_DIR}/install-agents-token.sh"

# The contract with the provisioning plane. Phase 8 writes these exact values.
WORKSPACE_ROOT="/srv/workspaces"
CONVENTIONS="/etc/commonclaw/workspace-conventions.md"
CONVENTION_POINTER="Workspace conventions for this claw: read ${CONVENTIONS} before working under ${WORKSPACE_ROOT}."
ADMIN_LOG="/etc/commonclaw/admin-log.md"
MEMBERS_GROUP="claw-members"
CLAW_BRIEFING="${WORKSPACE_ROOT}/CLAUDE.md"

# Phase 8 writes these same three settings, into the same absence.
GIT_IDENTITY_KEYS=("user.name" "user.email" "user.useConfigOnly")
# A key nothing on this claw ever sets. It exists so the read-back below can be
# shown to return "absent" for something absent, which is the only thing that
# makes a read-back of a value we did set into evidence.
GIT_PROBE_KEY="commonclaw.identityprobe"

# The two global instructions files, and the second pointer that goes in exactly
# one of them. The per-task core does not walk up to ${CLAW_BRIEFING}, so it is
# told where the file is; the other core finds it unaided, and a line in its
# always-loaded file would be weight bought to serve a core that is not reading
# it. Phase 8 writes it to the same one file and asserts its absence from the
# other, and this door has to agree with phase 8 on both halves.
PERSISTENT_CORE_FILE=".claude/CLAUDE.md"
PER_TASK_CORE_FILE=".codex/AGENTS.md"
CLAW_BRIEFING_POINTER="This claw's own briefing: read ${CLAW_BRIEFING} before working under ${WORKSPACE_ROOT}."

# The two forms this claw installs. A desktop key opens with the first and a
# phone key with the second; the hardware-backed spellings are the same two
# algorithms held on a security key. RSA is deliberately absent: the mobile app
# rejects it, so accepting it here hands somebody a key that fails at the last
# step of their own onboarding.
KEY_TYPES=(
  "ssh-ed25519"
  "ecdsa-sha2-nistp256"
  "sk-ssh-ed25519@openssh.com"
  "sk-ecdsa-sha2-nistp256@openssh.com"
)

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --person)   PERSON="${2:-}"; shift 2 ;;
    --key)      KEY="${2:-}"; shift 2 ;;
    --key-file) KEY_FILE="${2:-}"; shift 2 ;;
    --no-agents-cred) AGENTS_CRED=0; shift ;;
    --email)    EMAIL="${2:-}"; shift 2 ;;
    --full-name) FULL_NAME="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; FINGERPRINT=""; HOME_DIR=""; AGENTS_PLANE="absent"

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
  printf '  "script": "onboard-person",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "person": "%s",\n' "$(json_esc "$PERSON")"
  printf '  "home": "%s",\n' "$(json_esc "$HOME_DIR")"
  printf '  "key_fingerprint": "%s",\n' "$(json_esc "$FINGERPRINT")"
  printf '  "agents_plane": "%s",\n' "$(json_esc "$AGENTS_PLANE")"
  printf '  "agents_cred": %s,\n' "$(cc_agents_reads "$PERSON" && echo true || echo false)"
  printf '  "claw_token": "%s",\n' "$(json_esc "$(cc_agents_token_state)")"
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

[ -n "$PERSON" ] || { say "missing required argument: --person"; usage; }

if [ -n "$KEY" ] && [ -n "$KEY_FILE" ]; then
  say "pass --key or --key-file, not both"; exit 1
fi
if [ -z "$KEY" ]; then
  [ -n "$KEY_FILE" ] || { say "missing required argument: --key or --key-file"; usage; }
  [ -r "$KEY_FILE" ] || { say "cannot read key file: ${KEY_FILE}"; exit 1; }
  # A file arrives with a trailing newline. Read the FIRST line only, so a file
  # holding several keys refuses below on the count rather than installing one
  # of them silently.
  KEY="$(head -c 8192 "$KEY_FILE")"
fi

# ---- the name ----
#
# Constrain, do not escape. The shape below is what useradd accepts on this
# distribution and what every later command can carry without quoting rules
# deciding the outcome.
#
# A leading letter is required, where the roster's own matcher also allows a
# leading underscore. Matching an existing row and CREATING an account are
# different jobs: the underscore forms are a system-account convention, and this
# door makes people.
#
# TWO patterns, and the second one is the whole control. A shell case pattern is
# ANCHORED AT BOTH ENDS, so `[a-z][a-z0-9_-]*` reads as a character class
# followed by ANY remaining characters -- its trailing star is not "more of the
# same class", it is "anything at all". Measured 2026-08-11: that pattern
# accepted `w24; rm -rf /`, and the only thing that refused the name was useradd
# further down. A gate whose refusal is really a downstream tool's refusal is
# narration, not a gate. The refusal that decides is the NEGATIVE match below:
# it fires when any single character falls outside the class.
case "$PERSON" in
  [a-z]*) : ;;
  *) say "'${PERSON}' is not a usable username: it must start with a lowercase letter."; exit 1 ;;
esac
case "$PERSON" in
  *[!a-z0-9_-]*) say "'${PERSON}' is not a usable username: use lowercase letters, digits, hyphen and underscore only."; exit 1 ;;
esac
[ "${#PERSON}" -le 32 ] || { say "'${PERSON}' is longer than 32 characters, which useradd refuses"; exit 1; }

# ---- the collision ----
#
# Two lookups, not one. A name with no passwd entry and a group of the same name
# still collides: useradd creates the person's own group and fails halfway,
# leaving a half-made account behind.
if getent passwd "$PERSON" >/dev/null 2>&1; then
  existing_uid="$(id -u "$PERSON" 2>/dev/null || echo 0)"
  if [ "$existing_uid" -lt 1000 ]; then
    say "'${PERSON}' is a system account on this claw (uid ${existing_uid}). Choose another name."
  else
    say "'${PERSON}' already exists on this claw (uid ${existing_uid})."
    say "This door creates a person. It will not add a key to an account somebody is already using."
    say "To add a second device to an existing person, see operations/lifecycle.md."
  fi
  exit 1
fi
if getent group "$PERSON" >/dev/null 2>&1; then
  say "a group named '${PERSON}' already exists, so useradd cannot make this person's own group. Choose another name."
  exit 1
fi

# ---- the key ----
#
# Each leg covers what the others miss, and the order matters: the cheapest and
# most decisive refusals run before anything parses the blob.
case "$KEY" in
  *[$'\n\r']*) say "the key must be ONE line. A multi-line block is a private key, not a public key."; exit 1 ;;
esac
case "$KEY" in
  *"-----BEGIN"*|*"PRIVATE KEY"*|*"PuTTY-User-Key-File"*)
    # Name the PROPERTY, never a vault name. A manager holds several vaults, so
    # "keep it in your manager" is followed exactly by somebody putting a
    # personal private key in the shared team vault. The rule is in
    # reference/staff-access.md, under the heading about a vault only its owner
    # can read. A message a script prints to a person is an instruction with the
    # same force as a paragraph, and it takes the same clause.
    say "that is a PRIVATE key. It is not installed, and it is compromised by having left your machine."
    say "Mint a replacement, keep the private half in your own private vault that nobody else and no service account can read, and send the .pub half only."
    exit 1 ;;
esac
[ -n "${KEY//[[:space:]]/}" ] || { say "the key is empty"; exit 1; }
[ "${#KEY}" -le 4096 ] || { say "the key line is longer than 4096 characters, which no public key is"; exit 1; }
case "$KEY" in
  *[![:print:][:space:]]*) say "the key line carries a control character"; exit 1 ;;
esac

KEY_TYPE="${KEY%% *}"
type_ok=0
for t in "${KEY_TYPES[@]}"; do [ "$KEY_TYPE" = "$t" ] && { type_ok=1; break; }; done
if [ "$type_ok" -eq 0 ]; then
  say "'${KEY_TYPE}' is not a key type this claw installs."
  say "A desktop key opens with ssh-ed25519. A phone key opens with ecdsa-sha2-nistp256."
  say "Accepted: ${KEY_TYPES[*]}"
  say "A line that does not START with one of those -- an authorized_keys option, for instance -- is refused here."
  exit 1
fi

# Two or three fields: the type, the blob, and an optional comment. More than
# that is a second key on the same line, which authorized_keys would read as one
# broken entry.
field_count="$(printf '%s' "$KEY" | awk '{print NF}')"
case "$field_count" in
  2|3) : ;;
  *) say "the key line has ${field_count} fields; a public key has the type, the blob, and at most one comment"; exit 1 ;;
esac

# The key tool, last, for the one thing the checks above cannot do: prove the
# blob really is a public key of the type the line declares. It refuses a
# mismatch and it refuses a blob that does not parse. Written to a root-only
# directory, with no .pub sibling, so the tool reads exactly what was offered.
KEY_TMP="$(mktemp -d)"; chmod 0700 "$KEY_TMP"
trap 'rm -rf "$KEY_TMP"' EXIT
printf '%s\n' "$KEY" > "${KEY_TMP}/offered"
if ! FINGERPRINT="$(ssh-keygen -l -f "${KEY_TMP}/offered" 2>/dev/null)"; then
  say "the key tool refuses this line: it is not a public key of type ${KEY_TYPE}"
  exit 1
fi

# ---- the identity ----
#
# The derived default. This door reads the box; phase 8 uses the hostname it was
# given as an argument. They agree because phase 2 sets the box's hostname to
# that same value and checks it, so there is one name and two ways of reaching
# it. `hostname -s` rather than the full name: the short form is the fleet's own
# word for a claw, and the long one carries whatever the network decided.
CLAW_HOST="$(hostname -s 2>/dev/null || true)"
[ -n "$CLAW_HOST" ] || { say "this box reports no hostname, so no address can be derived. Pass --email."; exit 1; }
[ -n "$EMAIL" ] || EMAIL="${PERSON}@${CLAW_HOST}"
[ -n "$FULL_NAME" ] || FULL_NAME="$PERSON"

# The address is CONSTRAINED, the same way the username is and for the same
# reason: it is a value from a human that ends up in a record nobody may rewrite.
case "$EMAIL" in
  *[$'\n\r']*) say "the address must be one line"; exit 1 ;;
esac
case "$EMAIL" in
  *@*@*) say "'${EMAIL}' has more than one @" ; exit 1 ;;
  *@*)   : ;;
  *)     say "'${EMAIL}' has no @, so git will not read it as an address"; exit 1 ;;
esac
case "$EMAIL" in
  @*) say "'${EMAIL}' has nothing before the @"; exit 1 ;;
  *@) say "'${EMAIL}' has nothing after the @"; exit 1 ;;
esac
case "$EMAIL" in
  *[!A-Za-z0-9.@_%+-]*) say "'${EMAIL}' carries a character an address here may not: use letters, digits, and . _ % + - @"; exit 1 ;;
esac
[ "${#EMAIL}" -le 254 ] || { say "the address is longer than 254 characters"; exit 1; }

# The NAME is not charset-constrained, and that is a deliberate difference from
# both the username and the address above. A username lands in useradd and in
# filesystem paths; an address lands in a machine-read key. A display name lands
# in one quoted argument and in git's ident line, so the only characters that can
# break anything are the ones git's own ident grammar uses. Refusing more than
# those would refuse real people's real names, which is a worse failure than any
# it would prevent.
case "$FULL_NAME" in
  *[$'\n\r']*) say "the name must be one line"; exit 1 ;;
  *"<"*|*">"*) say "the name may not carry < or >, which git reads as the address delimiters"; exit 1 ;;
esac
case "$FULL_NAME" in
  *[[:cntrl:]]*) say "the name carries a control character"; exit 1 ;;
esac
[ -n "${FULL_NAME//[[:space:]]/}" ] || { say "the name is only whitespace"; exit 1; }
[ "${#FULL_NAME}" -le 64 ] || { say "the name is longer than 64 characters"; exit 1; }

# ---- the claw ----
[ -d "$WORKSPACE_ROOT" ] || { say "no workspace root at ${WORKSPACE_ROOT} -- run the provisioning plane first"; exit 1; }
command -v git >/dev/null 2>&1 || {
  say "no git on this claw, so this person could be created and never commit."
  say "Every workspace here is a git repository from the moment it is scaffolded, so an absence"
  say "means the provisioning plane did not finish. Run it rather than working around this."
  exit 1
}
[ -f "$ADMIN_LOG" ] || {
  say "no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down."
  say "The log is seeded by provisioning. Run the provisioning plane rather than creating it here."
  exit 1
}
getent group "$MEMBERS_GROUP" >/dev/null 2>&1 || {
  say "no ${MEMBERS_GROUP} group on this claw, so a person made here could never write ${CLAW_BRIEFING}."
  say "Provisioning creates the group in the same phase that creates that file. Run the provisioning plane rather than creating it here."
  exit 1
}

# The caller behind sudo, not root. A person appearing on a machine is recorded
# with who let them in, and "root" would record nothing.
# Anchored the same way as the name above, and for the same reason: this value
# is written into a world-readable record.
BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z_]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac
WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

say ""
say "=== onboard ${PERSON} ==="
say "  key:  ${FINGERPRINT}"
say "  git:  ${FULL_NAME} <${EMAIL}>"
say "  by:   ${BY}"
say ""

# Whether this claw has a token at all, read BEFORE anything is written so the
# dry run says what the real run will do. This opens no file and prints no byte
# of one: it asks whether a token is there. A person joined to the credential
# group on a claw that holds no token still resolves nothing, and that is a
# claw-level gap rather than anything wrong with the person.
CLAW_TOKEN="$(cc_agents_token_state)"

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-onboard"
  say "  would create the account, the home at 0750, .ssh at 0700 and authorized_keys at 0600"
  say "  would install the key above, once"
  say "  would link ~/workspaces -> ${WORKSPACE_ROOT}"
  say "  would stamp the conventions pointer into ${PERSISTENT_CORE_FILE} and ${PER_TASK_CORE_FILE}"
  say "  would stamp the claw-briefing pointer into ${PER_TASK_CORE_FILE} alone"
  say "  would set their git identity to ${FULL_NAME} <${EMAIL}>, and refuse a guessed one"
  say "  would add ${PERSON} to ${MEMBERS_GROUP}, which owns ${CLAW_BRIEFING} and nothing else"
  if [ "$AGENTS_CRED" -eq 0 ]; then
    say "  would add ${PERSON} to NO credential group: --no-agents-cred was passed, so this person resolves nothing by decision"
  else
    say "  would add ${PERSON} to ${CC_AGENTS_GROUP}, which is what makes ${CC_AGENTS_TOKEN} readable, as its own logged step"
    say "  would make the loader at ~/.config/commonclaw/agent-env.sh and the hook at the top of ~/.bashrc"
    if [ "$CLAW_TOKEN" = "present" ]; then
      say "  would leave ${PERSON} resolving op:// references from their next session, because this claw holds a token"
    else
      say "  would leave ${PERSON} resolving NOTHING, because this claw holds no token at ${CC_AGENTS_TOKEN} yet"
    fi
  fi
  say "  would append one row to ${ADMIN_LOG}"
  say "  would grant NO workspace, NO sudo, NO claw-admin"
  warn "dry run: nothing was written"
  finish
fi

# ---------------------------------------------------------------- the account

useradd -m -s /bin/bash "$PERSON"
ACTION="onboarded"

HOME_DIR="$(getent passwd "$PERSON" | cut -d: -f6)"
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { say "useradd made no home for ${PERSON}"; exit 1; }

chmod 0750 "$HOME_DIR"
install -d -m 0700 -o "$PERSON" -g "$PERSON" "${HOME_DIR}/.ssh"
install -m 0600 -o "$PERSON" -g "$PERSON" /dev/null "${HOME_DIR}/.ssh/authorized_keys"
printf '%s\n' "$KEY" >> "${HOME_DIR}/.ssh/authorized_keys"

ln -sfn "$WORKSPACE_ROOT" "${HOME_DIR}/workspaces"
chown -h "$PERSON":"$PERSON" "${HOME_DIR}/workspaces"

# Phase 8's own stamp, in phase 8's words. One line appended, never a rewrite.
for f in "$PERSISTENT_CORE_FILE" "$PER_TASK_CORE_FILE"; do
  d="${HOME_DIR}/$(dirname "$f")"
  [ -d "$d" ] || install -d -m 0700 -o "$PERSON" -g "$PERSON" "$d"
  [ -e "${HOME_DIR}/${f}" ] || install -m 0644 -o "$PERSON" -g "$PERSON" /dev/null "${HOME_DIR}/${f}"
  grep -qxF "$CONVENTION_POINTER" "${HOME_DIR}/${f}" \
    || printf '%s\n' "$CONVENTION_POINTER" >> "${HOME_DIR}/${f}"
done

# and the briefing pointer, one core only, phase 8's words again
grep -qxF "$CLAW_BRIEFING_POINTER" "${HOME_DIR}/${PER_TASK_CORE_FILE}" \
  || printf '%s\n' "$CLAW_BRIEFING_POINTER" >> "${HOME_DIR}/${PER_TASK_CORE_FILE}"

# ---------------------------------------------------------------- the identity
#
# Written BY THE PERSON, through git, into an absence. Three reasons, and each
# one rules out an alternative that looks simpler:
#
#   By the person, because a file root creates in somebody's home is a file they
#   cannot write. git run under their own uid makes it with their ownership and
#   git's own mode, and this door never has to know which mode that is.
#
#   Through git rather than by appending text, because the config format has
#   sections and an append that lands under the wrong one sets nothing while
#   looking exactly like success.
#
#   Into an absence, because the same three settings are phase 8's, and a run
#   that overwrote them would replace an address somebody chose with the derived
#   one every time the claw is re-provisioned.
for k in "${GIT_IDENTITY_KEYS[@]}"; do
  if sudo -u "$PERSON" -H git config --global --get "$k" >/dev/null 2>&1; then
    warn "${PERSON} already has ${k} set; left alone"
    continue
  fi
  case "$k" in
    user.name)          v="$FULL_NAME" ;;
    user.email)         v="$EMAIL" ;;
    user.useConfigOnly) v="true" ;;
  esac
  # The write is an ATTEMPT and the read-back below is the verdict. Left fatal
  # under errexit, a refused write would take the whole run out before the
  # structured result was emitted, so the caller would learn that something went
  # wrong and not what.
  sudo -u "$PERSON" -H git config --global "$k" "$v" || warn "could not write ${k} for ${PERSON}"
done

# The claw's own briefing is written by whoever works here, and this person now
# works here. The group is the only thing that makes that file theirs.
gpasswd -a "$PERSON" "$MEMBERS_GROUP" >/dev/null

# ------------------------------------------------ the credential group grant
#
# ITS OWN STEP, AND ITS OWN LINE OF OUTPUT. This is the grant that decides
# whether the person can read the claw's agents token, and it is deliberately
# not folded into the members-group join above. Two groups with two meanings:
# the members group owns the briefing, this one owns credential read. A person
# who ends up in one and not the other is then a visible state rather than an
# invisible one.
#
# THE GROUP IS REFUSED, NOT CREATED. Groups belong to provisioning. A door that
# made one would be a second owner of the claw's access model, and the two would
# disagree the first time either changed.
if [ "$AGENTS_CRED" -eq 1 ]; then
  if getent group "$CC_AGENTS_GROUP" >/dev/null 2>&1; then
    gpasswd -a "$PERSON" "$CC_AGENTS_GROUP" >/dev/null
    say "  credential group: added ${PERSON} to ${CC_AGENTS_GROUP}, which is what makes ${CC_AGENTS_TOKEN} readable"
  else
    bad "no ${CC_AGENTS_GROUP} group on this claw, so ${PERSON} cannot be granted credential read. Provisioning creates that group; run it, then re-run this door."
  fi
else
  warn "--no-agents-cred: ${PERSON} is NOT in ${CC_AGENTS_GROUP}, so every op:// reference in their session will fail. That is a decision recorded here, not an omission."
fi

# ------------------------------------------------------- the loader and hook
#
# What turns a readable file into an exported variable in this person's own
# sessions. It carries a PATH and never a value, so it is made unconditionally
# for anybody who is not deliberately opted out, and a run makes it rather than
# a human.
#
# THE TOKEN IS NEVER THIS DOOR'S TO HANDLE, and now it is never this door's to
# reach either. The value is one root-owned file for the whole claw, written by
# `install-agents-token.sh` and by nothing else. Onboarding a person does not
# touch a credential at any point.
if [ "$AGENTS_CRED" -eq 1 ]; then
  if cc_agents_plane_install "$PERSON" "$HOME_DIR"; then
    say "  loader: made ${CC_AP_ENV} and the hook at the top of ${HOME_DIR}/.bashrc"
  else
    bad "could not make the loader in ${HOME_DIR} -- ${PERSON} will resolve no credentials"
  fi
fi
AGENTS_PLANE="$(cc_agents_plane_state "$HOME_DIR")"

# ---------------------------------------------------------------- the record

# One row, one append, one call. Nobody reads this file and writes it back, so
# no concurrent writer can lose a row to this one.
printf '| %s | %s | onboarded a person | %s |\n' "$WHEN" "$BY" "$PERSON" >> "$ADMIN_LOG"

# THE CREDENTIAL GRANT GETS ITS OWN ROW. It is a separate act with a separate
# meaning, so it is separately readable afterwards: who can read this claw's
# agents token, and when that started, is answerable from this file alone. A
# grant folded into the onboarding row would be a grant nobody can date.
if [ "$AGENTS_CRED" -eq 1 ]; then
  printf '| %s | %s | granted credential read (%s) | %s |\n' \
    "$WHEN" "$BY" "$CC_AGENTS_GROUP" "$PERSON" >> "$ADMIN_LOG"
else
  printf '| %s | %s | onboarded WITHOUT credential read (--no-agents-cred) | %s |\n' \
    "$WHEN" "$BY" "$PERSON" >> "$ADMIN_LOG"
fi

# ---------------------------------------------------------------- verify

say ""
say "=== VERIFY ==="

if getent passwd "$PERSON" >/dev/null 2>&1 && [ "$(id -u "$PERSON")" -ge 1000 ]; then
  ok "account ${PERSON} exists at uid $(id -u "$PERSON")"
else
  bad "account ${PERSON} does not exist, or is not a person's uid"
fi

home_stat="$(stat -c '%a %U' "$HOME_DIR")"
if [ "$home_stat" = "750 ${PERSON}" ]; then
  ok "home is 750 ${PERSON} -- the isolation boundary"
else
  bad "home is ${home_stat}, wanted 750 ${PERSON}"
fi

ssh_stat="$(stat -c '%a %U:%G' "${HOME_DIR}/.ssh")"
if [ "$ssh_stat" = "700 ${PERSON}:${PERSON}" ]; then
  ok ".ssh is 700 ${PERSON}:${PERSON}"
else
  bad ".ssh is ${ssh_stat}, wanted 700 ${PERSON}:${PERSON}"
fi

ak_stat="$(stat -c '%a %U:%G' "${HOME_DIR}/.ssh/authorized_keys")"
if [ "$ak_stat" = "600 ${PERSON}:${PERSON}" ]; then
  ok "authorized_keys is 600 ${PERSON}:${PERSON}"
else
  bad "authorized_keys is ${ak_stat}, wanted 600 ${PERSON}:${PERSON}"
fi

# The key is present exactly once, and it is the key that was offered. A count
# alone would pass on a file holding one line of something else.
key_count="$(grep -cxF "$KEY" "${HOME_DIR}/.ssh/authorized_keys" || true)"
if [ "$key_count" = "1" ]; then
  ok "the offered key appears exactly once in authorized_keys"
else
  bad "the offered key appears ${key_count} times in authorized_keys"
fi

installed_fp="$(ssh-keygen -l -f "${HOME_DIR}/.ssh/authorized_keys" 2>/dev/null | head -1 || true)"
if [ "$installed_fp" = "$FINGERPRINT" ]; then
  ok "the installed key fingerprints to the offered key"
else
  bad "the installed key fingerprints to '${installed_fp}', not to the offered key"
fi

if [ -L "${HOME_DIR}/workspaces" ] && [ "$(readlink "${HOME_DIR}/workspaces")" = "$WORKSPACE_ROOT" ]; then
  ok "workspaces symlink resolves to ${WORKSPACE_ROOT}"
else
  bad "workspaces is not a symlink to ${WORKSPACE_ROOT}"
fi

pointer_ok=1
for f in "$PERSISTENT_CORE_FILE" "$PER_TASK_CORE_FILE"; do
  cnt="$(grep -cxF "$CONVENTION_POINTER" "${HOME_DIR}/${f}" 2>/dev/null || true)"
  [ "$cnt" = "1" ] || { bad "${f} carries ${cnt} conventions pointers, wanted exactly one"; pointer_ok=0; }
done
[ "$pointer_ok" -eq 1 ] && ok "exactly one conventions pointer in each core's instructions file"

# The briefing pointer: present once in one core's file, ABSENT from the other.
# The absence is half the check. A later edit that writes the line to both files
# would double what every session on this claw loads on every turn, and without
# this second reading nothing here would notice.
briefing_ptr_ok=1
cnt="$(grep -cxF "$CLAW_BRIEFING_POINTER" "${HOME_DIR}/${PER_TASK_CORE_FILE}" 2>/dev/null || true)"
[ "$cnt" = "1" ] || { bad "${PER_TASK_CORE_FILE} carries ${cnt} claw-briefing pointers, wanted exactly one"; briefing_ptr_ok=0; }
cnt="$(grep -cxF "$CLAW_BRIEFING_POINTER" "${HOME_DIR}/${PERSISTENT_CORE_FILE}" 2>/dev/null || true)"
[ "$cnt" = "0" ] || { bad "${PERSISTENT_CORE_FILE} carries ${cnt} claw-briefing pointers, wanted zero -- that core walks up to the briefing already"; briefing_ptr_ok=0; }
[ "$briefing_ptr_ok" -eq 1 ] && ok "the claw-briefing pointer is in ${PER_TASK_CORE_FILE} once and absent from ${PERSISTENT_CORE_FILE}"

# --- the git identity ---
#
# Read back THROUGH GIT, AS THE PERSON, which is the surface that decides what
# their commits carry. Reading the file with grep instead would pass on a config
# git cannot parse and on one sitting where git does not look.
read_identity() { sudo -u "$PERSON" -H git config --global --get "$1" 2>/dev/null || true; }

got="$(read_identity user.name)"
if [ "$got" = "$FULL_NAME" ]; then
  ok "git reads ${PERSON}'s name as '${FULL_NAME}'"
else
  bad "git reads ${PERSON}'s name as '${got}', wanted '${FULL_NAME}'"
fi

got="$(read_identity user.email)"
if [ "$got" = "$EMAIL" ]; then
  ok "git reads ${PERSON}'s address as '${EMAIL}'"
else
  bad "git reads ${PERSON}'s address as '${got}', wanted '${EMAIL}'"
fi

got="$(read_identity user.useConfigOnly)"
if [ "$got" = "true" ]; then
  ok "git will refuse to invent an identity for ${PERSON} rather than guess one"
else
  bad "user.useConfigOnly reads '${got}', so git would invent an identity from the hostname"
fi

# The known-answer control. Three reads above returned what this door wrote; a
# read-back that returned the wanted string whatever it was asked would do the
# same. This one asks for something that was never set and requires nothing back.
got="$(read_identity "$GIT_PROBE_KEY")"
if [ -z "$got" ]; then
  ok "known-answer: ${GIT_PROBE_KEY} reads empty, so the three reads above are reads"
else
  bad "known-answer FAILED -- ${GIT_PROBE_KEY} returned '${got}' and nothing set it"
fi

# The config belongs to the person. A root-owned file in their home would carry
# their identity until the first time they tried to change it.
#
# THE PATH IS ASKED FOR, NOT ASSUMED. git's global config is `~/.gitconfig` on a
# fresh home and the XDG path on a home that already carries one, so a check
# naming either filename reports a healthy claw as broken on the other. `git
# config --show-origin` names the file the value actually came from, which is the
# only thing worth checking the owner of.
gitcfg="$(sudo -u "$PERSON" -H git config --global --show-origin --get user.email 2>/dev/null | head -1 || true)"
gitcfg="${gitcfg%%$'\t'*}"; gitcfg="${gitcfg#file:}"
if [ -n "$gitcfg" ] && [ -f "$gitcfg" ]; then
  cfg_stat="$(stat -c '%U %a' "$gitcfg")"
  case "$cfg_stat" in
    "${PERSON} "*) ok "the identity comes from ${gitcfg}, which is ${PERSON}'s to write (${cfg_stat})" ;;
    *) bad "${gitcfg} is ${cfg_stat} -- ${PERSON} cannot change their own identity" ;;
  esac
else
  bad "git names no file as the source of ${PERSON}'s address"
fi

# --- the exclusion: an identity ABOVE the person would be everybody's ---
#
# One unix user per person and no shared accounts is the claw's rule, and a name
# or address at the system level breaks it silently: every person on the box then
# commits as one identity, and each of their own configs still reads correctly
# when asked in isolation.
sys_ident=""
for k in user.name user.email; do
  v="$(git config --system --get "$k" 2>/dev/null || true)"
  [ -n "$v" ] && sys_ident="${sys_ident} ${k}=${v}"
done
if [ -z "$sys_ident" ]; then
  ok "exclusion: no git identity at the system level, so nobody here commits as somebody else"
else
  bad "a system-wide git identity exists (${sys_ident# }) -- every person on this claw would commit as it"
fi

# --- the control that says what this door did NOT do ---
#
# A door that quietly granted access would pass every check above. These read
# the person's own group list, which is the thing access is made of.
groups_text=" $(id -nG "$PERSON" 2>/dev/null || true) "
case "$groups_text" in
  *" ${MEMBERS_GROUP} "*) ok "${PERSON} is in ${MEMBERS_GROUP}, so ${CLAW_BRIEFING} is theirs to write at their next login" ;;
  *) bad "${PERSON} is not in ${MEMBERS_GROUP} -- they could read the claw's own briefing and never write it" ;;
esac

# The join above adds a group to somebody. These say what that group is worth,
# because a group everybody is in would carry whatever it reached to everybody.
if grep -rsqF "$MEMBERS_GROUP" /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
  bad "a sudoers file names ${MEMBERS_GROUP} -- a group every person is in must carry no grant"
else
  ok "no sudoers file names ${MEMBERS_GROUP}: the join granted no root"
fi
# The same scan and the same exclusions as phase 8, for the same reasons: the
# pruned trees are the ones where a group on a file grants nobody anything --
# /tmp is 1777 already and every home is 0750. Measured at 0.16 seconds on the
# staging tier, so a firm's admin waits on it and does not notice.
mg_owns="$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
                     -o -path /tmp -o -path /var/tmp -o -path /home \) -prune \
             -o -group "$MEMBERS_GROUP" -print 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' || true)"
if [ "$mg_owns" = "${CLAW_BRIEFING} " ]; then
  ok "${MEMBERS_GROUP} owns one path where ownership grants anything: ${CLAW_BRIEFING}"
else
  bad "${MEMBERS_GROUP} owns path(s) besides ${CLAW_BRIEFING} where the group is a grant: ${mg_owns}"
fi

# THE TWO GROUPS STAY TWO, and this is the reading that holds them apart. The
# members group must not reach the token, and the credential group must not
# reach anything else. Collapsing either into the other would put credential
# read on everybody who can read the briefing, which is the single change that
# would undo the point of a separate group.
case "$mg_owns" in
  *"${CC_AGENTS_TOKEN}"*) bad "${MEMBERS_GROUP} owns ${CC_AGENTS_TOKEN} -- that puts credential read on everybody who can read the briefing" ;;
esac
ac_owns="$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
                     -o -path /tmp -o -path /var/tmp -o -path /home \) -prune \
             -o -group "$CC_AGENTS_GROUP" -print 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' || true)"
case "$ac_owns" in
  ""|"${CC_AGENTS_TOKEN} ") ok "${CC_AGENTS_GROUP} owns nothing but ${CC_AGENTS_TOKEN}: its one meaning is who reads the claw's agents token" ;;
  *) bad "${CC_AGENTS_GROUP} owns path(s) besides ${CC_AGENTS_TOKEN}: ${ac_owns} -- that group means credential read and nothing else" ;;
esac

# --- the credential plane, measured rather than assumed ---
#
# THE GRANT IS READ BACK FROM THE CLAW'S OWN RECORD. A gpasswd call that ran is
# not the same claim as a person who is in the group, and the difference is the
# whole reason this is a separate step. This is the reading that stops somebody
# arriving with an account and no credential read and nothing saying so.
if [ "$AGENTS_CRED" -eq 1 ]; then
  if cc_agents_reads "$PERSON"; then
    ok "${PERSON} is in ${CC_AGENTS_GROUP}, read back from the claw's own group record"
  else
    bad "${PERSON} is NOT in ${CC_AGENTS_GROUP}. They have an account and can read no credential, which is the state this door exists to stop shipping."
  fi

  cc_agents_paths "$HOME_DIR"
  plane_ok=1
  d="$(stat -c '%a %U:%G' "$CC_AP_DIR" 2>/dev/null || echo missing)"
  [ "$d" = "700 ${PERSON}:${PERSON}" ] || { bad "${CC_AP_DIR} is ${d}, wanted 700 ${PERSON}:${PERSON}"; plane_ok=0; }
  e="$(stat -c '%a %U:%G' "$CC_AP_ENV" 2>/dev/null || echo missing)"
  [ "$e" = "600 ${PERSON}:${PERSON}" ] || { bad "${CC_AP_ENV} is ${e}, wanted 600 ${PERSON}:${PERSON}"; plane_ok=0; }
  cnt="$(grep -cxF "$CC_AP_HOOK" "${HOME_DIR}/.bashrc" 2>/dev/null || true)"
  [ "$cnt" = "1" ] || { bad "${HOME_DIR}/.bashrc carries ${cnt} loader hooks, wanted exactly one"; plane_ok=0; }
  [ "$plane_ok" -eq 1 ] && ok "the loader is there: 0700 directory, 0600 loader, exactly one hook in .bashrc"

  # NO TOKEN IN THIS HOME, and this is a reading rather than a claim. The whole
  # point of one file per claw is that no home holds the value, so a home that
  # holds one is a claw that has not converged, or somebody who put a copy back.
  if [ -e "$(cc_agents_legacy_token "$HOME_DIR")" ]; then
    bad "$(cc_agents_legacy_token "$HOME_DIR") exists -- a per-home copy of the claw token. The token is ONE file at ${CC_AGENTS_TOKEN}; run install-agents-token.sh, which rotates and removes these together."
  else
    ok "no token rests in ${HOME_DIR}: the value is one file for the whole claw and this home holds none of it"
  fi

  # The loader carries a PATH and never a value, and this is the reading that
  # says so. It is cheap, and what it catches is somebody editing a token into
  # the file that every future run of this door would then copy forward.
  if grep -q 'ops_' "$CC_AP_ENV" 2>/dev/null; then
    bad "${CC_AP_ENV} carries what looks like a token value -- the loader names a PATH and never a value"
  else
    ok "the loader carries no credential value: it names the path and nothing else"
  fi

  case "$AGENTS_PLANE" in
    wired) : ;;
    *)     bad "${PERSON} has no loader at all" ;;
  esac

  # WHAT THE PERSON ACTUALLY RESOLVES, which is the group AND the claw's file
  # together. A grant on a claw holding no token still resolves nothing, and
  # this run says which of the two is missing rather than reporting a person
  # finished and leaving them to find out.
  CLAW_TOKEN="$(cc_agents_token_state)"
  if [ "$CLAW_TOKEN" = "present" ] && cc_agents_reads "$PERSON"; then
    ok "${PERSON} resolves op:// references from their next session: they are in ${CC_AGENTS_GROUP} and this claw holds a token"
  elif [ "$CLAW_TOKEN" != "present" ]; then
    bad "this claw holds NO token at ${CC_AGENTS_TOKEN}, so ${PERSON} resolves nothing however correct their groups are. That is a claw-level gap: run install-agents-token.sh once, and everybody here resolves."
  fi
else
  warn "the credential-plane checks did NOT run: --no-agents-cred was passed. An unrun control is not a passed one, and ${PERSON} resolves nothing until somebody decides otherwise."
fi

case "$groups_text" in
  *" sudo "*) bad "${PERSON} is in the sudo group -- staff hold no root" ;;
  *) ok "${PERSON} holds no sudo" ;;
esac
case "$groups_text" in
  *" claw-admin "*) bad "${PERSON} is in claw-admin -- this door does not grant the role" ;;
  *) ok "${PERSON} holds no claw-admin role" ;;
esac
ws_groups=""
for g in $groups_text; do case "$g" in ws-*) ws_groups="$ws_groups $g" ;; esac; done
if [ -z "$ws_groups" ]; then
  ok "${PERSON} is in no ws- group: creating a person granted no workspace"
else
  bad "${PERSON} is in workspace group(s):${ws_groups} -- this door does not grant access"
fi

# --- the exclusion control: the group list is a claim, a refusal is evidence ---
probe_ws=""
for d in "$WORKSPACE_ROOT"/*; do
  [ -d "$d" ] || continue
  [ -e "${d}/.workspace.yaml" ] || continue
  probe_ws="$d"; break
done
if [ -n "$probe_ws" ]; then
  if ! sudo -u "$PERSON" -H bash -c "ls '$probe_ws'" </dev/null >/dev/null 2>&1; then
    ok "exclusion: ${PERSON} is refused $(basename "$probe_ws"), so no access came with the account"
  else
    bad "exclusion FAILED -- ${PERSON} can read $(basename "$probe_ws") with no group granting it"
  fi
else
  warn "exclusion control did NOT run: this claw carries no workspace to be refused. An unrun control is not a passed one -- re-run it once a workspace exists."
fi

say ""
say "  Next: grant the workspaces this person needs (operations/lifecycle.md), and have"
say "  them confirm the connection from their own machine. A group change takes effect on"
say "  next login."
say ""
say "  Their commits will read ${FULL_NAME} <${EMAIL}>. That address reaches no mailbox;"
say "  it is how git tells one person's work from another's. They can change it themselves"
say "  and nothing here will overwrite it."
if [ "$AGENTS_CRED" -eq 1 ] && [ "$(cc_agents_token_state)" != "present" ]; then
  say ""
  say "  NOBODY ON THIS CLAW RESOLVES CREDENTIALS YET: there is no token at ${CC_AGENTS_TOKEN}."
  say "  It is one file for the whole claw, so this is done once and it covers everybody"
  say "  in ${CC_AGENTS_GROUP}, including ${PERSON}:"
  say ""
  say "    (umask 077; op read \"op://<this claw>-agents/<this claw>-agents-broker-service-token/credential\" \\"
  say "       > /run/user/\$(id -u)/commonclaw-agents-token)"
  say "    sudo ${TOKEN_DOOR}"
fi

finish
