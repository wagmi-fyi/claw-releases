#!/bin/bash
#
# startup-tokens.sh: open the door, then run the claw's own startup-file survey.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   ./startup-tokens.sh
#   ./startup-tokens.sh --help
#
# REQUIRED ROLE: claw-admin.
#
# WHAT IT ANSWERS. Which people's shell startup files set or export a 1Password
# token. Each hit is path:line:NAME under the person's name, and a claw with
# none answers "none". The line itself and its value are never printed.
#
# THE SURVEY IS THE AGENTS TOKEN DOOR'S OWN, run with --survey. That door
# already walks every person's home as root, and this grant already covers it.
# A second reader of other people's homes would be a second root implementation
# of one rule. The door's survey reads, prints names, and changes nothing.
#
# WHAT THIS SCRIPT ADDS is the door check, and only that: it reports whether the
# caller holds the role and whether the sudo grant covers the door, BEFORE
# anything runs.
#
# On an open door this process is REPLACED by the door, so the JSON on stdout is
# the door's own and the exit status is its own. The list is in its
# "startup_exports" field. On a closed door the JSON below carries stage "door",
# which is how a reader knows nothing ran.
#
set -euo pipefail

# The contract with the provisioning plane: the exact absolute path the sudoers
# drop-in grants. Both sides name it, and neither may move it alone.
DOOR="/opt/commonclaw/provision-claw/scripts/install-agents-token.sh"
ROLE="claw-admin"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

case "${1:-}" in
  '') : ;;
  -h|--help) usage ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
esac

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
if sudo -n -l "$DOOR" >/dev/null 2>&1; then has_grant=true; else has_grant=false; fi

if [ "$has_grant" = true ]; then
  [ "$has_role" = true ] || \
    printf 'note: the grant is open to you without the %s role\n' "$ROLE" >&2
  printf 'running the agents token door survey: %s --survey\n' "$DOOR" >&2
  exec sudo -n "$DOOR" --survey
fi

if [ "$has_role" = true ]; then
  note="The role is held but the grant is absent or does not cover the agents token door. Repair it from the provisioning plane. Do not read other people's homes by hand. A group added now reaches only a process that starts after it. /etc/commonclaw/workspace-conventions.md says what ends the old ones, under Access."
else
  note="The caller does not hold the ${ROLE} role. The claw's own admin runs this operation, or grants the role first. A group added now reaches only a process that starts after it. /etc/commonclaw/workspace-conventions.md says what ends the old ones, under Access."
fi

jq -n \
  --arg script "startup-tokens" \
  --arg stage "door" \
  --arg door "$DOOR" \
  --argjson has_role "$has_role" \
  --argjson has_grant "$has_grant" \
  --arg role "$ROLE" \
  --arg note "$note" \
  '{
     script: $script,
     ok: false,
     stage: $stage,
     door_script: $door,
     role_required: $role,
     checks: [
       {check: ("caller holds the " + $role + " role"), ok: $has_role},
       {check: "sudo grant covers the agents token door", ok: $has_grant}
     ],
     failed_checks: (
       (if $has_role  then [] else [("caller holds the " + $role + " role")] end)
       + (if $has_grant then [] else ["sudo grant covers the agents token door"] end)
     ),
     notes: [$note]
   }'

exit 1
