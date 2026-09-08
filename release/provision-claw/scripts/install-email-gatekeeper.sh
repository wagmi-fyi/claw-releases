#!/bin/bash
#
# install-email-gatekeeper.sh: stand the mail gatekeeper on this claw.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./install-email-gatekeeper.sh
#   sudo ./install-email-gatekeeper.sh --dry-run
#   sudo ./install-email-gatekeeper.sh --uninstall
#
# WHAT THE GATEKEEPER IS. One access point for a firm's mail. It routes what
# arrives to the sessions it concerns over the session bus, and carries what
# they write back out. It reads no mail for meaning, decides no recipient beyond
# a table, replies to nothing on its own, holds no secret on disk, and keeps no
# correspondence. Mail rests at the provider.
#
# WHERE THE PROGRAM COMES FROM. The payload, and nothing else. This script
# installs from a stage and refuses anything else by name, the way the wake
# rail's installer does.
#
# THE SERVICE USER IS IN claw-members, AND THAT IS A WIDENING WORTH SAYING OUT
# LOUD. The bus directory is group-owned by claw-members and group-writable, so
# a process that cannot join that group cannot put a message on the bus at all.
# Membership is therefore the mechanism, and its cost is that the gatekeeper's
# account can read every inbox on this claw. It is a service account with no
# shell and no login, and the law that rides with the bus is unchanged: no
# credential in a message body, ever.
#
# ADOPTION, NOT REVERSION (the Q62 doctrine). A re-run adopts what it finds. The
# conf and the routing table are kept as they are, a missing conf key is
# appended with its shipped default, an instance somebody deliberately disabled
# stays disabled, and a unit file this claw owns is converged with the change
# reported.
#
# NOT CONNECTED IS NOT A FAILURE. A claw with no provider key, or no inbox yet,
# is a claw nobody has wired one for. This script says so and exits 0. Phase 22
# failed a whole tenant apply on exactly that shape and the lesson is in its
# code.
#
# EXIT CODES. 0 the gatekeeper is installed and enabled. 1 something this script
# owns did not take. 2 usage.
set -uo pipefail

BIN_DIR="/opt/commonclaw/bin"
CONF="/etc/commonclaw/email-gatekeeper.conf"
ENVF="/etc/commonclaw/email-gatekeeper.env"
UNIT_DIR="/etc/systemd/system"
UNIT="email-gatekeeper.service"
SVC_USER="email-gate"
SVC_HOME="/srv/connections/email-gatekeeper"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${HERE}/../payload/email-gatekeeper"
TEMPLATE_DIR="${HERE}/../templates"

MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   MODE="dry-run"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help)   awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *)           printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

