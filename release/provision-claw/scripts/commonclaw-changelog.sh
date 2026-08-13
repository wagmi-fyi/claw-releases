#!/bin/bash
#
# commonclaw-changelog.sh — write one entry into the claw's own changelog.
#
# PAYLOAD SCRIPT. Installed onto the claw by provision-claw.sh. Called by the
# provisioning run that caused the change, and by the updater when it applies a
# release. One code path, because the obligation must not depend on which of the
# two did the work.
#
#   commonclaw-changelog.sh --revision <rev> --class <class> --notes <file>
#                           [--date <YYYY-MM-DD>] [--dry-run]
#
# WHY THIS EXISTS. `reference/claw-conventions.md` has said since the beginning
# that every provisioning run leaves one entry here and that a ride with no entry
# is invisible to everybody except the person who did it. Nothing enforced it.
# Confirmed 2026-08-13 by stripping comments from all eight shipped scripts: NO
# code path created or appended this file. Every entry in the fleet was written
# by hand afterwards, and three different operators missed the obligation in one
# week. An obligation that depends on somebody remembering is the shape this
# project keeps finding, so it is mechanized here.
#
# WHAT THIS SCRIPT DOES NOT DO: author the prose. The words come from the
# release's own notes, or from the file an operator names. A machine cannot say
# what a change feels like to the person using the claw, and that is the only
# thing the entry is for.
#
# REGISTER. The entry is read by a member and by their own agent, so the notes
# are natural language rather than ASD-STE100. The rest of the provisioning
# material is the other way round, and `SKILL.md` carries the split.
#
set -euo pipefail

CHANGELOG=/etc/commonclaw/changelog.md
CONF=/etc/commonclaw/provision.conf

REVISION=""; CLASS=""; NOTES_FILE=""; ENTRY_DATE=""; DRY_RUN=0

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --revision) REVISION="${2:-}"; shift 2 ;;
    --class)    CLASS="${2:-}";    shift 2 ;;
    --notes)    NOTES_FILE="${2:-}"; shift 2 ;;
    --date)     ENTRY_DATE="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

die() { printf 'commonclaw-changelog: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root: the changelog is root-owned and only provisioning writes it"

[ -n "$REVISION" ]   || die "--revision is required: the entry names the commit the run was staged from"
[ -n "$CLASS" ]      || die "--class is required"
[ -n "$NOTES_FILE" ] || die "--notes is required: the entry carries member-facing prose, and this script does not invent it"
[ -r "$NOTES_FILE" ] || die "cannot read notes file: ${NOTES_FILE}"
[ -s "$NOTES_FILE" ] || die "notes file is empty: ${NOTES_FILE} -- an entry with no prose tells a member nothing"

# A revision must survive being read back out of the file, so it stays to the
# shape git actually produces. A newline here would split one entry into two.
case "$REVISION" in
  *[!0-9a-zA-Z._-]*) die "--revision carries a character that is not part of a revision: '${REVISION}'" ;;
esac

# THE CLASS IS A CLOSED SET, and that is the point of the field. It exists so a
# reader knows what kind of change this is BEFORE the prose, and a free-text
# field drifts into a second summary. w28 extended it by one: a mixed run names
# both classes rather than choosing, with the fix first, because a reader
# deciding whether to look further needs to know a fix is in there.
case "$CLASS" in
  fix|feature|"fix and feature"|"security fix"|"security fix and feature") : ;;
  *) die "--class must be one of: fix | feature | fix and feature | security fix | security fix and feature (got '${CLASS}')" ;;
esac

# The day the run landed. Taken from the box in the same beat unless an operator
# names one, because a date carried in from somewhere else describes a different
# day than the one the change arrived on.
[ -n "$ENTRY_DATE" ] || ENTRY_DATE="$(date -I)"
case "$ENTRY_DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) die "--date must be YYYY-MM-DD (got '${ENTRY_DATE}')" ;;
esac

HOSTNAME_FOR_HEADER="$(hostname)"
if [ -r "$CONF" ]; then
  conf_host="$(sed -n 's/^BOX_HOSTNAME=//p' "$CONF" 2>/dev/null || true)"
  [ -n "$conf_host" ] && HOSTNAME_FOR_HEADER="$conf_host"
