#!/bin/bash
#
# render-template.sh — the one substitution rule for a workspace template.
#
# SOURCED, never executed. Two scripts render a workspace template and they both
# read this file: scaffold-workspace.sh writes a new briefing with it, and
# provision-claw.sh reproduces an existing one with it to decide whether a member
# has edited that briefing.
#
# It is one file because a second copy of the substitution would drift from the
# first, and the drift would surface as provisioning judging an untouched
# briefing to be member-authored, which is the one verdict that must not be
# wrong. This is the same law the workspace layout applies to AGENTS.md, applied
# to a rule instead of to a filename.
#
# Reads WORKSPACE and WS_GROUP from the caller. Takes the hostname from the
# machine, so reproducing an existing briefing is only meaningful on the claw
# that created it: a claw renamed since will not reproduce its own files.

render() {
  local src="$1" dest="$2" content
  content="$(cat "$src")"
  content="${content//\{\{WORKSPACE\}\}/$WORKSPACE}"
  content="${content//\{\{GROUP\}\}/$WS_GROUP}"
  content="${content//\{\{HOSTNAME\}\}/$(hostname)}"
  printf '%s\n' "$content" > "$dest"
}
