#!/bin/bash
#
# core-version.sh — the one reader for a person's persistent-session core version.
#
# SOURCED, never executed. Two callers ask what version a person carries, and
# both read this file: provision-claw.sh holds each person to the floor, and
# commonclaw-update.sh decides whether a release would move a core and therefore
# has to wait for the quiet window.
#
# It is one file for the reason version-compare.sh is one file. A second copy
# would drift, and this one would drift on how much of somebody's home a routine
# check opens — which is the cost the register maps, not a detail.

# ---------------------------------------------------------- the version read
#
# READ THE INSTALL, DO NOT RUN IT.
#
# The vendor installs each version into its own directory and points one symlink
# at the chosen one, so the version is the TARGET'S BASENAME and root reads it
# with nothing starting in the person's home.
#
# That matters because both callers run this for EVERY person on EVERY pass,
# including the ordinary one where everybody is at or above the floor and there
# is nothing to do. The form this replaces was a login shell in their home,
# sourcing their profile, on a pass with no work in it. Phase 14 of the
# provisioning run stopped handing a core somebody's home deliberately; this read
# was two functions away and still doing it, and the updater was doing it once
# per member per offered release.
#
# The symlink is the member's own, so a member could point it anywhere. That
# grants nothing new: they own the binary it names either way.
#
# FALLING BACK RATHER THAN GUESSING. An install laid out some other way is asked
# directly, which is the old cost paid only where the cheap read cannot answer.
# Answering nothing at all is also a valid outcome, and both callers already
# refuse to install on a version they cannot read rather than risk moving a core
# backwards.
claude_version_for() {
  local link target
  link="$(getent passwd "$1" | cut -d: -f6)/.local/bin/claude"
  if [ -L "$link" ]; then
    target="$(readlink -f -- "$link" 2>/dev/null || true)"
    target="${target##*/}"
    # Only a version-shaped basename is an answer. Anything else falls through to
    # the core's own report rather than being handed to the comparison, which
    # would refuse it and call a healthy claw broken.
    case "$target" in
      [0-9]*.[0-9]*.[0-9]*) printf '%s' "$target"; return 0 ;;
    esac
  fi
  # The core answers `--version` with "2.1.227 (Claude Code)", so the version is
  # the FIRST field. Read as the person from a login shell, because an install
  # laid out some other way reaches PATH through their profile and root's own
  # environment would find nothing.
  sudo -u "$1" -H bash -lc 'command -v claude >/dev/null 2>&1 && claude --version' \
    </dev/null 2>/dev/null | awk '{print $1}' || true
}
