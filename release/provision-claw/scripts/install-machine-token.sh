#!/bin/bash
#
# install-machine-token.sh — install this claw's machine-vault service-account
# token, without it passing through anybody else's hands.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   The member drops the token, then opens the door. The value never appears on
#   a screen, in a shell history, or in an argument.
#
#   FROM THEIR OWN MACHINE, which is the path that works today. A member session
#   ON a claw finds no manager account configured -- the only token on the box
#   opens the machine vault and is walled inside the backup unit -- so the
#   manager is reached from the desktop, where it is unlocked, and the value
#   crosses one ssh pipe onto memory-backed storage:
#
#     op read "op://{vault}/{hostname}-machine-broker-service-token/credential" \
#       | ssh {claw} 'umask 077; cat > /run/user/$(id -u)/commonclaw-machine-token'
#     ssh {claw} 'sudo /opt/commonclaw/provision-claw/scripts/install-machine-token.sh'
#
#   ON THE CLAW, once a member session there can reach a manager at all:
#
#     (umask 077; op read "op://{vault}/{hostname}-machine-broker-service-token/credential" \
#        > /run/user/$(id -u)/commonclaw-machine-token)
#     sudo ./install-machine-token.sh
#
#   --dry-run    check the drop and the claw, change nothing, read no token
#
# WHY THIS DOOR EXISTS. One credential rests on a claw: the token that opens its
# machine vault. Until now it reached the box through whoever provisioned the
# box, which is the last place a tenant's own credential should be. With this
# door the firm's own admin installs it, and the operator never holds it.
#
# THE DROP PATH IS NOT AN ARGUMENT, and that is a control rather than a
# convenience. A caller-supplied path would let a member name any file root can
# read and have this script encrypt it as a credential and then DESTROY it. The
# path is composed from the caller's own uid and nothing else.
#
# THREE CONSTRAINTS DECIDE THIS DESIGN.
#
# 1. THE DROP IS MEMORY-BACKED, OUTSIDE EVERYTHING THE RAIL CAPTURES. The rail
#    backs up /srv, /home and /etc/commonclaw. A token written into a home
#    enters the repository and stays for the whole retention window, so deleting
#    the file afterwards retires nothing -- whoever can restore can read it.
#    /run/user/{uid} is tmpfs: it never reaches the physical disk, it does not
#    survive a reboot, it is 0700 and owned by the caller, and the script
#    asserts the filesystem type rather than trusting this comment.
#    It also closes a quieter hole. tmpfs is a SEPARATE filesystem, so a hard
#    link from the drop path to a root-owned file elsewhere is impossible, and
#    symlinks are refused outright.
#
# 2. VERIFY BEFORE YOU BURN, at both ends. A token is proven by RESOLVING
#    SOMETHING REAL through the manager, never by comparing a size, because a
#    size passes on a credential holding the wrong bytes. Two gates:
#      gate 1, before anything on this claw moves: the offered token resolves
#              every reference the rail names. A wrong token dies here, with the
#              working credential untouched and the operator still holding the
#              only copy.
#      gate 2, after the write, at the consumed surface: the blob on disk
#              decrypts to what went in, the unit's own load path accepts it,
#              and the token read back off the disk resolves those same
#              references.
#    Only then is the drop copy destroyed. A failure after the write restores
#    the previous credential from a copy taken before it.
#
# 3. THE VALUE APPEARS NOWHERE. Not in output, not in an error, not in a log
#    line. Lengths and digests only. This script's own output is a publication
#    surface, so every line it prints -- including every failure path and every
#    message captured from another tool -- goes through one scrubber.
#
# THE CONTRACT WITH PROVISIONING. The credential path, its name, and the
# reference file below belong to phase 11 of provision-claw.sh and to the unit
# it installs. Both sides name them and neither may move one alone. The name
# matters twice: systemd refuses a correctly stored credential whose embedded
# name is not the one the unit loads.
#
set -euo pipefail

DRY_RUN=0

# The caller's environment decides nothing here. A member could export a token
# of their own, and a gate that resolved with it would prove the wrong thing.
unset OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_ACCOUNT || true
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The contract with the provisioning plane. Phase 11 writes these exact values.
ETC_ROOT="/etc/commonclaw"
CRED_NAME="op-service-account"
CRED_FILE="${ETC_ROOT}/credentials/${CRED_NAME}.cred"
ENV_FILE="${ETC_ROOT}/backup.env"
ADMIN_LOG="${ETC_ROOT}/admin-log.md"
DROP_NAME="commonclaw-machine-token"

