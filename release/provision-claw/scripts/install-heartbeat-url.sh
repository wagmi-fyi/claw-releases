#!/bin/bash
#
# install-heartbeat-url.sh — put this claw's heartbeat ping URL into this claw's
# own machine vault, without it passing through anybody else's hands.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   The URL is dropped onto memory-backed storage, then this door is opened. The
#   value never appears on a screen, in a shell history, or in an argument.
#
#     heartbeat-enroll.sh <hostname>          # from the hub: makes the check
#                                             # and pipes the URL into the drop
#     sudo ./install-heartbeat-url.sh
#
#   Or by hand, from a machine where the check's dashboard is open:
#
#     printf '%s' '<ping url>' \
#       | ssh {claw} 'umask 077; cat > /run/user/$(id -u)/commonclaw-heartbeat-url'
#     ssh {claw} 'sudo /opt/commonclaw/provision-claw/scripts/install-heartbeat-url.sh'
#
#   --dry-run    check the drop and the claw, change nothing, write nothing
#
# WHY THIS DOOR EXISTS. The memory check's dead-man ping is the only thing that
# notices a claw that has gone quiet, and it makes one request to a check that
# lives off the box. That check's URL is a credential: whoever holds it can ping
# it and make a dead claw look healthy. So it is stored the way the Slack webhook
# is, in the claw's own machine vault, and provisioning writes only the reference.
# Somebody still has to put the value there, and until this door existed that
# meant an operator handling a tenant's credential.
#
# THE VAULT AND THE ITEM ARE NOT ARGUMENTS. They are parsed out of the reference
# the claw already carries in memory.env, which is the file the memory check
# resolves at every beat. One source, so the item this door writes and the item
# that claw reads cannot drift. A door that took them as arguments could write a
# perfectly good item nothing on the box ever looks at.
#
# THE DROP PATH IS NOT AN ARGUMENT EITHER, for install-machine-token.sh's reason:
# a caller-supplied path would let a member name any file root can read and have
# this script publish it into a vault and then destroy it. The path is composed
# from the caller's own uid and nothing else.
#
# THE THREE CONSTRAINTS ARE THAT DOOR'S THREE, and they are the same constraints
# because it is the same act one layer out.
#
# 1. THE DROP IS MEMORY-BACKED, OUTSIDE EVERYTHING THE RAIL CAPTURES. The rail
#    backs up /srv, /home and /etc/commonclaw. /run/user/{uid} is tmpfs: it never
#    reaches the physical disk, it does not survive a reboot, it is 0700 and
#    owned by the caller, and the script asserts the filesystem type rather than
#    trusting this comment. tmpfs is also a separate filesystem, so a hard link
#    from the drop path to a root-owned file elsewhere is impossible, and
#    symlinks are refused outright.
#
# 2. VERIFY BEFORE YOU BURN. The URL is read back THROUGH THE REFERENCE the
#    memory check uses, not out of the item this door just wrote by another
#    route. A read-back that took a different path proves the write and not the
#    thing that depends on it. Only when the resolved value matches what went in
#    is the drop copy destroyed.
#
# 3. THE VALUE APPEARS NOWHERE. Not in output, not in an error, not in a log
#    line, and not on a command line: /proc/PID/cmdline is world-readable and
#    this claw is deliberately multi-user, so the value reaches `op` through a
#    JSON template on root-only memory-backed storage instead of an argument.
#    Every line this script prints goes through one scrubber.
#
# NOT ON THE MEMBER PLANE YET, and that is stated rather than assumed. The
# sudoers drop-in names eleven scripts and this is not one of them, so today it
# is run as root: by the operator, or by a claw-admin on a claw in wide mode.
# Granting it is a separate decision, because adding a door widens the plane the
# scope control measures, and this one writes into the firm's own vault.
#
# WHAT A REFUSED WRITE MEANS. The claw's own service account must hold write on
# the claw's own machine vault. A service account with read alone is the ordinary
# shape today, so a refusal here is expected rather than exceptional: this script
# says which vault refused it and exits non-zero, and it leaves no half-written
# item behind, because a create that fails creates nothing and an edit that fails
# changes nothing.
#
# EXIT CODES. 0 the reference resolves to the URL that was dropped. 1 something
# this script owns did not take. 2 usage, or a claw that is not ready.
#
# THE OVERRIDES BELOW EXIST FOR CONTROLS. MEMORY_ENV, CRED_FILE, OP_BIN and
# WORKDIR point this script at fixtures. Nothing on a claw sets them.
#
set -euo pipefail