FAILED=0
NOTES=()
ok()   { printf '  ok    %s\n' "$1" >&2; NOTES+=("ok: $1"); }
warn() { printf '  note  %s\n' "$1" >&2; NOTES+=("note: $1"); }
bad()  { printf '  BAD   %s\n' "$1" >&2; NOTES+=("bad: $1"); FAILED=1; }
check(){ local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

[ "$(id -u)" = 0 ] || { printf 'this installs into /opt, /etc, /srv and systemd, so it needs root\n' >&2; exit 2; }

# ------------------------------------------------------------------ uninstall
if [ "$MODE" = uninstall ]; then
  systemctl disable --now "$UNIT" >/dev/null 2>&1
  systemctl daemon-reload
  ok "${UNIT} stopped and disabled"
  printf '{"mode":"uninstall","note":"the program, the conf, the routing table and the send log were left in place: the table is a ruling and the log is an audit trail, and removing either is its own decision"}\n'
  exit 0
fi

DRY=""; [ "$MODE" = dry-run ] && DRY="would "

# ------------------------------------------------------ the program + adapters
for f in email-gatekeeper email; do
  [ -r "${PAYLOAD_DIR}/${f}" ] || bad "no ${PAYLOAD_DIR}/${f}. Run this from an assembled stage"
done
[ -d "${PAYLOAD_DIR}/email-gatekeeper-adapters" ] \
  || bad "no ${PAYLOAD_DIR}/email-gatekeeper-adapters. The service reaches no provider without one"
for t in email-gatekeeper.service email-gatekeeper.conf email-gatekeeper-routes.json; do
  [ -r "${TEMPLATE_DIR}/${t}" ] || bad "no ${TEMPLATE_DIR}/${t}. This script owns the claw's copy of it"
done
[ "$FAILED" = 0 ] || { printf '{"ok":false,"stage":"payload"}\n'; exit 1; }

# WHAT THE SERVICE RUNS RIGHT NOW, digested before the copy and again after it.
# An instance holds the program it started with, so replacing the file underneath
# a running unit changes nothing about the process: it installs right, verifies
# right, and does not run. The digest covers the program, the command and every
# adapter, because the service loads an adapter at delivery and a corrected
# adapter is as invisible as a corrected core.
svc_digest() {
  {
    [ -r "${BIN_DIR}/email-gatekeeper" ] && sha256sum "${BIN_DIR}/email-gatekeeper"
    [ -r "${BIN_DIR}/email" ] && sha256sum "${BIN_DIR}/email"
    [ -d "${BIN_DIR}/email-gatekeeper-adapters" ] \
      && find "${BIN_DIR}/email-gatekeeper-adapters" -type f -print0 \
         | sort -z | xargs -0 -r sha256sum
  } 2>/dev/null | sha256sum | cut -c1-16
}
SVC_BEFORE=""; SVC_AFTER=""

if [ "$MODE" != dry-run ]; then
  SVC_BEFORE="$(svc_digest)"
  install -d -m 0755 -o root -g root "$BIN_DIR" "${BIN_DIR}/email-gatekeeper-adapters" /etc/commonclaw
  install -m 0755 -o root -g root "${PAYLOAD_DIR}/email-gatekeeper" "${BIN_DIR}/email-gatekeeper"
  install -m 0755 -o root -g root "${PAYLOAD_DIR}/email" "${BIN_DIR}/email"
  for f in "${PAYLOAD_DIR}"/email-gatekeeper-adapters/*; do
    install -m 0755 -o root -g root "$f" "${BIN_DIR}/email-gatekeeper-adapters/$(basename "$f")"
  done
  SVC_AFTER="$(svc_digest)"
  check "${BIN_DIR}/email-gatekeeper is 0755 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '${BIN_DIR}/email-gatekeeper')\" = '755 root:root' ]"
  check "${BIN_DIR}/email is 0755 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '${BIN_DIR}/email')\" = '755 root:root' ]"
else
  ok "${DRY}install ${BIN_DIR}/email-gatekeeper, ${BIN_DIR}/email and the adapters"
fi

# ------------------------------------------------------- the account + its home
#
# A system account with no shell and no password. It is in claw-members because
# writing to the group-owned bus needs it, and for no other reason.
if [ "$MODE" = dry-run ]; then
  ok "${DRY}create the ${SVC_USER} system account and ${SVC_HOME}"
else
  if id "$SVC_USER" >/dev/null 2>&1; then
    ok "the ${SVC_USER} account already exists and was adopted"
  else
    useradd --system --home-dir "$SVC_HOME" --no-create-home \
            --shell /usr/sbin/nologin "$SVC_USER" >/dev/null 2>&1 \
      && ok "the ${SVC_USER} system account was created" \
      || bad "the ${SVC_USER} system account could not be created"
  fi
  if getent group claw-members >/dev/null 2>&1; then
    usermod -aG claw-members "$SVC_USER" >/dev/null 2>&1 \
      && ok "${SVC_USER} is in claw-members, which is what lets it write a bus message" \
      || bad "${SVC_USER} could not be put in claw-members, so it cannot put mail on the bus"
  else
    bad "there is no claw-members group on this claw, so the gatekeeper cannot reach the bus"
  fi
  install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME" \
          "${SVC_HOME}/state" "${SVC_HOME}/log"
  check "${SVC_HOME} is 0750 ${SVC_USER}" \
    bash -c "[ \"\$(stat -c '%a %U' '${SVC_HOME}')\" = '750 ${SVC_USER}' ]"
fi

# ------------------------------------------------------------------- the conf
#
# ADOPTED, NEVER OVERWRITTEN, and a missing key is appended with its shipped
# default and a comment naming the release. Seeded-once alone meant a setting
# added by a later release never reached a claw that already had the file.
conf_release_name() {
  local f="${HERE}/../../release.json"
  [ -r "$f" ] || { printf ''; return 0; }
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
}

conf_add_missing_keys() {
  local template="$1" conf="$2" line key added=0 rel
  rel="$(conf_release_name)"
  while IFS= read -r line; do
    case "$line" in
      [A-Z_]*=*) key="${line%%=*}" ;;
      *) continue ;;
    esac
    grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$conf" && continue
    if [ "$MODE" = dry-run ]; then
      ok "${DRY}append ${key} to ${conf} with its shipped default"
      added=$((added + 1))
      continue
    fi
    {
      printf '\n'
      if [ -n "$rel" ]; then
        printf '# %s arrived in release %s. This file was seeded before it existed,\n' "$key" "$rel"
      else
        printf '# %s arrived in a release later than the one that seeded this file,\n' "$key"
      fi
      printf '# so the shipped default is appended here. What it does is written in\n'
      printf '# the shipped template beside this script.\n'
      printf '%s\n' "$line"
    } >> "$conf"
    ok "${key} was missing from ${conf} and its shipped default was appended"
    added=$((added + 1))
  done < "$template"
  [ "$added" -gt 0 ] || ok "${conf} carries every key this release ships"
}

if [ -e "$CONF" ]; then
  ok "conf at ${CONF} already exists and its existing keys were left exactly as they are"
  conf_add_missing_keys "${TEMPLATE_DIR}/email-gatekeeper.conf" "$CONF"
elif [ "$MODE" != dry-run ]; then
  install -m 0644 -o root -g root "${TEMPLATE_DIR}/email-gatekeeper.conf" "$CONF"
  ok "conf seeded at ${CONF}"
else
  ok "${DRY}seed ${CONF}"
fi

if [ "$MODE" != dry-run ]; then
  check "the conf carries no literal provider key" \
    bash -c "! grep -qiE '^[[:space:]]*(PROVIDER_KEY|API_KEY|EMAIL_PROVIDER_KEY)[[:space:]]*=' '$CONF'"
fi

# --------------------------------------------------------- the key's reference
#
# A REFERENCE, NEVER A VALUE, composed from the vault and hostname the calling
# run passes in `EMAIL_GATEKEEPER_VAULT` and `EMAIL_GATEKEEPER_HOSTNAME`, and
# from this box's own hostname when nobody passes them. Phase 22 composes the
# webhook reference the same way, inside the run where both are in scope. Seeding
# it is what makes install-email-provider-key.sh able to work out where to write,
# because that door parses the vault and the item out of this line rather than
# taking them as arguments.
if [ "$MODE" = dry-run ]; then
  ok "${DRY}seed ${ENVF} with this claw's provider-key reference"
elif [ -e "$ENVF" ]; then
  ok "${ENVF} already exists and was left exactly as it is"
else
  # THE VAULT COMES FROM THE RUN THAT CALLS THIS. `provision.conf` does not
  # carry a VAULT key and never has. VAULT is a variable inside
  # `provision-claw.sh`, declared there and defaulted once the arguments are
  # parsed to `{hostname}-machine`, and the conf's hostname key is BOX_HOSTNAME
  # rather than TARGET_HOSTNAME. Reading that file for either name found nothing
  # on every claw, this file was seeded on none of them, and phase 25's check on
  # it could not pass anywhere.
  #
  # Phase 25 passes both values. A hand-run passes neither and falls back to the
  # same default the run uses, so an operator's door and the release compose one
  # reference.
  VAULT="${EMAIL_GATEKEEPER_VAULT:-}"
  HOSTN="${EMAIL_GATEKEEPER_HOSTNAME:-$(hostname -s)}"
  [ -n "$VAULT" ] || VAULT="${HOSTN}-machine"
  if [ -z "$HOSTN" ]; then
    # THIS GUARDS A NAMELESS REFERENCE, and it is the only state left that stops
    # the seeding. With no hostname the item name is `commonclaw-email-provider-`
    # and the default vault is `-machine`, so the line resolves to nothing while
    # reading like a wired claw.
    warn "this claw reports no short hostname, so ${ENVF} was not seeded. Pass EMAIL_GATEKEEPER_HOSTNAME, or give the box a hostname, then run this again"
  else
    {
      printf '# Manager references, never values. Resolved at start by the service.\n'
      printf '# Item names follow the naming table in reference/claw-conventions.md.\n'
      printf '#\n'
      printf '# One provider key per claw, never one for the fleet. A shared key means a\n'
      printf '# leak from any claw sends as every claw.\n'
      printf 'COMMONCLAW_EMAIL_PROVIDER_KEY=op://%s/commonclaw-email-provider-%s/credential\n' \
        "$VAULT" "$HOSTN"
    } > "$ENVF"
    chmod 0644 "$ENVF"; chown root:root "$ENVF"
    ok "${ENVF} seeded with this claw's reference"
  fi
fi
if [ "$MODE" != dry-run ] && [ -e "$ENVF" ]; then
  check "${ENVF} holds a reference, not a value" \
    bash -c "grep -q '^COMMONCLAW_EMAIL_PROVIDER_KEY=op://' '$ENVF'"
fi

# ------------------------------------------------------------ the routing table
#
# SEEDED ONCE AND NEVER REWRITTEN. It carries this firm's own identity and its
# own routing decisions. A release that rewrote it would take a firm's address
# off its own claw.
ROUTES="${SVC_HOME}/state/routes.json"
if [ "$MODE" = dry-run ]; then
  ok "${DRY}seed ${ROUTES} with an empty self and the default handle"
elif [ -e "$ROUTES" ]; then
  ok "${ROUTES} already exists and was left exactly as it is"
else
  install -m 0640 -o "$SVC_USER" -g "$SVC_USER" \
          "${TEMPLATE_DIR}/email-gatekeeper-routes.json" "$ROUTES"
  ok "${ROUTES} seeded with an empty self"
fi

# ---------------------------------------------------------------------- the unit
if [ "$MODE" = dry-run ]; then
  ok "${DRY}install ${UNIT_DIR}/${UNIT}"
else
  if [ -e "${UNIT_DIR}/${UNIT}" ] && ! cmp -s "${TEMPLATE_DIR}/${UNIT}" "${UNIT_DIR}/${UNIT}"; then
    warn "${UNIT_DIR}/${UNIT} differed from this release and was converged"
  fi
  install -m 0644 -o root -g root "${TEMPLATE_DIR}/${UNIT}" "${UNIT_DIR}/${UNIT}"
  systemctl daemon-reload
fi

# ------------------------------------------------------------------ enable it
STATE="unknown"; RESTARTS=""; WAS_ACTIVE=""
if [ "$MODE" = dry-run ]; then
  ok "${DRY}enable and start ${UNIT}"
elif systemctl is-enabled "$UNIT" 2>/dev/null | grep -q '^disabled$'; then
  warn "${UNIT} is deliberately disabled and was left off"
else
  WAS_ACTIVE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  systemctl enable --now "$UNIT" >/dev/null 2>&1
  if [ "$SVC_BEFORE" != "$SVC_AFTER" ] && [ "$WAS_ACTIVE" = active ]; then
    systemctl restart "$UNIT" >/dev/null 2>&1
    warn "${UNIT} was running the gatekeeper at ${SVC_BEFORE} and this run installed ${SVC_AFTER}, so it was restarted onto the new bytes"
  fi
  check "${UNIT} is enabled" \
    bash -c "systemctl is-enabled '$UNIT' 2>/dev/null | grep -qx enabled"
  STATE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  RESTARTS="$(systemctl show -p NRestarts --value "$UNIT" 2>/dev/null || true)"
fi

# --------------------------------------------------------------- the health line
#
# WHAT THIS READS IS INSTALLED AND ENABLED. Connected is reported beside it as a
# note and never as a failure, for phase 22's reason: a claw whose firm has not
# wired a provider key yet is the ordinary state of a fresh claw, and a rail that
# failed the apply for it would stop the release eleven lines above the sentence
# that says how to wire one.
CONNECTED="unknown"; WHY=""; INBOX=""
if [ "$MODE" != dry-run ] && [ -x "${BIN_DIR}/email-gatekeeper" ]; then
  CHECK_OUT="$("${BIN_DIR}/email-gatekeeper" --check 2>/dev/null)" || true
  if command -v jq >/dev/null 2>&1 && [ -n "$CHECK_OUT" ]; then
    CONNECTED="$(printf '%s' "$CHECK_OUT" | jq -r '.probe.ready // false')"
    WHY="$(printf '%s' "$CHECK_OUT" | jq -r '.probe.reason // ""')"
    INBOX="$(printf '%s' "$CHECK_OUT" | jq -r '.inbox_id // ""')"
  fi
  case "$CONNECTED" in
    true) ok "the gatekeeper reaches its provider" ;;
    *)    warn "the gatekeeper does not reach a provider yet (${WHY:-no reason given}). Wire the key with install-email-provider-key.sh. This is not a failure" ;;
  esac
  if [ -z "$INBOX" ]; then
    warn "this claw has no inbox yet. After the key is wired, an operator makes one once with: email inbox create --username <name> --display-name \"<Name>\""
  else
    ok "this claw's inbox is ${INBOX}"
  fi
  case "$STATE" in
    active)     warn "${UNIT} is running (restarts: ${RESTARTS:-0})" ;;
    activating) warn "${UNIT} is in activating with ${RESTARTS:-0} restart(s), so it is coming up or looping. journalctl -u ${UNIT} says which" ;;
    *)          warn "${UNIT} is enabled and reads ${STATE:-unknown}" ;;
  esac
fi

printf '{"ok":%s,"mode":"%s","unit":"%s","state":"%s","connected":"%s","inbox_id":"%s","program":"%s","conf":"%s","routes":"%s"}\n' \
  "$([ "$FAILED" = 0 ] && echo true || echo false)" "$MODE" "$UNIT" "$STATE" \
  "$CONNECTED" "$INBOX" "${BIN_DIR}/email-gatekeeper" "$CONF" "$ROUTES"
exit "$FAILED"
