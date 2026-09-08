#!/bin/bash
#
# install-email-provider-key.sh: put this claw's mail provider key into this
# claw's own machine vault, without it passing through anybody else's hands.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   The key is dropped onto memory-backed storage, then this door is opened. The
#   value never appears on a screen, in a shell history, or in an argument.
#
#     printf '%s' '<provider api key>' \
#       | ssh {claw} 'umask 077; cat > /run/user/$(id -u)/commonclaw-email-provider-key'
#     ssh {claw} 'sudo /opt/commonclaw/provision-claw/scripts/install-email-provider-key.sh'
#
#   --dry-run    check the drop and the claw, change nothing, write nothing
#
# WHY THIS DOOR EXISTS. The gatekeeper holds one key that can send mail as this
# firm and read everything that arrives. Whoever holds it can write to this
# firm's clients under this firm's name. So it is stored the way the alarm
# webhook and the heartbeat URL are, in the claw's own machine vault, and
# provisioning writes only the reference. Somebody still has to put the value
# there, and without this door that means an operator handling a firm's
# credential.
#
# THE VAULT AND THE ITEM ARE NOT ARGUMENTS. They are parsed out of the reference
# the claw already carries in email-gatekeeper.env, which is the file the service
# resolves at start. One source, so the item this door writes and the item the
# service reads cannot drift. A door that took them as arguments could write a
# perfectly good item nothing on the box ever looks at.
#
# THE DROP PATH IS NOT AN ARGUMENT EITHER: a caller-supplied path would let a
# member name any file root can read and have this script publish it into a vault
# and then destroy it. The path is composed from the caller's own uid.
#
# THE THREE CONSTRAINTS ARE install-heartbeat-url.sh's THREE, because it is the
# same act on a different secret.
#
# 1. THE DROP IS MEMORY-BACKED, OUTSIDE EVERYTHING THE RAIL CAPTURES.
#    /run/user/{uid} is tmpfs: it never reaches the physical disk, it does not
#    survive a reboot, it is 0700 and owned by the caller, and this script
#    asserts the filesystem type rather than trusting this comment.
# 2. VERIFY BEFORE YOU BURN. The key is read back THROUGH THE REFERENCE the
#    service resolves, not out of the item this door just wrote by another
#    route. Only when the resolved value matches what went in is the drop copy
#    destroyed.
# 3. THE VALUE APPEARS NOWHERE. Not in output, not in an error, not in a log
#    line, and not on a command line: /proc/PID/cmdline is world-readable and
#    this claw is deliberately multi-user, so the value reaches `op` through a
#    JSON template on root-only memory-backed storage.
#
# AND THE FOURTH, WHICH THE OTHER TWO DOORS DO NOT NEED. A running service holds
# the key it started with. Writing the vault item under a live gatekeeper installs
# right, verifies right, and does not run: the process keeps reaching nothing. So
# this door restarts the unit after the gate passes and reports the pid it moved
# to. That is the installs-right-does-not-run law, and it bit this project twice
# in one hour on 2026-09-02.
#
# WHAT A REFUSED WRITE MEANS. The claw's own service account must hold write on
# the claw's own machine vault. A service account with read alone is the ordinary
# shape today, so a refusal here is expected rather than exceptional: this script
# says which vault refused it and exits non-zero, and it leaves no half-written
# item behind.
#
# EXIT CODES. 0 the reference resolves to the key that was dropped. 1 something
# this script owns did not take. 2 usage, or a claw that is not ready.
#
# THE OVERRIDES BELOW EXIST FOR CONTROLS. GATEKEEPER_ENV, CRED_FILE, OP_BIN and
# WORKDIR point this script at fixtures. Nothing on a claw sets them.
#
set -euo pipefail

DRY_RUN=0

# The caller's environment decides nothing. A member could export a token of
# their own, and a write that used it would put the key somewhere else.
unset OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_ACCOUNT || true
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ETC_ROOT="/etc/commonclaw"
GATEKEEPER_ENV="${GATEKEEPER_ENV:-${ETC_ROOT}/email-gatekeeper.env}"
CRED_NAME="op-service-account"
CRED_FILE="${CRED_FILE:-${ETC_ROOT}/credentials/${CRED_NAME}.cred}"
ADMIN_LOG="${ETC_ROOT}/admin-log.md"
DROP_NAME="commonclaw-email-provider-key"
OP_BIN="${OP_BIN:-op}"
UNIT="email-gatekeeper.service"

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
ACTION="none"; KEY=""; DROP=""; VAULT=""; ITEM=""; FIELD=""; REFERENCE=""; NEWPID=""