DRY_RUN=0

# The caller's environment decides nothing. A member could export a token of
# their own, and a write that used it would put the URL somewhere else.
unset OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_ACCOUNT || true
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ETC_ROOT="/etc/commonclaw"
MEMORY_ENV="${MEMORY_ENV:-${ETC_ROOT}/memory.env}"
CRED_NAME="op-service-account"
CRED_FILE="${CRED_FILE:-${ETC_ROOT}/credentials/${CRED_NAME}.cred}"
ADMIN_LOG="${ETC_ROOT}/admin-log.md"
DROP_NAME="commonclaw-heartbeat-url"
OP_BIN="${OP_BIN:-op}"

# Root-only scratch on the same memory-backed filesystem, for the same reason:
# the template that carries the value must not reach the disk and must not
# survive a reboot.
WORKDIR="${WORKDIR:-/run/commonclaw}"

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
ACTION="none"; URL=""; DROP=""; VAULT=""; ITEM=""; FIELD=""; REFERENCE=""

# ---------------------------------------------------------------- the scrubber
#
# One function, applied to every line this script emits. A redaction placed per
# call site is a redaction somebody adds a call site past, and the failure paths
# are where a value most often escapes.
scrub() {
  local s="$1"
  [ -n "$URL" ] && s="${s//"$URL"/<redacted>}"
  printf '%s' "$s"
}

say()  { printf '%s\n' "$(scrub "$*")" >&2; }
ok()   { local m; m="$(scrub "$*")"; printf '  OK    %s\n' "$m" >&2; CHK_DESC+=("$m"); CHK_OK+=(true); return 0; }
bad()  { local m; m="$(scrub "$*")"; printf '  FAIL  %s\n' "$m" >&2; CHK_DESC+=("$m"); CHK_OK+=(false); FAILED=1; return 0; }
warn() { local m; m="$(scrub "$*")"; printf '  note  %s\n' "$m" >&2; NOTES+=("$m"); return 0; }

refuse() { say "$*"; exit 2; }

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
  printf '  "script": "install-heartbeat-url",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "vault": "%s",\n' "$(json_esc "$VAULT")"
  printf '  "item": "%s",\n' "$(json_esc "$ITEM")"
  printf '  "reference": "%s",\n' "$(json_esc "$REFERENCE")"
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

# Whatever happens, the value leaves this process's memory and the scratch tree
# goes with it. The drop copy is NOT removed here: burning it is a decision the
# success path takes, and an exit on any other path must leave the operator
# holding their only copy.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() { URL=""; rm -rf -- "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { printf 'run this as root\n' >&2; exit 2; }

for t in "$OP_BIN" systemd-creds install stat; do
  command -v "$t" >/dev/null 2>&1 || refuse "this claw has no ${t}, which this door needs"
done

[ -r "$MEMORY_ENV" ] \
  || refuse "no ${MEMORY_ENV}: this claw carries no heartbeat reference, so there is nothing to fill. Run the provisioning plane first."

REFERENCE="$(sed -n 's/^COMMONCLAW_HEARTBEAT_URL=//p' "$MEMORY_ENV" | tail -1)"
REFERENCE="${REFERENCE%\"}"; REFERENCE="${REFERENCE#\"}"
case "$REFERENCE" in
  op://*) : ;;
  "") refuse "${MEMORY_ENV} names no COMMONCLAW_HEARTBEAT_URL, so nothing on this claw would read what this door wrote" ;;
  *)  refuse "COMMONCLAW_HEARTBEAT_URL in ${MEMORY_ENV} is not an op:// reference. If it holds a literal URL, that is a credential at rest inside the backed-up config root: rotate the check and remove the line." ;;
esac

