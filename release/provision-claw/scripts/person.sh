#!/bin/bash
#
# person.sh: the one test for whether an account on this claw is a person.
#
# SOURCED, never executed. Every rail that reads `claw-members` as the claw's
# people reads it through this file:
#
#   commonclaw-update.sh  the people count before the fetch, and the per-person
#                         core read in the classifier
#   provision-claw.sh     the people set on an update, which the people phase,
#                         the per-person core phase and the wake-rail phase all
#                         iterate, and the two steps in the people phase that
#                         take back what an earlier release gave an account that
#                         is not a person and move that account to the bus group
#   onboard-person.sh     the refusal of a name a system account holds, and the
#                         verify that the account it made is a person
#   install-agents-token.sh
#                         the search for a person to prove the token as, and for
#                         per-home copies of the token
#
# It is one file for the reason version-compare.sh is one file. A second copy of
# the test would drift, and the answer it would drift on is who gets a core, a
# credential grant and a wake-rail unit.
#
# WHY THE UID AS WELL AS THE GROUP. `claw-members` holds people alone. Services
# that post on the bus are in `claw-bus`, and the people phase moves any service
# it finds in `claw-members` there. The group is the first check and the uid is
# the second, because one group once answered both questions: 1.5.1 put the mail
# service's account in `claw-members` to reach the bus, the updater deferred
# every release on that claw, and the second apply gave the account a core, a
# credential loader, the group that reads the claw's broker token, and a
# wake-rail unit. A group is written by whoever runs `gpasswd`. The uid is what
# the machine handed the account when it made it.
#
# The uid says it. The machine hands a login account a uid inside the range
# /etc/login.defs states, UID_MIN to UID_MAX, which is 1000 to 60000 on Ubuntu.
# `useradd --system` hands a service account a uid below UID_MIN. `nobody` sits
# at 65534, above the range. So the test reads the range from the file the
# machine allocates from, and a rail asking it gets the answer useradd already
# gave when it made the account.
#
# THE BOUNDS ARE READ AT EACH CALL, from one path. A key that is absent, or a
# value that is not a number, falls back to Ubuntu's own default for that key.
# The last definition of a key in the file wins, which is how the tools that
# read the file resolve a key written twice.

CC_LOGIN_DEFS="/etc/login.defs"
CC_UID_MIN_DEFAULT=1000
CC_UID_MAX_DEFAULT=60000

# _cc_login_def <key> <default> ; prints the key's value, or the default
_cc_login_def() {
  local v=""
  if [ -r "$CC_LOGIN_DEFS" ]; then
    v="$(awk -v k="$1" '$1 == k && $2 ~ /^[0-9]+$/ { v = $2 } END { print v }' "$CC_LOGIN_DEFS" 2>/dev/null)"
  fi
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *)           printf '%s\n' "$v" ;;
  esac
}

# cc_is_person <account>
#   0  the account exists and its uid lies inside UID_MIN to UID_MAX
#   1  the account exists and its uid lies outside that range
#   2  there is no such account
#
# A name made only of digits is refused as no account. getent answers a number
# with whichever account holds that uid, so without the refusal a stray number
# in a group would be tested as somebody else.
cc_is_person() {
  local name="$1" row uid lo hi
  case "$name" in
    ''|*:*|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  case "$name" in
    *[!0-9]*) : ;;
    *) return 2 ;;
  esac
  # `|| true` because every caller runs under `set -euo pipefail`, and a lookup
  # that finds nobody is an answer here rather than a reason to end the run.
  row="$(getent passwd "$name" 2>/dev/null | head -1 || true)"
  [ -n "$row" ] || return 2
  [ "${row%%:*}" = "$name" ] || return 2
  uid="$(printf '%s\n' "$row" | cut -d: -f3)"
  case "$uid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  lo="$(_cc_login_def UID_MIN "$CC_UID_MIN_DEFAULT")"
  hi="$(_cc_login_def UID_MAX "$CC_UID_MAX_DEFAULT")"
  [ "$uid" -ge "$lo" ] && [ "$uid" -le "$hi" ] && return 0
  return 1
}

# cc_group_members <group> ; prints the group's listed members, one per line
#
# The one parse of a group row. A person who carries the group as their PRIMARY
# group is not listed in the row and so is not printed, which is the behaviour
# every caller had before this file.
cc_group_members() {
  getent group "$1" 2>/dev/null \
    | awk -F: '{ n = split($4, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }' \
    || true
}

# cc_people_in_group <group> ; prints the members that pass cc_is_person
cc_people_in_group() {
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    cc_is_person "$m" && printf '%s\n' "$m"
  done < <(cc_group_members "$1")
  return 0
}