# ---------------------------------------------------------------- the scrubber
#
# One function, applied to every line this script emits. A redaction placed per
# call site is a redaction somebody adds a call site past, and the failure paths
# are where a value most often escapes.
scrub() {
  local s="$1"
  [ -n "$KEY" ] && s="${s//"$KEY"/<redacted>}"
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
  printf '  "script": "install-email-provider-key",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "vault": "%s",\n' "$(json_esc "$VAULT")"
  printf '  "item": "%s",\n' "$(json_esc "$ITEM")"
  printf '  "reference": "%s",\n' "$(json_esc "$REFERENCE")"
  printf '  "drop_path": "%s",\n' "$(json_esc "$DROP")"
  printf '  "action": "%s",\n' "$(json_esc "$ACTION")"
  printf '  "service_pid": "%s",\n' "$(json_esc "$NEWPID")"
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
cleanup() { KEY=""; rm -rf -- "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { printf 'run this as root\n' >&2; exit 2; }

for t in "$OP_BIN" systemd-creds install stat; do
  command -v "$t" >/dev/null 2>&1 || refuse "this claw has no ${t}, which this door needs"
done

[ -r "$GATEKEEPER_ENV" ] \
  || refuse "no ${GATEKEEPER_ENV}: this claw carries no provider-key reference, so there is nothing to fill. Run the provisioning plane first."

REFERENCE="$(sed -n 's/^COMMONCLAW_EMAIL_PROVIDER_KEY=//p' "$GATEKEEPER_ENV" | tail -1)"
REFERENCE="${REFERENCE%\"}"; REFERENCE="${REFERENCE#\"}"
case "$REFERENCE" in
  op://*) : ;;
  "") refuse "${GATEKEEPER_ENV} names no COMMONCLAW_EMAIL_PROVIDER_KEY, so nothing on this claw would read what this door wrote" ;;
  *)  refuse "COMMONCLAW_EMAIL_PROVIDER_KEY in ${GATEKEEPER_ENV} is not an op:// reference. If it holds a literal key, that is a credential at rest inside the backed-up config root: rotate the key at the provider and remove the line." ;;
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
  say "It exists while you have a live login session. Reconnect, then drop the key and run this again."
  exit 2
fi

DROP_FS="$(stat -f -c '%T' "$DROP_DIR" 2>/dev/null || echo unknown)"
[ "$DROP_FS" = "tmpfs" ] \
  || refuse "${DROP_DIR} is on ${DROP_FS}, not tmpfs. Refusing: a key dropped there could reach the disk."
[ "$(stat -c '%u' "$DROP_DIR")" = "$CALLER_UID" ] \
  || refuse "${DROP_DIR} does not belong to the calling uid"

if [ ! -e "$DROP" ]; then
  say "no provider key at ${DROP}."
  say ""
  say "Drop it first, from the machine where the provider's console is open:"
  say ""
  say "  printf '%s' '<provider api key>' \\"
  say "    | ssh $(hostname) 'umask 077; cat > ${DROP}'"
  say ""
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
  || refuse "the drop file is mode ${FD_MODE}, readable beyond you. Drop it under umask 077 and mint a fresh key: this one was exposed."
case "$FD_SIZE" in ''|*[!0-9]*) refuse "cannot size the opened drop file" ;; esac
[ "$FD_SIZE" -gt 0 ] || refuse "the drop file is empty"
[ "$FD_SIZE" -le 4096 ] || refuse "the drop file is ${FD_SIZE} bytes, far larger than an API key. Refusing rather than guessing what it is."

say ""
say "=== install the mail provider key for $(hostname) ==="
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
  say "  would restart ${UNIT} so the running service holds the new key"
  say "  would destroy ${DROP} only after that"
  warn "dry run: the drop was not read, and nothing was written"
  finish
fi

# ---------------------------------------------------------------- the value

KEY="$(cat <&9)"
exec 9<&-

# A trailing newline from a shell redirect is stripped by the substitution. A
# value with any OTHER whitespace in it is not an API key.
[ -n "$KEY" ] || refuse "the drop file holds nothing once its trailing newline is removed"
case "$KEY" in
  *[[:space:]]*) refuse "the dropped value carries whitespace, so it is not an API key. Check what was piped in." ;;
