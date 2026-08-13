#!/bin/bash
#
# seats-retire.sh — open the door, then run the claw's own seat retirement.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./seats-retire.sh --person <user> --core <core> --reason "<why>"
#   ./seats-retire.sh --help
#
# REQUIRED ROLE: claw-admin.
#
# EVERY ARGUMENT PASSES THROUGH UNCHANGED to the claw's own retire script, which
# is the only interface. This script parses none of them and validates none of
# them. A second copy of those rules would drift from the copy the claw enforces,
# and the drift would be silent.
#
# WHAT THIS SCRIPT ADDS is the door check, and only that: it reports whether the
# caller holds the role and whether the sudo grant covers the retire script,
# BEFORE anything runs. Without it a missing grant surfaces as a bare sudo error,
# and "you are not claw-admin" is indistinguishable from "this claw never got the
# grant" -- two different answers with two different owners.
#
# On an open door this process is REPLACED by the retire script, so the JSON on
# stdout is that script's own and the exit status is its own. On a closed door
# the JSON below carries stage "door", which is how a reader knows nothing ran.
#
# NEVER EDIT THE ROSTER BY HAND. It is a root-owned file, its grammar has one
# reader, and a line written past that grammar makes the claw's own check refuse
# to check anything. The retirement goes through this door or it does not happen.
#
set -euo pipefail

# The contract with the provisioning plane: the exact absolute path the sudoers
# drop-in grants. Both sides name it, and neither may move it alone.
RETIRE="/opt/commonclaw/provision-claw/scripts/retire-seat.sh"
ROLE="claw-admin"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

[ $# -gt 0 ] || usage

command -v jq >/dev/null 2>&1 || { printf 'jq is required and is not installed\n' >&2; exit 1; }

# Read the group list once and match the whole word. A pipeline into grep -q
# would make the answer depend on the producer's exit status under pipefail.
groups_text=" $(id -nG 2>/dev/null || true) "
case "$groups_text" in
  *" ${ROLE} "*) has_role=true ;;
  *)             has_role=false ;;
esac

# The grant is the door that decides. The role is what the claw declares; sudo
# is what the claw enforces, and root holds the door open without the role.
if sudo -n -l "$RETIRE" >/dev/null 2>&1; then has_grant=true; else has_grant=false; fi

if [ "$has_grant" = true ]; then
  [ "$has_role" = true ] || \
    printf 'note: the grant is open to you without the %s role\n' "$ROLE" >&2
  printf 'running the claw retire script: %s\n' "$RETIRE" >&2
  exec sudo -n "$RETIRE" "$@"
fi

if [ "$has_role" = true ]; then
  note="The role is held but the grant is absent or does not cover this script. Repair it from the provisioning plane; do not reproduce the step by hand. A group added in this session takes effect at next login."
else
  note="The caller does not hold the ${ROLE} role. The claw's own admin runs this operation, or grants the role first. A group added in this session takes effect at next login."
fi

jq -n \
  --arg script "seats-retire" \
  --arg stage "door" \
  --arg retire "$RETIRE" \
  --argjson has_role "$has_role" \
  --argjson has_grant "$has_grant" \
  --arg role "$ROLE" \
  --arg note "$note" \
  '{
     script: $script,
     ok: false,
     stage: $stage,
     retire_script: $retire,
     role_required: $role,
     checks: [
       {check: ("caller holds the " + $role + " role"), ok: $has_role},
       {check: "sudo grant covers the retire script",   ok: $has_grant}
     ],
     failed_checks: (
       (if $has_role  then [] else [("caller holds the " + $role + " role")] end)
       + (if $has_grant then [] else ["sudo grant covers the retire script"] end)
     ),
     notes: [$note]
   }'

exit 1