# op://VAULT/ITEM/FIELD. A reference with the wrong number of parts would make
# this door write into a vault nobody named.
_ref="${REFERENCE#op://}"
VAULT="${_ref%%/*}"; _rest="${_ref#*/}"
ITEM="${_rest%%/*}"; FIELD="${_rest#*/}"
case "$FIELD" in */*) FIELD="${FIELD##*/}" ;; esac
[ -n "$VAULT" ] && [ -n "$ITEM" ] && [ -n "$FIELD" ] \
  || refuse "cannot read a vault, an item and a field out of ${REFERENCE}"

[ -r "$CRED_FILE" ] \
  || refuse "no machine credential at ${CRED_FILE}: this claw cannot reach its own vault. Install the machine token first."

# ---- the caller, and therefore the drop path ----
#
# From the uid sudo recorded, never from the environment: XDG_RUNTIME_DIR is
# caller-settable, and a caller-settable drop path is the hole this door must
# not have.
CALLER_UID="${SUDO_UID:-$(id -u)}"
case "$CALLER_UID" in ''|*[!0-9]*) refuse "cannot determine the calling uid" ;; esac
BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z_]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac

DROP_DIR="/run/user/${CALLER_UID}"
DROP="${DROP_DIR}/${DROP_NAME}"

if [ ! -d "$DROP_DIR" ]; then
  say "no runtime directory at ${DROP_DIR}."
  say "It exists while you have a live login session. Reconnect, then drop the URL and run this again."
  exit 2
fi

DROP_FS="$(stat -f -c '%T' "$DROP_DIR" 2>/dev/null || echo unknown)"
[ "$DROP_FS" = "tmpfs" ] \
  || refuse "${DROP_DIR} is on ${DROP_FS}, not tmpfs. Refusing: a URL dropped there could reach the disk."
[ "$(stat -c '%u' "$DROP_DIR")" = "$CALLER_UID" ] \
  || refuse "${DROP_DIR} does not belong to the calling uid"

if [ ! -e "$DROP" ]; then
  say "no heartbeat URL at ${DROP}."
  say ""
  say "Drop it first, from the machine where the check's dashboard is open:"
  say ""
  say "  printf '%s' '<ping url>' \\"
  say "    | ssh $(hostname) 'umask 077; cat > ${DROP}'"
  say ""
  say "Or let the hub make the check and drop it for you: heartbeat-enroll.sh $(hostname)"
  exit 2
fi

# The path checks, then the same checks on the OPEN file, so a swap between the
# two cannot decide what gets read.
[ ! -L "$DROP" ] || refuse "${DROP} is a symlink. Refusing: this door reads a file you wrote, not a file you pointed at."
[ -f "$DROP" ]   || refuse "${DROP} is not a regular file"

exec 9<"$DROP"
[ -f /proc/self/fd/9 ] || refuse "the opened drop is not a regular file"
FD_UID="$(stat -L -c '%u' /proc/self/fd/9 2>/dev/null || echo "")"
FD_MODE="$(stat -L -c '%a' /proc/self/fd/9 2>/dev/null || echo "")"
FD_SIZE="$(stat -L -c '%s' /proc/self/fd/9 2>/dev/null || echo "")"
[ -n "$FD_UID" ] && [ -n "$FD_MODE" ] && [ -n "$FD_SIZE" ] \
  || refuse "cannot inspect the opened drop file"
[ "$FD_UID" = "$CALLER_UID" ] \
  || refuse "the opened drop belongs to uid ${FD_UID}, not to you. Refusing: this door installs your drop, not somebody else's file."