# Root-only scratch, on the same memory-backed filesystem and for the same
# reason: what passes through here must not reach the disk and must not survive
# a reboot.
WORKDIR="/run/commonclaw"

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
ACTION="none"; TOKEN=""; DROP=""

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

# refuse <message> — a refusal is an output path too, so it scrubs like the rest
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
  printf '  "script": "install-machine-token",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "credential": "%s",\n' "$(json_esc "$CRED_NAME")"
  printf '  "credential_path": "%s",\n' "$(json_esc "$CRED_FILE")"
  printf '  "drop_path": "%s",\n' "$(json_esc "$DROP")"
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
# success path takes, and an exit on any other path must leave the operator
# holding their only copy.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() { TOKEN=""; rm -rf -- "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { printf 'run this as root\n' >&2; exit 1; }

for t in op systemd-creds sha256sum install stat; do
  command -v "$t" >/dev/null 2>&1 || refuse "this claw has no ${t}, which this door needs"
done

[ -r "$ENV_FILE" ] || refuse "no ${ENV_FILE}: this claw has no rail references to resolve, so a token cannot be proven here. Run the provisioning plane first."
grep -q '^[A-Z_][A-Z_0-9]*=op://' "$ENV_FILE" \
  || refuse "${ENV_FILE} carries no op:// references, so there is nothing real to resolve"
[ -d "$(dirname "$CRED_FILE")" ] \
  || refuse "no credential directory at $(dirname "$CRED_FILE") -- run the provisioning plane first"
[ -f "$ADMIN_LOG" ] || refuse "no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down. The log is seeded by provisioning."

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

drop_recipe() {
  say "Drop the token first, then run this again. From your own machine, where your"
  say "manager is unlocked -- a session on this claw cannot reach one:"
  say ""
  say "  op read \"op://<your-machine-vault>/<item>/credential\" \\"
  say "    | ssh $(hostname) 'umask 077; cat > ${DROP}'"
  say ""
  say "The path is fixed and the file must be yours, regular, and unreadable by anyone else."
}

if [ ! -d "$DROP_DIR" ]; then
  say "no runtime directory at ${DROP_DIR}."
  say "It exists while you have a live login session. Reconnect, then drop the token and run this again."
  exit 1
fi

# tmpfs is the whole guarantee that this path never reaches the disk, so assert
# it rather than assume it.
DROP_FS="$(stat -f -c '%T' "$DROP_DIR" 2>/dev/null || echo unknown)"
[ "$DROP_FS" = "tmpfs" ] \
  || refuse "${DROP_DIR} is on ${DROP_FS}, not tmpfs. Refusing: a token dropped there could reach the disk."

[ "$(stat -c '%u' "$DROP_DIR")" = "$CALLER_UID" ] \
  || refuse "${DROP_DIR} does not belong to the calling uid"

