#!/bin/bash
#
# install-bus-nudge.sh — stand the wake rail on this claw.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./install-bus-nudge.sh <account> [<account> ...]
#   sudo ./install-bus-nudge.sh --dry-run <account>
#   sudo ./install-bus-nudge.sh --uninstall <account> [...]
#
# WHERE THE PROGRAM COMES FROM. The rail's source is the orchestrate skill, and
# the assembler vendors it into the payload when a release is cut. So a stage
# carries it and a bare checkout of the source repository does not. This script
# installs from the stage and refuses anything else by name.
#
# WHAT THE RAIL IS. The session bus is files. A delegate writes its report into
# an inbox and announces it to nobody, so the reader learns about it when it
# next happens to look. `bus-nudge` watches the buses on this machine and tells
# a live session, in one fixed sentence and nothing else, that it has unread
# mail. The session then reads the bus. The nudge carries no instruction, so a
# wrong or stale one wastes a turn and can never inject work.
#
# WHY IT IS PER ACCOUNT AND NOT ONE MACHINE-WIDE DAEMON. Everything delivery
# needs — the session records, the socket, the auth key — is written by the
# session under its owner's account, mode 0600. A root daemon reaching into
# those on somebody's behalf is a different act with a different consent story,
# and the ruling this rail runs under is same-user delivery. So one templated
# instance per account, each running as that account.
#
# THE OPT-IN THIS INSTALLS, AND WHAT IT COSTS. A session holds a message from a
# sender that cannot attest its permission mode, and waits for a human to
# approve it. A headless rail cannot answer that prompt. So this installer sets
# `crossSessionInbound` to `accept` in the machine's managed settings, which is
# the ruled shape: every session on the claw opts in. What that permits is a
# local process holding a session's own 0600 auth key writing a user turn into
# that session. It does not open the claw to anything off it, and it does not
# cross accounts: the key file permissions do that, not this setting.
#
# ADOPTION, NOT REVERSION (the Q62 doctrine). A re-run adopts what it finds.
# An existing conf is kept as it is. An instance somebody deliberately disabled
# stays disabled and is reported. A unit file this claw owns is converged and
# the change is reported. Nothing here overwrites a decision a person made.
#
# EXIT CODES. 0 the rail is standing. 1 something this script owns did not
# take. 2 usage.
set -uo pipefail

BIN_DIR="/opt/commonclaw/bin"
DOC_DIR="/opt/commonclaw/doc"
CONF="/etc/commonclaw/bus-nudge.conf"
UNIT_DIR="/etc/systemd/system"
MANAGED_SETTINGS="/etc/claude-code/managed-settings.json"
ORCHESTRATE_CONF="/etc/orchestrate.conf"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${HERE}/../payload"
TEMPLATE_DIR="${HERE}/../templates"

MODE="install"
ACCOUNTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   MODE="dry-run"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help)   awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    -*)          printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    *)           ACCOUNTS+=("$1"); shift ;;
  esac
done
[ "${#ACCOUNTS[@]}" -gt 0 ] || { printf 'name at least one account\n' >&2; exit 2; }