esac
# A shape floor, not a format. Providers pick their own key shapes and this door
# outlives any one of them, so it refuses what is obviously not a key and
# accepts the rest.
[ "${#KEY}" -ge 16 ] \
  || refuse "the dropped value is ${#KEY} characters, too short to be a provider key. Nothing was written."
KEY_SHA="$(printf '%s' "$KEY" | sha256sum | cut -d' ' -f1)"
say "  offered key: ${#KEY} bytes, sha256 ${KEY_SHA:0:16}"

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
# STDIN IS CLOSED ON BOTH WRITES: the manager refuses a template when stdin is
# not a terminal, and over ssh this script's stdin is a socket. Redirecting from
# /dev/null makes stdin a regular file at EOF, which it accepts. That defect was
# found and fixed on the heartbeat door on 2026-09-02 and this door was written
# after it.
TEMPLATE="${WORKDIR}/item.json"
: > "$TEMPLATE"; chmod 0600 "$TEMPLATE"
printf '{"title":"%s","category":"API_CREDENTIAL","fields":[{"id":"%s","type":"CONCEALED","label":"%s","value":"%s"}]}\n' \
  "$ITEM" "$FIELD" "$FIELD" "$KEY" > "$TEMPLATE"

op_said() { tr '\n' ' ' < "${WORKDIR}/op.err" 2>/dev/null | cut -c1-300; }

# WHAT THE MANAGER SAID DECIDES WHAT THIS DOOR SAYS. The exit is CLASSIFIED and
# never asserted: a usage refusal and a permission refusal both exit non-zero and
# need opposite work, and a message that names one cause on every failure sends
# an operator to fix something that was never wrong.
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
# READ BACK THROUGH THE REFERENCE, which is the path the gatekeeper takes at
# every start. Reading the item back by name would prove the write and not the
# thing that depends on it: a reference naming a field this door did not fill
# resolves to nothing while the item looks perfect.
say ""
say "=== the gate: the reference the gatekeeper reads resolves to what went in ==="

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
if [ "$RB_SHA" = "$KEY_SHA" ]; then
  ok "the reference resolves to exactly what was dropped (sha256 ${RB_SHA:0:16})"
else
  bad "the reference resolves to sha256 ${RB_SHA:0:16}, not the ${KEY_SHA:0:16} that went in. Something else is in that field."
  warn "${DROP} was NOT destroyed -- you still hold the only copy"
  finish
fi

# ------------------------------------------------------- the running process
#
# A SERVICE HOLDS THE KEY IT STARTED WITH. Without this the vault is right, the
# reference resolves, every check above is green, and the gatekeeper keeps
# reaching nothing until somebody happens to restart it. That is the
# installs-right-does-not-run defect, and the proof that binds is a pid that
# moved.
say ""
say "=== the running process ==="
if ! systemctl list-unit-files "$UNIT" >/dev/null 2>&1; then
  warn "${UNIT} is not installed on this claw, so nothing needed restarting. Install the gatekeeper, then run this again"
elif systemctl is-enabled "$UNIT" 2>/dev/null | grep -q '^disabled$'; then
  warn "${UNIT} is deliberately disabled and was left off. The key is in the vault and the service will read it when somebody turns it on"
else
  OLDPID="$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)"
  systemctl restart "$UNIT" >/dev/null 2>&1 || true
  NEWPID="$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)"
  if [ -n "$NEWPID" ] && [ "$NEWPID" != "0" ] && [ "$NEWPID" != "$OLDPID" ]; then
    ok "${UNIT} restarted onto the new key: pid ${OLDPID:-none} became ${NEWPID}"
  else
    bad "${UNIT} did not come back with a new pid (was ${OLDPID:-none}, now ${NEWPID:-none}). The vault holds the key and the running service may not. journalctl -u ${UNIT} says why"
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

# ---------------------------------------------------------------- the record

# The event, never the value. This file is world-readable and its readers are
# the firm's own people.
if [ -f "$ADMIN_LOG" ]; then
  WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '| %s | %s | %s the mail provider key | %s |\n' "$WHEN" "$BY" "$ACTION" "$ITEM" >> "$ADMIN_LOG"
  ok "the event is in ${ADMIN_LOG}, and the value is not"
else
  warn "no ${ADMIN_LOG} on this claw, so the event was not recorded"
fi

say ""
say "The key is in this claw's own machine vault and nowhere else on this box."
say "Next, if this claw has no inbox yet:"
say "  email inbox create --username <name> --display-name \"<Display Name>\""
finish
