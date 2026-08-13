#!/bin/bash
#
# set-update-mode.sh — the firm decides how this claw takes releases.
#
# GRANTED SCRIPT. A claw-admin runs it through the member plane. It is root-owned
# and unwritable by its caller, it validates its own arguments, and it is
# idempotent, because the sudo grant carries no validation of its own.
#
#   sudo set-update-mode.sh --mode auto
#   sudo set-update-mode.sh --mode manual
#   sudo set-update-mode.sh --show
#
# WHAT THE TWO MODES MEAN.
#   auto    this claw takes validated releases on its own, in its quiet window.
#   manual  nothing lands unless somebody here asks for it. The claw still checks,
#           and still records what it is declining, so a firm can see what it is
#           holding off without asking the operator.
#
# MANUAL DOES NOT DISABLE THE TIMER, and that is deliberate. Provisioning installs
# units on every run, so a mode expressed as unit state is one a later release can
# flip back to auto with nothing telling the firm. The file is the one source of
# truth, and the updater reads it and exits as a no-op. `reference/release-rail.md`
# carries the reasoning.
#
# IT WRITES A MEMBER-PLANE ROW, because a decision changing is itself an act.
#
# The first draft of this door did not, on the argument that it changes a decision
# rather than the machine. That argument does not survive the history question:
# the mode file records the PRESENT and nothing records the path to it, so a firm
# asking who put this claw on manual in June, and what it was before, would have
# no durable answer anywhere. Printing it to the caller's terminal is not a
# record. One appended row carries who, when, was and became, forever, in the file
# whose whole purpose is what this firm's own admins did to its own claw.
#
set -euo pipefail

UPDATER_CONF=/etc/commonclaw/updater.conf
ADMIN_LOG=/etc/commonclaw/admin-log.md

MODE=""; SHOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --show) SHOW=1; shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

die() { printf 'set-update-mode: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this through the member plane with sudo"

# The caller behind sudo, never root. A record of who decided is the point, and
# it is the same rule the member-plane log follows.
WHO="${SUDO_USER:-unknown}"

[ -r "$UPDATER_CONF" ] \
  || die "no ${UPDATER_CONF} on this claw. Provisioning seeds it, so its absence means it was removed, and this door will not write its own"

# The act needs somewhere to be recorded before it happens. Same stance the other
# doors take: provisioning seeds this log, so its absence means somebody took it
# away, and an act with nowhere to be written down should not happen quietly.
[ -f "$ADMIN_LOG" ] \
  || die "no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down. Provisioning seeds that file"

current() { sed -n 's/^MODE=//p' "$UPDATER_CONF" | head -1 | tr -d '"'; }

if [ "$SHOW" -eq 1 ] || [ -z "$MODE" ]; then
  printf 'update mode: %s\n' "$(current)"
  printf 'channel:     %s\n' "$(sed -n 's/^CHANNEL=//p' "$UPDATER_CONF" | head -1 | tr -d '"')"
  if [ -r /etc/commonclaw/release.json ]; then
    printf 'carrying:    %s\n' "$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/commonclaw/release.json | head -1)"
  else
    printf 'carrying:    nothing recorded yet\n'
  fi
  [ "$SHOW" -eq 1 ] && exit 0
  die "--mode is required: auto or manual"
fi

case "$MODE" in
  auto|manual) : ;;
  *) die "--mode must be auto or manual, not '${MODE}'" ;;
esac

WAS="$(current)"
if [ "$WAS" = "$MODE" ]; then
  printf 'set-update-mode: already %s; nothing changed\n' "$MODE" >&2
  exit 0
fi

# ONE LINE REWRITTEN, the rest of the file untouched. The conf carries the
# firm's other choices, so this door replaces the mode and nothing else. A
# rewrite of the whole file would silently drop a value somebody set by hand.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if grep -q '^MODE=' "$UPDATER_CONF"; then
  sed "s/^MODE=.*/MODE=\"${MODE}\"/" "$UPDATER_CONF" > "$tmp"
else
  die "${UPDATER_CONF} carries no MODE line to change; refusing to guess where it belongs"
fi

# Refuse unless the substitution landed exactly once. A blind replace that
# matched twice, or not at all, is the same failure as a sweep reporting clean
# while measuring nothing.
n="$(grep -c "^MODE=\"${MODE}\"$" "$tmp" || true)"
[ "$n" -eq 1 ] || die "the mode line did not substitute exactly once (found ${n}); nothing was written"

install -m 0644 -o root -g root "$tmp" "$UPDATER_CONF"

# ONE ROW, ONE APPEND, ONE CALL. Nobody reads this file and writes it back, so
# two writers in the same second cannot lose each other's row. The caller behind
# sudo, never root, because a record of who decided is the point. The subject
# carries what it WAS as well as what it became, since a mode file already says
# what it is now and the row exists to hold the path there.
printf '| %s | %s | changed the update mode | %s -> %s |\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WHO" "${WAS:-unset}" "$MODE" >> "$ADMIN_LOG"

printf 'set-update-mode: %s -> %s, set by %s, recorded in %s\n' "${WAS:-unset}" "$MODE" "$WHO" "$ADMIN_LOG" >&2
if [ "$MODE" = "manual" ]; then
  printf 'releases will now be reported and held. Apply one with: sudo %s\n' \
    "/opt/commonclaw/provision-claw/scripts/commonclaw-update.sh --now" >&2
fi