FAILED=0
NOTES=()
ok()   { printf '  ok    %s\n' "$1" >&2; NOTES+=("ok: $1"); }
warn() { printf '  note  %s\n' "$1" >&2; NOTES+=("note: $1"); }
bad()  { printf '  BAD   %s\n' "$1" >&2; NOTES+=("bad: $1"); FAILED=1; }
check(){ local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

[ "$(id -u)" = 0 ] || { printf 'this installs into /opt, /etc and systemd, so it needs root\n' >&2; exit 2; }

for a in "${ACCOUNTS[@]}"; do
  id "$a" >/dev/null 2>&1 || { printf 'no such account: %s\n' "$a" >&2; exit 2; }
done

# ------------------------------------------------------------------ uninstall
if [ "$MODE" = uninstall ]; then
  for a in "${ACCOUNTS[@]}"; do
    systemctl disable --now "bus-nudge@${a}.timer" >/dev/null 2>&1
    systemctl disable --now "bus-nudge@${a}.service" >/dev/null 2>&1
    ok "bus-nudge@${a} stopped and disabled"
  done
  systemctl daemon-reload
  printf '{"mode":"uninstall","accounts":["%s"],"note":"the program, the conf and the managed-settings opt-in were left in place: each is shared and removing one is its own decision"}\n' \
    "$(IFS='","'; echo "${ACCOUNTS[*]}")"
  exit 0
fi

DRY=""; [ "$MODE" = dry-run ] && DRY="would "
pair=""; src=""; dst=""

# ------------------------------------------------------ the program + adapters
for f in bus-nudge; do
  [ -r "${PAYLOAD_DIR}/${f}" ] || { bad "no ${PAYLOAD_DIR}/${f} — the assembler vendors it from the orchestrate skill, so run this from an assembled stage"; }
done
[ -d "${PAYLOAD_DIR}/bus-nudge-adapters" ] || bad "no ${PAYLOAD_DIR}/bus-nudge-adapters — the core refuses to deliver without one, and the assembler vendors it beside the program"
[ -r "${TEMPLATE_DIR}/wake-rail.md" ] || bad "no ${TEMPLATE_DIR}/wake-rail.md — this script owns the claw's copy of it"
[ -r "${PAYLOAD_DIR}/doc/operator-runbook.md" ] || bad "no ${PAYLOAD_DIR}/doc/operator-runbook.md — this script owns the claw's copy of it"
[ "$FAILED" = 0 ] || { printf '{"ok":false,"stage":"payload"}\n'; exit 1; }

# WHAT THE RAIL RUNS RIGHT NOW, digested before the copy and again after it.
# An instance holds the program it started with. Replacing the file underneath a
# running unit changes nothing about the process, so a fix that ships in the
# payload installs, verifies, and does not run. Measured on staging 2026-09-02:
# one instance held its pid across two applies while the program moved twice.
# The digest covers the program and every adapter, because the program loads an
# adapter at delivery and a corrected adapter is as invisible as a corrected
# core.
rail_digest() {
  {
    [ -r "${BIN_DIR}/bus-nudge" ] && sha256sum "${BIN_DIR}/bus-nudge"
    [ -d "${BIN_DIR}/bus-nudge-adapters" ] && find "${BIN_DIR}/bus-nudge-adapters" -type f -print0 \
      | sort -z | xargs -0 -r sha256sum
  } 2>/dev/null | sha256sum | cut -c1-16
}
RAIL_BEFORE=""; RAIL_AFTER=""

if [ "$MODE" != dry-run ]; then
  RAIL_BEFORE="$(rail_digest)"
  install -d -m 0755 -o root -g root "$BIN_DIR" "$DOC_DIR" "${BIN_DIR}/bus-nudge-adapters" /etc/commonclaw
  install -m 0755 -o root -g root "${PAYLOAD_DIR}/bus-nudge" "${BIN_DIR}/bus-nudge"
  for f in "${PAYLOAD_DIR}"/bus-nudge-adapters/*; do
    install -m 0755 -o root -g root "$f" "${BIN_DIR}/bus-nudge-adapters/$(basename "$f")"
  done
  RAIL_AFTER="$(rail_digest)"
  check "${BIN_DIR}/bus-nudge is 0755 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '${BIN_DIR}/bus-nudge')\" = '755 root:root' ]"
  check "the delivered sentence carries no interpolation but the bus directory" \
    bash -c "${BIN_DIR}/bus-nudge --law >/dev/null"
else
  ok "${DRY}install ${BIN_DIR}/bus-nudge and its adapters"
fi

# ------------------------------------------------------------- the claw's docs
#
# TWO FILES, ONE PLACE. `wake-rail.md` says how this rail reaches a session and
# is the member's reading. `operator-runbook.md` is the operator's, and it rides
# in the payload rather than in templates because nothing renders it.
#
# WRITTEN TO AN END STATE AND REPORTED BY DIGEST, which is the law the notifier's
# two config files already follow. They carry the release's own words rather than
# state the claw accumulates, so a re-run rewrites them and a corrected sentence
# reaches every claw. A copy whose bytes match is adopted and nothing is written.
# One that differs is replaced and the run names the digest it found, because the
# copy on the box may be one somebody edited, and a line in this output is the
# only way anybody learns it is gone.
for pair in "${TEMPLATE_DIR}/wake-rail.md:wake-rail.md" \
            "${PAYLOAD_DIR}/doc/operator-runbook.md:operator-runbook.md"; do
  src="${pair%:*}"; dst="${DOC_DIR}/${pair##*:}"
  if [ "$MODE" = dry-run ]; then ok "${DRY}install ${dst}"; continue; fi
  if [ ! -e "$dst" ]; then
    install -m 0644 -o root -g root "$src" "$dst"
    ok "${dst} installed"
  elif cmp -s "$src" "$dst"; then
    ok "${dst} already matches this release and was adopted unchanged"
  else
    warn "${dst} differed from this release and was REPLACED. The copy this run found was sha256 $(sha256sum "$dst" | cut -c1-16); if it was newer than the release, it is gone"
    install -m 0644 -o root -g root "$src" "$dst"
  fi
  check "${dst} is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$dst')\" = '644 root:root' ]"
done

# ------------------------------------------------------------------- the conf
#
# ADOPTED, NEVER OVERWRITTEN. A conf on the claw is somebody's ruling about this
# machine. Seeding an absent one is help; replacing a present one is reverting
# a decision nobody asked to revert.
#
# A MISSING KEY IS APPENDED WITH ITS DEFAULT, and no existing key is touched.
# Seeded-once meant a setting added by a later release never reached a claw that
# already had the file. `IDLE_POLL_SECS` shipped in 1.4.1 and no claw provisioned
# before it could see the key existed, let alone tune it. Nothing broke, because
# the program carries the same default, and that is the whole cost: a firm could
# not tune a setting by editing a file the run would not touch, and nothing told
# them it was there.
#
# APPENDED, NEVER REWRITTEN. The key arrives at the end of the file with a
# comment naming the release that added it, so somebody reading their own conf
# can see which lines are theirs and which arrived on an update. A key already
# present keeps its value whatever it is, including one that differs from the
# template, because that is somebody's ruling.
#
# THE KEY LIST COMES FROM THE TEMPLATE, so a key added there in a later release
# reaches an existing conf without this script being edited again.
# THE STAGE'S OWN release.json, and nothing else. A stage carries the release
# being applied, which is the release that added the key. The claw's
# /etc/commonclaw/release.json names the version the box still carries, which
# during an apply is the OLD one, so reading it would write the wrong release
# into somebody's conf. Where there is no stage, the comment says "a later
# release" and names nothing.
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

if [ ! -r "${TEMPLATE_DIR}/bus-nudge.conf" ]; then
  bad "no ${TEMPLATE_DIR}/bus-nudge.conf — this script owns the claw's conf and cannot seed or complete one without it"
elif [ -e "$CONF" ]; then
  ok "conf at ${CONF} already exists and its existing keys were left exactly as they are"
  conf_add_missing_keys "${TEMPLATE_DIR}/bus-nudge.conf" "$CONF"
elif [ "$MODE" != dry-run ]; then
  install -m 0644 -o root -g root "${TEMPLATE_DIR}/bus-nudge.conf" "$CONF"
  ok "conf seeded at ${CONF}"
else
  ok "${DRY}seed ${CONF}"
fi

# --------------------------------------------------------- the machine opt-in
#
# MERGED, NEVER OVERWRITTEN, exactly as the session-bus phase treats this file.
# One key is ours; everything else in it is somebody else's decision.
if ! command -v jq >/dev/null 2>&1; then
  bad "jq is absent, so the managed-settings opt-in was not written and no session will accept a nudge"
elif [ "$MODE" != dry-run ]; then
  install -d -m 0755 -o root -g root "$(dirname "$MANAGED_SETTINGS")"
  existing='{}'; [ -s "$MANAGED_SETTINGS" ] && existing="$(cat "$MANAGED_SETTINGS")"
  if merged="$(printf '%s' "$existing" | jq '.crossSessionInbound = "accept"' 2>/dev/null)"; then
    printf '%s\n' "$merged" > "$MANAGED_SETTINGS"
    chmod 0644 "$MANAGED_SETTINGS"; chown root:root "$MANAGED_SETTINGS"
    check "${MANAGED_SETTINGS} sets crossSessionInbound to accept" \
      bash -c "[ \"\$(jq -r '.crossSessionInbound // empty' '$MANAGED_SETTINGS')\" = 'accept' ]"
    check "${MANAGED_SETTINGS} is 0644 root:root" \
      bash -c "[ \"\$(stat -c '%a %U:%G' '$MANAGED_SETTINGS')\" = '644 root:root' ]"
  else
    bad "${MANAGED_SETTINGS} is not readable as JSON, so the opt-in was NOT written. Every nudge will be held. Fix the file by hand."
  fi
else
  ok "${DRY}set crossSessionInbound to accept in ${MANAGED_SETTINGS}"
fi

# ----------------------------------------------------- where the shared bus is
#
# The rail does not know where a machine keeps the bus every account joins. It
# asks the orchestrate settings seam, whose machine layer is /etc/orchestrate.conf,
# and here the answer is the one the session-bus phase already wrote into the
# managed settings. Recording it there is what lets a program installed outside
# every skill tree reach the same answer the skill's own scripts reach.
#
# SEEDED INTO AN ABSENCE, NEVER REWRITTEN, which is the law the updater mode and
# the seat roster follow. Once the file exists it is somebody's ruling about this
# machine.
SHARED_BUS=""
if command -v jq >/dev/null 2>&1 && [ -s "$MANAGED_SETTINGS" ]; then
  SHARED_BUS="$(jq -r '.env.SESSION_BUS_DIR // empty' "$MANAGED_SETTINGS" 2>/dev/null || true)"
fi
if [ -z "$SHARED_BUS" ]; then
  warn "${MANAGED_SETTINGS} names no shared bus, so this machine has none recorded and the rail watches each account's own bus alone"
elif [ "$MODE" = dry-run ]; then
  ok "${DRY}record ${SHARED_BUS} at ${ORCHESTRATE_CONF}"
elif [ -e "$ORCHESTRATE_CONF" ]; then
  if grep -qE '^[[:space:]]*ORCHESTRATE_SHARED_BUS[[:space:]]*=' "$ORCHESTRATE_CONF"; then
    ok "${ORCHESTRATE_CONF} already names the shared bus and was left exactly as it is"
  else
    warn "${ORCHESTRATE_CONF} exists and does not name the shared bus. It was left alone. Add ORCHESTRATE_SHARED_BUS=\"${SHARED_BUS}\" by hand, or the rail watches each account's own bus alone"
  fi
else
  {
    printf '# The machine layer of the orchestrate settings seam. A setting here is\n'
    printf '# read before the skill ships its own, and after the environment.\n'
    printf 'ORCHESTRATE_SHARED_BUS="%s"\n' "$SHARED_BUS"
  } > "$ORCHESTRATE_CONF"
  chmod 0644 "$ORCHESTRATE_CONF"; chown root:root "$ORCHESTRATE_CONF"
  ok "shared bus recorded at ${ORCHESTRATE_CONF} as ${SHARED_BUS}"
fi

# A rail watching one bus fewer than the machine has reads exactly like a quiet
# bus, so the resolution is driven rather than assumed.
if [ "$MODE" != dry-run ] && command -v jq >/dev/null 2>&1; then
  check "the installed rail resolves this machine's shared bus" \
    bash -c "[ -n \"\$('${BIN_DIR}/bus-nudge' --check 2>/dev/null | jq -r '.shared_bus // empty')\" ]"
fi

# -------------------------------------------------------------- the two units
for u in bus-nudge@.service bus-nudge@.timer; do
  [ -r "${TEMPLATE_DIR}/${u}" ] || { bad "no ${TEMPLATE_DIR}/${u}"; continue; }
  if [ "$MODE" = dry-run ]; then ok "${DRY}install ${UNIT_DIR}/${u}"; continue; fi
  if [ -e "${UNIT_DIR}/${u}" ] && ! cmp -s "${TEMPLATE_DIR}/${u}" "${UNIT_DIR}/${u}"; then
    warn "${UNIT_DIR}/${u} differed from this release and was converged"
  fi
  install -m 0644 -o root -g root "${TEMPLATE_DIR}/${u}" "${UNIT_DIR}/${u}"
done
[ "$MODE" = dry-run ] || systemctl daemon-reload

# ------------------------------------------------------- one instance per head
STARTED=()
state=""; restarts=""; was_active=""
for a in "${ACCOUNTS[@]}"; do
  if [ "$MODE" = dry-run ]; then ok "${DRY}enable and start bus-nudge@${a}"; continue; fi

  # A person who turned this off turned it off. A re-run that re-enabled it
  # would make the switch a suggestion.
  if systemctl is-enabled "bus-nudge@${a}.service" 2>/dev/null | grep -q '^disabled$'; then
    warn "bus-nudge@${a}.service is deliberately disabled and was left off"
    continue
  fi
  # AN INSTANCE ALREADY RUNNING KEEPS THE PROGRAM IT STARTED WITH, and
  # `enable --now` leaves a running unit alone. So the state is read before the
  # enable, and an instance that was already up is restarted onto the new bytes
  # when the digest above moved. An instance that was down is started by the
  # enable, on the new bytes already, and is never restarted a second time.
  was_active="$(systemctl is-active "bus-nudge@${a}.service" 2>/dev/null || true)"
  systemctl enable --now "bus-nudge@${a}.service" >/dev/null 2>&1
  systemctl enable --now "bus-nudge@${a}.timer"   >/dev/null 2>&1
  if [ "$RAIL_BEFORE" != "$RAIL_AFTER" ] && [ "$was_active" = active ]; then
    systemctl restart "bus-nudge@${a}.service" >/dev/null 2>&1
    warn "bus-nudge@${a}.service was running the rail at ${RAIL_BEFORE} and this run installed ${RAIL_AFTER}, so it was restarted onto the new bytes"
  fi

  # WHAT THIS COUNTS IS INSTALLED AND ENABLED, NEVER RUNNING.
  #
  # It counted `is-active` and that failed a whole release apply on 2026-09-02,
  # for an account whose owner was simply not signed in at that moment. The rail
  # has nobody to nudge then, which is the ordinary state of a claw with more
  # than one person on it and is not a fault this installer can fix. Enablement
  # is what this script owns: the unit is laid, it is turned on, and it comes up
  # with the box. Whether an instance is running right now is reported beside it
  # as a note, so a person reading the output still learns it.
  check "bus-nudge@${a}.service is enabled" \
    bash -c "systemctl is-enabled 'bus-nudge@${a}.service' 2>/dev/null | grep -qx enabled"
  check "bus-nudge@${a}.timer is enabled" \
    bash -c "systemctl is-enabled 'bus-nudge@${a}.timer' 2>/dev/null | grep -qx enabled"
  state="$(systemctl is-active "bus-nudge@${a}.service" 2>/dev/null || true)"
  restarts="$(systemctl show -p NRestarts --value "bus-nudge@${a}.service" 2>/dev/null || true)"
  case "$state" in
    active)     warn "bus-nudge@${a}.service is running (restarts: ${restarts:-0})" ;;
    activating) warn "bus-nudge@${a}.service is in activating with ${restarts:-0} restart(s), so it is coming up or looping. journalctl -u bus-nudge@${a}.service says which" ;;
    *)          warn "bus-nudge@${a}.service is enabled and reads ${state:-unknown}. An account with nobody signed in is the ordinary reason and it needs nothing done to it" ;;
  esac
  STARTED+=("$a")
done

STARTED_JSON="[]"
[ "${#STARTED[@]}" -gt 0 ] && STARTED_JSON="[\"$(IFS='","'; echo "${STARTED[*]}")\"]"
printf '{"ok":%s,"mode":"%s","accounts":["%s"],"started":%s,"program":"%s","conf":"%s","opt_in":"%s"}\n' \
  "$([ "$FAILED" = 0 ] && echo true || echo false)" "$MODE" \
  "$(IFS='","'; echo "${ACCOUNTS[*]}")" \
  "$STARTED_JSON" \
  "${BIN_DIR}/bus-nudge" "$CONF" "$MANAGED_SETTINGS"
exit "$FAILED"