if [ ! -e "$DROP" ]; then
  say "no token at ${DROP}."
  drop_recipe
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
# Nobody but the owner. 0600 and 0400 both pass; anything with a group or other
# bit means the token was readable by another account while it sat there.
[ $(( 8#${FD_MODE} & 8#077 )) -eq 0 ] \
  || refuse "the drop file is mode ${FD_MODE}, readable beyond you. Drop it under umask 077 and mint a fresh token: this one was exposed."
case "$FD_SIZE" in ''|*[!0-9]*) refuse "cannot size the opened drop file" ;; esac
[ "$FD_SIZE" -gt 0 ] || refuse "the drop file is empty"
[ "$FD_SIZE" -le 65536 ] || refuse "the drop file is ${FD_SIZE} bytes, far larger than a token. Refusing rather than guessing what it is."

say ""
say "=== install ${CRED_NAME} ==="
say "  drop:   ${DROP}  (${FD_SIZE} bytes, tmpfs, ${FD_MODE}, uid ${FD_UID})"
say "  target: ${CRED_FILE}"
say "  by:     ${BY}"
say ""

if [ "$DRY_RUN" -eq 1 ]; then
  exec 9<&-
  ACTION="would-install"
  say "  would resolve every reference in ${ENV_FILE} with the offered token, before touching anything"
  say "  would copy the current credential aside, then encrypt the token into ${CRED_FILE}"
  say "  would prove the installed credential decrypts, loads as a unit credential, and resolves"
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

# ---------------------------------------------------------------- gate 1
#
# Resolve something real, before this claw moves at all. `op run` puts the
# referenced values in the child's environment; the child prints their LENGTHS
# and nothing else.
say ""
say "=== GATE 1: the offered token resolves the rail's own references ==="

# stdout carries the lengths and nothing else, so a chatty manager cannot be
# read as a resolved value. Its own words go to a file and come back scrubbed.
resolve_with() {
  OP_SERVICE_ACCOUNT_TOKEN="$1" op run --env-file="$ENV_FILE" -- \
    /bin/sh -c 'printf "%s %s %s" "${#RESTIC_PASSWORD}" "${#AWS_ACCESS_KEY_ID}" "${#AWS_SECRET_ACCESS_KEY}"' \
    2>"${WORKDIR}/manager.err"
}
manager_said() { tr '\n' ' ' < "${WORKDIR}/manager.err" 2>/dev/null | cut -c1-300; }

g1_out=""; g1_rc=0
g1_out="$(resolve_with "$TOKEN")" || g1_rc=$?
if [ "$g1_rc" -ne 0 ]; then
  bad "gate 1: the offered token does NOT resolve this claw's references (manager exit ${g1_rc})"
  say ""
  say "  the manager said: $(manager_said)"
  say ""
  warn "nothing on this claw was touched, and ${DROP} was NOT destroyed -- you still hold the only copy"
  ACTION="refused-before-write"
  finish
fi
case "$g1_out" in
  *" 0"|"0 "*|*" 0 "*) bad "gate 1: a reference resolved to an EMPTY value (lengths: ${g1_out})"; ACTION="refused-before-write"; finish ;;
esac
ok "gate 1: every reference in $(basename "$ENV_FILE") resolved (lengths: ${g1_out})"

# ---------------------------------------------------------------- the write

PREV_SHA=""
if [ -f "$CRED_FILE" ]; then
  PREV_SHA="$(sha256sum "$CRED_FILE" | cut -d' ' -f1)"
  install -m 0600 -o root -g root "$CRED_FILE" "${WORKDIR}/previous.cred"
  say ""
  say "  previous credential copied aside: $(stat -c '%s' "$CRED_FILE") bytes, sha256 ${PREV_SHA:0:16}"
fi

# Restore the machine to the credential it had. Called on every failure path
# after the write, so a bad install never outlives this run.
restore_previous() {
  if [ -n "$PREV_SHA" ]; then
    install -m 0600 -o root -g root "${WORKDIR}/previous.cred" "$CRED_FILE"
    local now; now="$(sha256sum "$CRED_FILE" | cut -d' ' -f1)"
    if [ "$now" = "$PREV_SHA" ]; then
      ok "restored: the credential on disk is byte-identical to the one this run found (sha256 ${now:0:16})"
    else
      bad "RESTORE FAILED: ${CRED_FILE} is sha256 ${now:0:16}, not the ${PREV_SHA:0:16} this run found. The copy is at ${WORKDIR}/previous.cred and this run has NOT removed it."
      trap - EXIT   # leave the scratch copy in place; a broken rail beats a tidy one
    fi
  else
    rm -f -- "$CRED_FILE"
    ok "removed the credential this run wrote: this claw had none before, and it has none now"
  fi
}

say ""
say "=== the write ==="

# mktemp reserves the name, then hands it over: the store writes its own file
# and refuses an existing one. Same directory as the target, so the rename below
# is a rename and not a copy.
NEW_CRED="$(mktemp "$(dirname "$CRED_FILE")/.cred.XXXXXX")"
rm -f -- "$NEW_CRED"
if ! printf '%s' "$TOKEN" | systemd-creds encrypt --name="$CRED_NAME" - "$NEW_CRED" 2>/dev/null; then
  rm -f -- "$NEW_CRED"
  bad "the host credential store refused to encrypt the token; nothing was replaced"
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  ACTION="refused-before-write"
  finish
fi
# One rename on one filesystem, so no reader ever sees a half-written blob.
mv -f "$NEW_CRED" "$CRED_FILE"
chown root:root "$CRED_FILE"; chmod 0600 "$CRED_FILE"
ACTION="installed"
say "  wrote ${CRED_FILE}: $(stat -c '%s' "$CRED_FILE") bytes, $(stat -c '%a %U:%G' "$CRED_FILE")"

# ---------------------------------------------------------------- gate 2
#
# At the consumed surface, in three legs, because they fail for different
# reasons: the bytes, the name systemd loads it by, and the manager.
say ""
say "=== GATE 2: the installed credential, at the surface that consumes it ==="

READBACK=""; rb_rc=0
READBACK="$(systemd-creds decrypt --name="$CRED_NAME" "$CRED_FILE" - 2>/dev/null)" || rb_rc=$?
if [ "$rb_rc" -ne 0 ]; then
  bad "gate 2a: the installed credential does not decrypt under the name ${CRED_NAME}"
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi
RB_SHA="$(printf '%s' "$READBACK" | sha256sum | cut -d' ' -f1)"
if [ "$RB_SHA" = "$TOKEN_SHA" ]; then
  ok "gate 2a: the blob decrypts to exactly what went in (${#READBACK} bytes, sha256 ${RB_SHA:0:16})"
else
  bad "gate 2a: the blob decrypts to sha256 ${RB_SHA:0:16}, not the ${TOKEN_SHA:0:16} that went in"
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi

# The unit's own load path. systemd refuses a credential whose embedded name is
# not the one being loaded, and that refusal is invisible to a plain decrypt
# that was told the right name. The child prints a byte count, never the value.
u_out=""; u_rc=0
u_out="$(systemd-run --quiet --pipe --wait \
          --property="LoadCredentialEncrypted=${CRED_NAME}:${CRED_FILE}" \
          /bin/sh -c 'wc -c < "$CREDENTIALS_DIRECTORY"/'"${CRED_NAME}" 2>&1)" || u_rc=$?
u_out="$(printf '%s' "$u_out" | tr -d '[:space:]')"
if [ "$u_rc" -eq 0 ] && [ "$u_out" = "${#TOKEN}" ]; then
  ok "gate 2b: a unit loads it as ${CRED_NAME} and receives ${u_out} bytes"
elif [ "$u_rc" -eq 0 ]; then
  bad "gate 2b: a unit loaded ${CRED_NAME} but received '${u_out}' bytes, not ${#TOKEN}"
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
else
  bad "gate 2b: no unit can load ${CRED_NAME} from this file (exit ${u_rc}): $(printf '%s' "$u_out" | cut -c1-200)"
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi

g2_out=""; g2_rc=0
g2_out="$(resolve_with "$READBACK")" || g2_rc=$?
READBACK=""
if [ "$g2_rc" -ne 0 ]; then
  bad "gate 2c: the token read back off this disk does not resolve the rail's references (manager exit ${g2_rc})"
  restore_previous
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi
ok "gate 2c: the credential ON THIS DISK resolves every reference in $(basename "$ENV_FILE") (lengths: ${g2_out})"

# ---------------------------------------------------------------- the burn

# Only here, and only because both gates passed. On tmpfs an unlink frees the
# pages; there is no on-disk remnant to overwrite, which is why the drop path
# was chosen rather than shredded.
rm -f -- "$DROP"
if [ -e "$DROP" ]; then
  bad "the drop copy at ${DROP} is still there after removal"
else
  ok "the drop copy is destroyed: ${DROP} is gone"
fi
rm -f -- "${WORKDIR}/previous.cred"

# ---------------------------------------------------------------- the record

# The event, never the value: no length and no digest reaches this file, because
# it is world-readable and its readers are the firm's own people.
WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '| %s | %s | installed the machine broker token | %s |\n' "$WHEN" "$BY" "$CRED_NAME" >> "$ADMIN_LOG"

say ""
say "  The rail resolves through the credential you installed. Nobody else held it."
if [ -n "$PREV_SHA" ]; then
  warn "the credential this replaced (sha256 ${PREV_SHA:0:16}) is superseded on the box. If it was a different token, revoke it at the manager: replacing a file revokes nothing."
fi

finish
