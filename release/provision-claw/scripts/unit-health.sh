#!/bin/bash
#
# unit-health.sh — whether this machine's units are healthy, in one reading a
# looping unit cannot pass.
#
# TWO CALLERS, ONE READING. The updater prints this at the end of an apply, and
# the ride runbook tells a person to run it. The other shared siblings here are
# sourced and never executed because each has one kind of caller; this one has
# two, so it does both. A second copy of the reading would drift, and it would
# drift on whether a claw is healthy.
#
# WHY `systemctl --failed` IS NOT THE READING. A unit with `Restart=` never
# settles into `failed`. It sits in `activating` forever, `--failed` stays empty,
# and whoever reads that line calls the box healthy. Measured on wagmi on
# 2026-09-02: `--failed` listed zero units while one instance of the wake rail
# restarted every ten seconds and wrote about 43,000 journal lines a day.
#
# So the reading is both halves. Nothing failed, and nothing in `activating`
# carrying a restart count. The second half is the one that catches a loop, and
# it is the half every runbook here was missing.
#
#   unit_health         one line per finding on stdout. 0 clean, 1 something
#                       is wrong.
#   ./unit-health.sh    the same, for an operator with one command to type.
#
# THE OVERRIDE BELOW EXISTS FOR CONTROLS, the way OP_BIN does in
# install-heartbeat-url.sh. A rig cannot make a real unit loop on a live box
# without installing one, so the reading is driven against a recording stub
# instead. Nothing in the field sets it.
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

unit_health() {
  local rc=0 unit n

  # ---- nothing failed ----
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    printf 'FAILED     %s\n' "$unit"
    rc=1
  done < <("$SYSTEMCTL" list-units --state=failed --no-legend --plain --all 2>/dev/null \
             | awk '{print $1}')

  # ---- nothing looping ----
  #
  # A restart count of zero in `activating` is a unit merely coming up, which is
  # ordinary on a box that has just booted or just taken a release. A count above
  # zero is a unit that has already died at least once and is on its way back,
  # and that is the loop.
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    n="$("$SYSTEMCTL" show -p NRestarts --value "$unit" 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 0 ] || continue
    printf 'RESTARTING %s (%s restart(s), still activating)\n' "$unit" "$n"
    rc=1
  done < <("$SYSTEMCTL" list-units --state=activating --no-legend --plain --all 2>/dev/null \
             | awk '{print $1}')

  if [ "$rc" -eq 0 ]; then
    printf 'units healthy: none failed, none activating with a restart count\n'
  fi
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  unit_health
  exit $?
fi
