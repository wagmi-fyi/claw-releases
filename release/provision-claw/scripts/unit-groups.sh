#!/bin/bash
#
# unit-groups.sh: whether a running unit's process holds the group that owns a
# directory.
#
# SOURCED, never executed. Three callers read it:
#
#   install-email-gatekeeper.sh   the mail service, against the bus root
#   install-bus-nudge.sh          each wake-rail watcher, against the shared bus
#   manage-workspace-access.sh    a person's own service manager, against the
#                                 group list that person now holds
#
# Each one restarts a unit whose process lacks a group, because a running
# process keeps the groups it started with. The two installers carried one
# copy each, byte for byte the same, from 1.6.0's move of the bus to its own
# group. This file is that copy, and neither installer carries its own.
#
# It is one file for the reason person.sh is one file. A second copy of the
# reading would drift, and the answer it would drift on is whether a service
# reaches the bus after the apply.

# unit_holds_group <unit> <directory>
#   0  the unit's main process holds the group that owns the directory
#   1  it does not
#   2  there is nothing to read: no running process, or no such directory
#
# Named by no group. The directory's owner says which group, so the answer
# follows the bus wherever provisioning puts it.
unit_holds_group() {
  local pid gid
  [ -n "$2" ] && [ -d "$2" ] || return 2
  gid="$(stat -c '%g' -- "$2" 2>/dev/null)" || return 2
  pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null)"
  case "$pid" in ''|0|*[!0-9]*) return 2 ;; esac
  [ -r "/proc/${pid}/status" ] || return 2
  awk -v g="$gid" '$1 == "Gid:" || $1 == "Groups:" { for (i = 2; i <= NF; i++) if ($i == g) f = 1 }
                   END { exit f ? 0 : 1 }' "/proc/${pid}/status"
}

# unit_group_drift <unit> <account>
#   0  the unit's main process and the account hold different group sets
#   1  they hold the same set
#   2  there is nothing to read: no running process, or no such account
#
# The whole set rather than one group. A grant and a revoke both leave a
# running process holding what it was born with, and a check written for one
# direction reports the other as converged. Reading both sides as sets answers
# either one.
#
# The account's side comes from the claw's own group record. The process's side
# comes from /proc, because a process is the only place its own group set is
# readable and the record cannot say what a running thing already started with.
unit_group_drift() {
  local pid mine theirs
  mine="$(id -G "$2" 2>/dev/null | tr ' ' '\n' | sort -nu | tr '\n' ' ')"
  [ -n "$mine" ] || return 2
  pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null)"
  case "$pid" in ''|0|*[!0-9]*) return 2 ;; esac
  [ -r "/proc/${pid}/status" ] || return 2
  theirs="$(awk '$1 == "Gid:" { print $2 } $1 == "Groups:" { for (i = 2; i <= NF; i++) print $i }' \
              "/proc/${pid}/status" | sort -nu | tr '\n' ' ')"
  [ -n "$theirs" ] || return 2
  [ "$mine" != "$theirs" ]
}
