#!/bin/bash
#
# bootstrap-workspace.sh — open the door, then run the claw's own scaffold.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./bootstrap-workspace.sh --workspace <name> --members <user>[,<user>...]
#   ./bootstrap-workspace.sh --help
#
# REQUIRED ROLE: claw-admin.
#
# EVERY ARGUMENT PASSES THROUGH UNCHANGED to the claw's scaffold, which is the
# only interface. This script parses none of them and validates none of them.
# A second copy of the scaffold's argument rules would drift from the copy the
# provisioner enforces, and the drift would be silent.
#
# WHAT THIS SCRIPT ADDS is the door check, and only that: it reports whether
# the caller holds the role and whether the sudo grant covers the scaffold,
# BEFORE anything runs. Without it a missing grant surfaces as a bare sudo
# error, and "you are not claw-admin" is indistinguishable from "this claw
# never got the grant" -- two different answers with two different owners.
#
# On an open door this process is REPLACED by the scaffold, so the JSON on
# stdout is the scaffold's own and the exit status is the scaffold's own.
# On a closed door the JSON below carries stage "door", which is how a reader
# knows the scaffold never ran.
#
set -euo pipefail

# The contract with the provisioning plane: the exact absolute path the sudoers
# drop-in grants. Both sides name it, and neither may move it alone.
SCAFFOLD="/opt/commonclaw/provision-claw/scripts/scaffold-workspace.sh"
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
if sudo -n -l "$SCAFFOLD" >/dev/null 2>&1; then has_grant=true; else has_grant=false; fi

if [ "$has_grant" = true ]; then
  [ "$has_role" = true ] || \
    printf 'note: the grant is open to you without the %s role\n' "$ROLE" >&2
  printf 'running the claw scaffold: %s\n' "$SCAFFOLD" >&2
  exec sudo -n "$SCAFFOLD" "$@"
fi

if [ "$has_role" = true ]; then
  note="The role is held but the grant is absent or does not cover this script. Repair it from the provisioning plane; do not reproduce the step by hand. A group added in this session takes effect at next login."
else
  note="The caller does not hold the ${ROLE} role. The claw's own admin runs this operation, or grants the role first. A group added in this session takes effect at next login."
fi

jq -n \
  --arg script "bootstrap-workspace" \
  --arg stage "door" \
  --arg scaffold "$SCAFFOLD" \
  --argjson has_role "$has_role" \
  --argjson has_grant "$has_grant" \
  --arg role "$ROLE" \
  --arg note "$note" \
  '{
     script: $script,
     ok: false,
     stage: $stage,
     scaffold: $scaffold,
     role_required: $role,
     checks: [
       {check: ("caller holds the " + $role + " role"), ok: $has_role},
       {check: "sudo grant covers the scaffold",        ok: $has_grant}
     ],
     failed_checks: (
       (if $has_role  then [] else [("caller holds the " + $role + " role")] end)
       + (if $has_grant then [] else ["sudo grant covers the scaffold"] end)
     ),
     notes: [$note]
   }'

exit 1