[ $(( 8#${FD_MODE} & 8#077 )) -eq 0 ] \
  || refuse "the drop file is mode ${FD_MODE}, readable beyond you. Drop it under umask 077 and make a fresh check: this URL was exposed."
case "$FD_SIZE" in ''|*[!0-9]*) refuse "cannot size the opened drop file" ;; esac
[ "$FD_SIZE" -gt 0 ] || refuse "the drop file is empty"
[ "$FD_SIZE" -le 4096 ] || refuse "the drop file is ${FD_SIZE} bytes, far larger than a URL. Refusing rather than guessing what it is."

say ""
say "=== install the heartbeat URL for $(hostname) ==="
say "  drop:      ${DROP}  (${FD_SIZE} bytes, tmpfs, ${FD_MODE}, uid ${FD_UID})"
say "  reference: ${REFERENCE}"
say "  vault:     ${VAULT}"
say "  item:      ${ITEM}"
say "  by:        ${BY}"
say ""

if [ "$DRY_RUN" -eq 1 ]; then
  exec 9<&-
  ACTION="would-install"
  say "  would read the drop, shape-check it, and write it into ${VAULT} as ${ITEM}"
  say "  would resolve ${REFERENCE} and require it to match what went in"
  say "  would destroy ${DROP} only after that"
  warn "dry run: the drop was not read, and nothing was written"
  finish
fi

# ---------------------------------------------------------------- the value

URL="$(cat <&9)"
exec 9<&-

# A trailing newline from a shell redirect is stripped by the substitution. A
# value with any OTHER whitespace in it is not a URL.
[ -n "$URL" ] || refuse "the drop file holds nothing once its trailing newline is removed"
case "$URL" in
  *[[:space:]]*) refuse "the dropped value carries whitespace, so it is not a ping URL. Check what was piped in." ;;
esac
# https and nothing else. A ping over plain http announces this claw's liveness
# to the path, and the URL IS the whole authentication.
case "$URL" in
  https://*) : ;;
  *) refuse "the dropped value does not begin with https://. Nothing was written." ;;
esac
URL_SHA="$(printf '%s' "$URL" | sha256sum | cut -d' ' -f1)"
say "  offered URL: ${#URL} bytes, sha256 ${URL_SHA:0:16}"

install -d -m 0700 -o root -g root "$WORKDIR"

# ---------------------------------------------------------------- the token

TOKEN=""
if ! TOKEN="$(systemd-creds decrypt --name="$CRED_NAME" "$CRED_FILE" - 2>/dev/null)"; then
  bad "the machine credential at ${CRED_FILE} does not decrypt under the name ${CRED_NAME}, so this claw cannot reach its own vault"
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  ACTION="refused-before-write"
  finish
fi
ok "the machine credential decrypts, so this claw can act as itself"

# ---------------------------------------------------------------- the write
#
# THE VALUE REACHES `op` THROUGH A TEMPLATE ON TMPFS, never through an argument.
# Both `op item create` and `op item edit` take --template; assignment statements
# would put the URL in argv, where every account on this claw can read it out of
# /proc while the call is open.
#
# STDIN IS CLOSED ON BOTH WRITES, and that is the fix for the defect this door
# shipped with. `op item create --template` and `op item edit --template` refuse
# when stdin is not a terminal, saying they cannot take a template and stdin at
# the same time. Over ssh this script's stdin is a socket, so every
# non-interactive invocation was refused, and the message blamed a vault
# permission. Redirecting from /dev/null makes stdin a regular file at EOF,
# which the manager accepts. Proven on staging on 2026-09-02 by driving the
# shipped script unchanged with only its stdin closed.
TEMPLATE="${WORKDIR}/item.json"
: > "$TEMPLATE"; chmod 0600 "$TEMPLATE"
printf '{"title":"%s","category":"API_CREDENTIAL","fields":[{"id":"%s","type":"CONCEALED","label":"%s","value":"%s"}]}\n' \
  "$ITEM" "$FIELD" "$FIELD" "$URL" > "$TEMPLATE"

op_said() { tr '\n' ' ' < "${WORKDIR}/op.err" 2>/dev/null | cut -c1-300; }

# WHAT THE MANAGER SAID DECIDES WHAT THIS DOOR SAYS.
#
# The old message named a missing write grant on every refusal. The first real
# refusal in the field was a usage error, and an operator following that message
# would have gone and granted a permission the account already held, then seen
# the same failure again. This is the accept-with-a-ledger law turned against
# itself: a pre-attributed signature swallowing a different cause.
#
# So the exit is CLASSIFIED and never asserted. Where the manager's words fit
# none of these, this says so rather than picking the likeliest.
op_failure_class() {
  case "$(op_said)" in
    *"stdin at the same time"*|*"Usage:"*|*"usage:"*|*"unknown flag"*|*"unknown command"*|*"accepts "*)
      printf 'the manager refused the CALL rather than the write: it read this invocation as malformed' ;;
    *"denied"*|*"not allowed"*|*"ermission"*|*"not authorized"*|*"no access"*|*"403"*)
      printf 'the manager refused on PERMISSION: this account does not hold write on this vault' ;;
    *"401"*|*"authenticat"*|*"invalid token"*|*"service account"*)
      printf 'the manager refused the CREDENTIAL: the token this claw decrypted was not accepted' ;;
    *"connection"*|*"network"*|*"timeout"*|*"timed out"*|*"dial tcp"*|*"no such host"*|*"TLS"*|*"i/o"*)
      printf 'the manager could not REACH the service' ;;
    *)
      printf 'the manager gave a reason this door does not classify' ;;
  esac
}

