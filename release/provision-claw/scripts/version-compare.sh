#!/bin/bash
#
# version-compare.sh — the one version comparison for this skill.
#
# SOURCED, never executed. Two callers compare versions and they both read this
# file: provision-claw.sh holds each core to its floor, and commonclaw-update.sh
# decides whether a release on offer is newer than the one this claw carries.
#
# It is one file because a second copy would drift from the first, and the verdict
# it would drift on is whether a machine moves backwards. That is the same law
# render-template.sh applies to the substitution rule, applied to a comparison.
#
# The block below is unchanged from where it was proven. It shipped inside
# provision-claw.sh and carried 29 controls there, including the four cases where
# a string compare puts 2.1.9 above 2.1.10. Moving it must not alter a byte of it.

# ---------------------------------------------------------- version comparison
#
# THE WHOLE RISK OF THE VERSION FLOOR IS HERE. A string compare says 2.1.9 is
# newer than 2.1.10, and getting this wrong produces silently the exact defect
# the floor exists to prevent: a run that moves somebody's core backwards while
# reporting that it did not. So this compares segments as NUMBERS, and it has
# three verdicts rather than two.
#
#   0  a is at or above b   -> the caller skips
#   1  a is below b         -> the caller installs
#   2  REFUSED              -> the caller does NEITHER, and says so
#
# THE REFUSAL IS LOAD-BEARING, not defensive tidiness. An input this function
# does not understand -- an empty string because the binary is absent, a
# prerelease suffix, a sentence from a tool that answered `--version` with an
# error -- is a case where we cannot prove an install would be forward. The only
# safe answer is to refuse and let the phase report it, because guessing here is
# indistinguishable from the bug. Every caller treats refusal as do-not-install.
#
# Missing segments compare as zero, so 2.1 and 2.1.0 are equal and 2.1.1 is above
# both. A segment is capped at nine digits: shell arithmetic is 64-bit and a
# longer run of digits would overflow into a wrong answer rather than an error,
# which is the one failure mode this function must not have.
#
# Written as if/fi rather than as AND-lists on purpose. Under `set -e` a bare
# `[ x -gt y ] && return 0` exits the whole script the moment the test is false,
# which here is the ordinary path, not an error.
version_at_least() {
  local a="$1" b="$2" i n x y
  local -a A=() B=()

  # digits and single dots only, no leading, trailing or doubled dot, not empty
  case "$a" in ''|*[!0-9.]*|*..*|.*|*.) return 2 ;; esac
  case "$b" in ''|*[!0-9.]*|*..*|.*|*.) return 2 ;; esac

  IFS=. read -r -a A <<<"$a" || true
  IFS=. read -r -a B <<<"$b" || true

  for i in "${A[@]}" "${B[@]}"; do
    if [ "${#i}" -gt 9 ]; then return 2; fi
  done

  n=${#A[@]}
  if [ "${#B[@]}" -gt "$n" ]; then n=${#B[@]}; fi

  for ((i=0; i<n; i++)); do
    x=$(( 10#${A[i]:-0} ))
    y=$(( 10#${B[i]:-0} ))
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}