fi

# THE FINGERPRINT THE DEDUPE COMPARES ON, and it must never be empty.
#
# The first NON-EMPTY line, not the first line. A notes file that opens with a
# blank line would otherwise hand an empty pattern to a fixed-string search, an
# empty pattern matches every line of any file, and the script would then decide
# the entry was already recorded and skip it. Silently, and for every release
# after it. That is the sweep-reports-clean-while-measuring-nothing shape, so the
# empty case is refused here rather than discovered as a missing entry later.
NOTES_FINGERPRINT="$(grep -m1 -v '^[[:space:]]*$' "$NOTES_FILE" || true)"
[ -n "$NOTES_FINGERPRINT" ] \
  || die "notes file carries no non-blank line: ${NOTES_FILE} -- an entry with no prose tells a member nothing"

# ALREADY RECORDED IS A SKIP, NOT A SECOND ENTRY. A convergence re-run gave the
# claw nothing it did not already have, so a second identical entry would report
# a change that did not happen. Matched on the revision AND the notes together:
# the same revision with different prose is a different statement about the same
# commit and is allowed through.
if [ -f "$CHANGELOG" ] && grep -qF "**Revision:** ${REVISION}" "$CHANGELOG" 2>/dev/null; then
  if grep -qF -- "$NOTES_FINGERPRINT" "$CHANGELOG" 2>/dev/null; then
    printf 'commonclaw-changelog: revision %s with these notes is already recorded; nothing appended\n' "$REVISION" >&2
    exit 0
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'commonclaw-changelog: would append an entry dated %s for revision %s, class %s\n' \
    "$ENTRY_DATE" "$REVISION" "$CLASS" >&2
  [ -f "$CHANGELOG" ] || printf 'commonclaw-changelog: would also seed the header, because %s does not exist\n' "$CHANGELOG" >&2
  exit 0
fi

install -d -m 0755 -o root -g root /etc/commonclaw

# THE SEEDED HEADER, written only into an absence. It states the day the record
# starts, so silence above the first entry reads as the file not existing rather
# than as nothing having happened.
#
# THE SENTENCE CLAIMS NOTHING ABOUT WHAT CAME BEFORE, and that is deliberate.
# Every claw alive today ran for weeks before anything wrote here, so saying the
# machine was provisioned earlier would be true of all of them. It would be FALSE
# on a claw born with this rail, whose first entry is its own birth, and this
# header is permanent: a false sentence seeded here outlives everybody who could
# correct it. So it says only that the file did not exist, which holds either way.
if [ ! -f "$CHANGELOG" ]; then
  cat > "$CHANGELOG" <<HEADEOF
# ${HOSTNAME_FOR_HEADER} changelog

What this machine has been given, newest entry at the bottom. Each entry is
written by the provisioning run that caused it. Nothing else writes here.

If a behaviour changed under you, this file is the answer. Read it before asking
anyone.

**This record starts on ${ENTRY_DATE}.** Silence above this line means the file
did not exist yet. Anything that happened to this machine before that date is not
written here.

---
HEADEOF
  printf 'commonclaw-changelog: seeded the header at %s\n' "$CHANGELOG" >&2
fi

# ONE APPEND, ONE CALL. Nobody reads this file and writes it back, so two writers
# in the same second cannot lose each other's entry. Same shape the member-plane
# log uses in onboard-person.sh.
{
  printf '\n## %s\n\n' "$ENTRY_DATE"
  printf '**Revision:** %s\n' "$REVISION"
  printf '**Class:** %s\n\n' "$CLASS"
  printf '**What changed**\n\n'
  cat "$NOTES_FILE"
  printf '\n'
} >> "$CHANGELOG"

# World-readable, because the first reader is a member's own session asking what
# changed under them. A record only the operator can read answers the operator's
# question, which was never the one being asked.
chmod 0644 "$CHANGELOG"
chown root:root "$CHANGELOG"

printf 'commonclaw-changelog: appended an entry dated %s for revision %s (class: %s)\n' \
  "$ENTRY_DATE" "$REVISION" "$CLASS" >&2