say ""
say "=== the write ==="

exists=0
if OP_SERVICE_ACCOUNT_TOKEN="$TOKEN" "$OP_BIN" item get "$ITEM" --vault "$VAULT" \
     --format json >/dev/null 2>"${WORKDIR}/op.err"; then
  exists=1
fi

wr_rc=0
if [ "$exists" -eq 1 ]; then
  ACTION="edited"
  say "  ${ITEM} already exists in ${VAULT}; its ${FIELD} field is being replaced"
  OP_SERVICE_ACCOUNT_TOKEN="$TOKEN" "$OP_BIN" item edit "$ITEM" --vault "$VAULT" \
    --template "$TEMPLATE" </dev/null >/dev/null 2>"${WORKDIR}/op.err" || wr_rc=$?
else
  ACTION="created"
  say "  ${ITEM} does not exist in ${VAULT} and is being created"
  OP_SERVICE_ACCOUNT_TOKEN="$TOKEN" "$OP_BIN" item create --vault "$VAULT" \
    --template "$TEMPLATE" </dev/null >/dev/null 2>"${WORKDIR}/op.err" || wr_rc=$?
fi
rm -f -- "$TEMPLATE"

if [ "$wr_rc" -ne 0 ]; then
  bad "the vault ${VAULT} did not take the write (manager exit ${wr_rc}). $(op_failure_class)."
  say ""
  say "  the manager said: $(op_said)"
  say ""
  say "  This door does not decide the cause. Read the line above before changing any grant:"
  say "  a usage refusal and a permission refusal both exit non-zero and need opposite work."
  say ""
  warn "nothing was changed: a create that fails creates nothing and an edit that fails changes nothing"
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  ACTION="refused-by-vault"
  TOKEN=""
  finish
fi
ok "the vault accepted the write (${ACTION})"

# ---------------------------------------------------------------- the gate
#
# READ BACK THROUGH THE REFERENCE, which is the path the memory check takes on
# every beat. Reading the item back by name would prove the write and not the
# thing that depends on it: a reference naming a field this door did not fill
# resolves to nothing while the item looks perfect.
say ""
say "=== the gate: the reference the memory check reads resolves to what went in ==="

rb=""; rb_rc=0
rb="$(OP_SERVICE_ACCOUNT_TOKEN="$TOKEN" "$OP_BIN" read "$REFERENCE" 2>"${WORKDIR}/op.err")" || rb_rc=$?
TOKEN=""
if [ "$rb_rc" -ne 0 ]; then
  bad "${REFERENCE} does not resolve after the write (manager exit ${rb_rc}). $(op_failure_class): $(op_said)"
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi
RB_SHA="$(printf '%s' "$rb" | sha256sum | cut -d' ' -f1)"
rb=""
if [ "$RB_SHA" = "$URL_SHA" ]; then
  ok "the reference resolves to exactly what was dropped (sha256 ${RB_SHA:0:16})"
else
  bad "the reference resolves to sha256 ${RB_SHA:0:16}, not the ${URL_SHA:0:16} that went in. Something else is in that field."
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
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

# ---------------------------------------------------------------- the record

# The event, never the value. This file is world-readable and its readers are
# the firm's own people.
if [ -f "$ADMIN_LOG" ]; then
  WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '| %s | %s | %s the heartbeat URL | %s |\n' "$WHEN" "$BY" "$ACTION" "$ITEM" >> "$ADMIN_LOG"
else
  warn "no member-plane record at ${ADMIN_LOG}, so this act was not written down there"
fi

say ""
say "  The dead-man ping resolves. This claw's silence is now somebody else's alarm."
warn "the off-box check's grace period and this claw's beat interval are two numbers nothing compares. Lengthening the beat without lengthening the grace turns every beat into a false alarm."

finish
