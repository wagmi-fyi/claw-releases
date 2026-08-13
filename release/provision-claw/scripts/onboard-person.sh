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
#   --dry-run    print the plan, change nothing
#
# WHAT IT MAKES. The five things provisioning gives a person who was in the keys
# file at build time, so somebody arriving later gets the same claw:
#   the unix account, with a home and a shell
#   the home at 0750, .ssh at 0700, authorized_keys at 0600 carrying their key
#   the workspaces symlink, one hop from home to every workspace
#   the convention pointer in each core's global instructions file, and the
#     claw-briefing pointer in the per-task core's file alone
#   membership of the claw's members group, which owns the claw-wide briefing
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
# Adding a second device to a person who already exists is a different act with
# no door today; `operations/lifecycle.md` carries it by hand.
#
# THE CONTRACT WITH PROVISIONING. The home mode, the symlink target and the two
# pointer sentences below belong to phase 8 of provision-claw.sh. Both sides name
# them and neither may move one alone. A pointer written in different words is a
# SECOND pointer, and the next provisioning run leaves the claw carrying both.
# The same contract covers WHERE each one goes: the conventions pointer in both
# cores' files, the claw-briefing pointer in the per-task core's file only, with
# its absence from the other asserted on both sides.
#
set -euo pipefail

PERSON=""; KEY=""; KEY_FILE=""; DRY_RUN=0

# The contract with the provisioning plane. Phase 8 writes these exact values.
WORKSPACE_ROOT="/srv/workspaces"
CONVENTIONS="/etc/commonclaw/workspace-conventions.md"
CONVENTION_POINTER="Workspace conventions for this claw: read ${CONVENTIONS} before working under ${WORKSPACE_ROOT}."
ADMIN_LOG="/etc/commonclaw/admin-log.md"
MEMBERS_GROUP="claw-members"
CLAW_BRIEFING="${WORKSPACE_ROOT}/CLAUDE.md"

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
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; FINGERPRINT=""; HOME_DIR=""

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

# ---- the claw ----
[ -d "$WORKSPACE_ROOT" ] || { say "no workspace root at ${WORKSPACE_ROOT} -- run the provisioning plane first"; exit 1; }
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
say "  by:   ${BY}"
say ""

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-onboard"
  say "  would create the account, the home at 0750, .ssh at 0700 and authorized_keys at 0600"
  say "  would install the key above, once"
  say "  would link ~/workspaces -> ${WORKSPACE_ROOT}"
  say "  would stamp the conventions pointer into ${PERSISTENT_CORE_FILE} and ${PER_TASK_CORE_FILE}"
  say "  would stamp the claw-briefing pointer into ${PER_TASK_CORE_FILE} alone"
  say "  would add ${PERSON} to ${MEMBERS_GROUP}, which owns ${CLAW_BRIEFING} and nothing else"
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

# The claw's own briefing is written by whoever works here, and this person now
# works here. The group is the only thing that makes that file theirs.
gpasswd -a "$PERSON" "$MEMBERS_GROUP" >/dev/null

# ---------------------------------------------------------------- the record

# One row, one append, one call. Nobody reads this file and writes it back, so
# no concurrent writer can lose a row to this one.
printf '| %s | %s | onboarded a person | %s |\n' "$WHEN" "$BY" "$PERSON" >> "$ADMIN_LOG"

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

finish
