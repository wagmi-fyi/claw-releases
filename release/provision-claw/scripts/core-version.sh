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
#
# ANSWERING NOTHING IS TWO DIFFERENT ANSWERS, and this function cannot tell them
# apart. A person with no core at all reads as the empty string, and so does a
# core that is installed and cannot say what it is. A caller that needs the
# difference asks claude_present_for below; it must not read it off this value.
claude_version_for() {
  local link target
  link="$(getent passwd "$1" | cut -d: -f6)/.local/bin/claude"
  # THE LINK HAS TO REACH A RUNNABLE FILE before its name is an answer.
  # readlink resolves a path whether or not anything is there, so a launcher
  # left pointing at a version that has been removed still yields a
  # version-shaped basename -- and a claw would report that person at or above
  # the floor, left alone, with no core they can start. Measured 2026-08-16:
  # a dangling launcher naming 2.1.999 read as 2.1.999 and passed the phase.
  #
  # -f AND -x, NOT -x ALONE. -x is TRUE FOR A DIRECTORY, so a launcher naming a
  # version-shaped directory passes an executability test and reads healthy --
  # measured 2026-08-16, the same false green by a second route. -f rejects a
  # directory; -x still requires the execute bit on what is left.
  #
  # Both tests follow the symlink, so a dangling launcher fails them and falls
  # through to the read below, which answers nothing, which is the honest answer
  # for a person no core resolves for.
  if [ -L "$link" ] && [ -f "$link" ] && [ -x "$link" ]; then
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

# -------------------------------------------------------- the absence probe
#
# ABSENT IS NOT UNREADABLE, and only asking can separate them.
#
# The version comparison refuses on the empty string, so a caller that reads
# absence off that refusal calls a person who has never logged in a core too
# broken to touch. That is a probe keyed on the wrong field: the version read
# failed, and the thing being claimed is that no binary exists. Measured
# 2026-08-16 on the hub, it left a roster member with no core at all and the
# release's apply refusing to give her one.
#
# So this asks the one question that separates the two: does a claude resolve
# for this person.
#
# WHAT `command -v` ACTUALLY ANSWERS, because the claim this comment used to make
# was not the one the shell keeps. It reports whether the name resolves to
# something that is there and is not a directory. It does NOT test the execute
# bit: measured 2026-08-16, bash answers rc=0 for a 0644 candidate on PATH, where
# dash answers 127. So "resolves" is the only claim this probe can carry, and it
# is the claim the branch is written on.
#
# It is the right question anyway. A launcher pointing at a version that is gone
# answers no, and so does one pointing at a directory (both measured rc=1),
# because neither resolves to a file -- and where nothing resolves there is no
# installed core anybody could move backwards. A candidate that is there and
# cannot run counts as PRESENT here, which sends that person to the refusal
# branch, which is where a core somebody has to go and look at belongs.
#
# It reads PATH the same way the fallback above does, from a login shell as the
# person, because an install laid out some other way is reachable only through
# their profile and the two must not disagree about what is installed.
#
# COST, and where it is paid. This is a login shell in somebody's home, which is
# the cost w40 took out of the ordinary pass. Call it ONLY where the version
# comparison has already refused. That branch is not reached at all on the pass
# where everybody is at or above the floor, so the ordinary run still starts
# nothing in anybody's home.
claude_present_for() {
  sudo -u "$1" -H bash -lc 'command -v claude >/dev/null 2>&1' \
    </dev/null >/dev/null 2>&1
}
