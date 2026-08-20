#!/bin/bash
#
# manage-claw-authority.sh — apply one signed authority decision to this claw.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./manage-claw-authority.sh --apply grant-door     <request> <signature> --script <path>
#   sudo ./manage-claw-authority.sh --apply revoke-door    <request> <signature>
#   sudo ./manage-claw-authority.sh --apply add-admin      <request> <signature>
#   sudo ./manage-claw-authority.sh --apply remove-admin   <request> <signature>
#   sudo ./manage-claw-authority.sh --apply transfer-owner <request> <signature>
#
#   --dry-run   verify everything, print the plan, change nothing, consume nothing
#
#   Requests are composed with `claw-authority`, on the member plane, by anybody.
#   `claw-authority --list` reads who holds authority here and needs no privilege.
#
# GRANTED SCRIPT. A claw-admin runs it through the member plane. It is root-owned
# and unwritable by its caller, it validates its own arguments, and it is
# idempotent, because the sudo grant carries no validation of its own.
#
# ---------------------------------------------------------------------------
# THE AUTHORITY MODEL, WHICH IS THIS FILE'S WHOLE SUBJECT
#
# THREE TIERS, AND THEY ARE FACTS ABOUT ONE CLAW.
#
#   OWNER    exactly one, on every claw that has a registry. Never deleted, only
#            transferred, and a transfer needs the current owner's own signature.
#            The owner is the only tier that can change the roster.
#   ADMINS   appointed and removed by the owner alone. An admin cannot appoint an
#            admin. An admin can approve a door.
#   STAFF    everybody in `claw-members`. Unchanged by this file, and holding no
#            privilege, which is what that group has always meant.
#
# WHY AN ADMIN CANNOT MINT AN ADMIN. A tier that can widen itself is one tier
# wearing two names: the first admin appoints the second, and the set the owner
# thought they were choosing is a set anybody in it can extend without the owner
# hearing about it. Appointment is the owner's, and it is the only power that
# does not delegate.
#
# ONE SIGNATURE APPROVES A DOOR. Any owner or any admin. Two-signature approval
# is a decision this claw has deliberately not taken yet; the record written for
# every approval already names one signer and one tier, so a second would be an
# added field rather than a changed shape. Nothing here anticipates it further
# than that, because a half-built second signature is a check that cannot fail.
#
# NO APPROVAL SECRET EVER RESTS ON THIS BOX. What rests here is public: the
# public halves of the keys, and the signatures they made. The approval itself
# happens on a person's own machine, with a private key that never travels. This
# is why an agent may draft a door and can never install one -- not because a
# rule says so, but because installing one takes a key no process on this claw
# can reach.
#
# THE MECHANISM IS SSH SIGNATURES, because a claw's people already hold SSH keys
# and a second kind of key would be a second thing to lose. `ssh-keygen -Y sign`
# on their device, `ssh-keygen -Y verify` here, against an allowed-signers file
# this claw keeps. No new tool, no new key, no new ceremony.
#
# THE SIGNATURE IS OVER A DOCUMENT, AND THE DOOR SCRIPT'S EXACT CONTENT HASH IS
# IN IT. The hash is what decides which bytes may be installed and it keeps
# deciding: the wrapper re-checks it on every run. It sits inside a document
# because a signature over a bare hash approves those bytes on every claw the
# firm owns, under any operation that takes a hash, forever. The document adds
# the claw, the operation and a deadline, and a request id this claw records so
# a kept document cannot be replayed to undo a later decision.
#
# THE REGISTRY IS EDITED ONLY BY THE OPERATIONS BELOW. Provisioning lays it once
# into an absence, the same law the updater's mode file and the seat roster
# follow. Nothing else writes it, and a provisioning run that re-asserted a
# roster the firm had since changed would be the vendor overruling the firm on
# its own machine.
#
# REVOKE IS SYMMETRIC WITH GRANT. Taking a door away needs a signature exactly as
# giving one does. An asymmetry there would mean the cheaper act is the
# destructive one, and every door on the claw would rest on whoever could run
# this script rather than on whoever approved it.
#
# A LOST OWNER IS NOT SOLVED HERE. It is a break-glass act the vendor performs on
# the firm's written request, and it is written down rather than coded:
# `reference/claw-conventions.md` carries it. A recovery path in this file would
# be a second way into the registry, sitting on the box, reachable by whatever
# could reach this script -- which is the thing the whole design is arranged to
# prevent.
#
# WHAT A SIGNATURE DOES NOT DO, SAID RATHER THAN IMPLIED. It does not read the
# script. Somebody signing a grant is vouching that they looked at those bytes
# and want them running as root on this claw. This door verifies WHO approved and
# WHAT EXACTLY they approved. It has no opinion about whether the thing is safe,
# and it cannot have one.
#
# REVOKING SOMEBODY'S LOGIN KEY DOES NOT REVOKE THEIR SIGNING AUTHORITY. The
# registry is its own record. A device lost by an admin needs `manage-person-keys
# --revoke-key` for the login and `--apply remove-admin` for the authority, and
# the member doc says so in those words.
#
# ONE VERB. Every operation is `--apply <operation> <request> <signature>`,
# because the operation is a field the signer signed. Naming it on the command
# line as well is the caller stating intent: the two must agree, so a request
# file swapped for another cannot act under the name somebody typed.
#
set -euo pipefail

# THIS DOOR RESOLVES ITS OWN TOOLS. Every command below is called by bare name --
# `ssh-keygen`, `visudo`, `gpasswd`, `stat`, `sha256sum`, `runuser` and the rest --
# and a bare name is resolved through PATH. Until this line the door had no PATH
# of its own and took whatever it was handed.
#
# What normally stops that being fatal is `secure_path` in `/etc/sudoers`, which
# makes sudo discard the caller's PATH and supply this one. It is set by the
# distribution, it is not written by any CommonClaw file, and no provisioning
# control on this claw reads it back. So the whole authority model rested on a
# line in a file this project does not own and does not measure: a claw whose
# `/etc/sudoers` lost it would hand this door away to a shimmed `ssh-keygen` on
# the caller's PATH, and every release would still report green.
#
# A door that depends on something should require it rather than inherit it.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

MODE=""; OPERATION=""; REQ_FILE=""; SIG_FILE=""; SRC_SCRIPT=""; DRY_RUN=0

ADMIN_LOG="/etc/commonclaw/admin-log.md"
MEMBERS_GROUP="claw-members"
CLAW_ADMIN_GROUP="claw-admin"

AUTHORITY_ROOT="/etc/commonclaw/authority"
OWNER_FILE="${AUTHORITY_ROOT}/owner"
ADMINS_FILE="${AUTHORITY_ROOT}/admins"
DOORS_DIR="${AUTHORITY_ROOT}/doors"
SEEN_FILE="${AUTHORITY_ROOT}/requests-seen"

OPT_ROOT="/opt/commonclaw"
TENANT_DOOR_ROOT="${OPT_ROOT}/tenant-doors"
TENANT_SUDOERS="/etc/sudoers.d/commonclaw-tenant-doors"

# Where a door may be drafted from. The tenant's own plane. Two reasons and both
# are load-bearing: it is the plane members write in, and it is the plane the
# backup rail keeps, so the source of an approved door survives a restore that
# `/opt` does not.
WORKSPACE_ROOT="/srv/workspaces"

# It must match `payload/claw-authority`'s copy character for character. The
# member-plane program tells people which namespace to sign under; this is the
# value that decides whether what they signed is accepted.
NAMESPACE="claw-authority@commonclaw"
DOC_VERSION="commonclaw-authority-request v1"

# HOW LONG AN APPROVAL MAY STAY APPLICABLE, and it is a constant of the DOOR for
# the same reason the namespace is. `payload/claw-authority` carries this number
# too and refuses to draft past it, and that copy binds nobody: the drafting
# program holds no privilege, appears in no sudo grant, and nothing requires
# anybody to use it. A request is a short text document a person can type.
#
# So the bound the firm was told about lived only where it could be walked
# around. This door checked that the window had CLOSED and never that the window
# was BOUNDED, which let a hand-written request stay applicable for ten years and
# apply without a word. The signer is shown a timestamp and is left to do the
# arithmetic themselves; this is the line that does it for them.
MAX_DAYS=30

# A person signs on their own device and a claw keeps its own clock, so the two
# do not hold the same second. This is the allowance, and it is small and named
# rather than folded silently into the bound above. It is spent in two places: a
# `drafted-at` that reads as slightly ahead of this claw, and the top of the
# window, because the drafter writes its two timestamps with two separate reads
# of the clock and a request drafted for exactly thirty days must not be refused
# over the second that passed between them.
MAX_CLOCK_SKEW=300

GROUP_MEMBERS="claw-members"
GROUP_ADMIN="claw-admin"

MAX_SCRIPT_BYTES=262144
MAX_REQ_BYTES=16384
MAX_SIG_BYTES=16384
# A bound on the registry, so a file somebody filled cannot turn a verification
# into a walk. A firm's roster is people, not thousands.
MAX_SIGNER_LINES=256

# THE REPLAY LEDGER GETS ITS OWN BOUND, AND IT IS MUCH LARGER THAN THE REGISTRY'S.
# The ledger holds one line per request this claw has ever applied, so it grows
# for as long as the claw is used, while the registry holds people. Giving the
# ledger the roster's 256 would be a guard that refuses every act on a claw that
# had simply been running a while: it would halt the thing it exists to protect,
# and the firm would read the refusal as an attack. This number is a ceiling on a
# file nobody should be able to make enormous, not a limit on ordinary use.
MAX_SEEN_LINES=65536

# The wrapper template, resolved one directory up from this script exactly as
# the scaffold resolves its own templates. A door installed without it would be
# a grant with nothing behind it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER_TEMPLATE="${SCRIPT_DIR}/../templates/tenant-door-wrapper.sh"

# WHICH WRAPPER, PINNED. This door used to install the template and then satisfy
# itself by comparing the installed path against the template it had just copied.
# That control can only ever catch a copy that failed. It says nothing about
# whether the bytes are the wrapper this release ships, which is what its own
# words claimed and what a reader counting it as evidence would believe.
#
# So the identity of the wrapper is a number carried here, checked before the
# copy and read back after it. A tampered template is now refused instead of
# installed and blessed.
#
# WHEN THE WRAPPER CHANGES THIS NUMBER CHANGES WITH IT, and a rig control holds
# the two together so that a wrapper edited without it goes red here rather than
# on a firm's claw. `provision-claw.sh` phase 18 carries the same constant for
# the same reason the namespace and the day bound are carried twice: the two
# programs lay the same file and each must be able to refuse alone.
WRAPPER_SHA256="95a492ed7f583208f3f8c048865a8ce5cfe30db504a91711a37649759d3a6aa4"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

# `shift N` returns non-zero when fewer than N arguments remain, and under
# `set -e` that ends the script with status 1 and NOTHING printed. A caller who
# typed half the arguments would get silence and a failure code, so the count is
# checked first and the miss is named.
need() {
  [ "$1" -ge "$2" ] || { printf '%s needs %s value(s)\n' "$3" "$(( $2 - 1 ))" >&2; usage; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   need $# 4 "--apply <operation> <request> <signature>"
               MODE="apply"; OPERATION="$2"; REQ_FILE="$3"; SIG_FILE="$4"; shift 4 ;;
    --script)  need $# 2 "--script <path>"; SRC_SCRIPT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; SIGNER=""; SIGNER_TIER=""; SUBJECT=""; REQUEST_ID=""
DOOR_NAME=""; DOOR_GROUP=""; DOOR_SHA=""; PERSON=""; PERSON_KEY=""
WORK=""

say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  OK    %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(true); return 0; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; CHK_DESC+=("$*"); CHK_OK+=(false); FAILED=1; return 0; }
warn() { printf '  note  %s\n' "$*" >&2; NOTES+=("$*"); return 0; }

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_json() {
  local i first
  printf '{\n'
  printf '  "script": "manage-claw-authority",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "operation": "%s",\n' "$(json_esc "$OPERATION")"
  printf '  "request_id": "%s",\n' "$(json_esc "$REQUEST_ID")"
  printf '  "approved_by": "%s",\n' "$(json_esc "$SIGNER")"
  printf '  "approved_tier": "%s",\n' "$(json_esc "$SIGNER_TIER")"
  printf '  "subject": "%s",\n' "$(json_esc "$SUBJECT")"
  printf '  "action": "%s",\n' "$(json_esc "$ACTION")"
  printf '  "checks": [\n'
  for i in "${!CHK_DESC[@]}"; do
    printf '    {"check": "%s", "ok": %s}' "$(json_esc "${CHK_DESC[$i]}")" "${CHK_OK[$i]}"
    [ "$i" -lt $(( ${#CHK_DESC[@]} - 1 )) ] && printf ','
    printf '\n'
  done
  printf '  ],\n'
  printf '  "failed_checks": ['
  first=1
  for i in "${!CHK_DESC[@]}"; do
    [ "${CHK_OK[$i]}" = "false" ] || continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "${CHK_DESC[$i]}")"; first=0
  done
  printf '],\n'
  printf '  "notes": ['
  first=1
  for i in "${NOTES[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "$i")"; first=0
  done
  printf ']\n}\n'
}

finish() { emit_json; [ "$FAILED" -eq 0 ] || exit 1; exit 0; }

members_of() { getent group "$1" 2>/dev/null | cut -d: -f4 | tr ',' ' ' | xargs || true; }

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { say "run this as root"; exit 1; }

[ "$MODE" = "apply" ] || { say "pick a mode: --apply <operation> <request> <signature>"; usage; }

case "$OPERATION" in
  grant-door|revoke-door|add-admin|remove-admin|transfer-owner) : ;;
  *) say "'${OPERATION}' is not an operation. Pick one: grant-door, revoke-door, add-admin, remove-admin, transfer-owner."; exit 1 ;;
esac

if [ "$OPERATION" != "grant-door" ] && [ -n "$SRC_SCRIPT" ]; then
  say "--script belongs to a grant-door. A ${OPERATION} installs no bytes, so there is nothing for it to name."
  exit 1
fi

# ---- the two files the caller handed over ----
#
# READ BEFORE ANYTHING IS BELIEVED. Both are caller-supplied paths and this
# process is root, so the shape of the path is checked before its contents are.
# These are checks on the NAME, and they run here because a name has to be safe
# to open before anything opens it. Every check on the CONTENTS runs below, on
# this door's own copy, for the reason the copy exists.
for f in "$REQ_FILE" "$SIG_FILE"; do
  [ -e "$f" ] || { say "no such file: '${f}'"; exit 1; }
  [ ! -L "$f" ] || { say "REFUSED: '${f}' is a symlink. Name the file itself; a link is a name for bytes that can change under it."; exit 1; }
  [ -f "$f" ] || { say "REFUSED: '${f}' is not a regular file."; exit 1; }
done

# ---- the registry ----
#
# ITS ABSENCE IS A REFUSAL, NOT AN INVITATION. A claw with no registry has no
# owner, and a door that laid one here would be a door that appointed the firm's
# owner from whoever ran it. Provisioning lays the registry, once, from the
# person the firm named.
[ -d "$AUTHORITY_ROOT" ] || {
  say "REFUSED: no authority registry at ${AUTHORITY_ROOT}, so nothing on this claw says who may approve anything."
  say "Provisioning lays it. Run the provisioning plane rather than creating it here."
  exit 1
}
[ -f "$OWNER_FILE" ] || {
  say "REFUSED: no owner recorded at ${OWNER_FILE}."
  say "Every claw with a registry has exactly one owner, and this door will not appoint one -- an owner appointed by whoever ran a script is not an owner."
  exit 1
}
[ -s "$OWNER_FILE" ] || {
  say "REFUSED: ${OWNER_FILE} is empty. An empty owner file is not 'no owner yet'; it is a registry somebody emptied, and reading authority out of it would be reading a grant out of a blank page."
  exit 1
}

[ -f "$ADMIN_LOG" ] || {
  say "REFUSED: no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down."
  say "The log is seeded by provisioning. Run the provisioning plane rather than creating it here."
  exit 1
}

getent group "$MEMBERS_GROUP" >/dev/null 2>&1 || {
  say "REFUSED: no ${MEMBERS_GROUP} group on this claw, so nothing here says who the people are."
  exit 1
}
MEMBERS_LIST="$(members_of "$MEMBERS_GROUP")"
[ -n "$MEMBERS_LIST" ] || {
  say "REFUSED: ${MEMBERS_GROUP} lists nobody on this claw."
  say "Identity on this plane is that group. An empty one means no person was onboarded through the door, so there is nobody for a tier to describe."
  exit 1
}

BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac

WORK="$(mktemp -d)"; chmod 0700 "$WORK"
cleanup() { rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------- one read
#
# ONE READ OF EACH CALLER-CONTROLLED PATH, and it is the law this file already
# states thirty lines further down for the door script. It was not being applied
# to the document that carries the authority.
#
# WHAT WENT WRONG WITHOUT IT. The request was PARSED from the caller's path into
# the array this door acts on, and then `ssh-keygen -Y verify` opened that same
# path and read it a second time. Between the two reads sat the field-set
# comparison, the claw check, the deadline parse, the replay lookup, two registry
# validations and a fork of `find-principals`. The path belongs to the caller, so
# a caller who replaced the file inside that window had the signature checked over
# one document and the act taken from another: an operation nobody approved,
# carrying the tier of whoever signed the document that was shown. The signature
# file has the same shape -- searched for a principal, then read again by verify.
#
# So both are copied here, above the parse, into the 0700 directory this door
# already opens, and everything below acts on the copies. The caller can swap
# whatever they like afterwards; what this door parsed and what it verified are
# the same bytes, because they are the same file and nothing else can reach it.
#
# THE ORIGINAL PATHS ARE KEPT for messages only. A refusal that named a path
# under /tmp would be telling somebody about a file they cannot look at.
REQ_PATH="$REQ_FILE"; SIG_PATH="$SIG_FILE"
cp -- "$REQ_FILE" "${WORK}/request"   || { say "REFUSED: could not read '${REQ_PATH}'."; exit 1; }
cp -- "$SIG_FILE" "${WORK}/signature" || { say "REFUSED: could not read '${SIG_PATH}'."; exit 1; }
REQ_FILE="${WORK}/request"; SIG_FILE="${WORK}/signature"

# THE BOUNDS ARE MEASURED ON THE COPY, and that is the whole point of measuring
# them here rather than beside the name checks above. A size read from a path the
# caller still owns is a size for bytes this door is not going to read. These are
# the bytes it reads.
[ "$(stat -c %s "$REQ_FILE")" -le "$MAX_REQ_BYTES" ] || { say "REFUSED: the request is larger than ${MAX_REQ_BYTES} bytes. A request is a short document."; exit 1; }
[ "$(stat -c %s "$SIG_FILE")" -le "$MAX_SIG_BYTES" ] || { say "REFUSED: the signature is larger than ${MAX_SIG_BYTES} bytes."; exit 1; }
[ "$(stat -c %s "$SIG_FILE")" -gt 0 ] || { say "REFUSED: the signature file is empty. An empty file is not an unsigned request being tolerated; it is a request with nothing approving it."; exit 1; }

# ---------------------------------------------------------------- the document
#
# STRICT, AND STRICT IS THE POINT. Every line is interpreted or the document is
# refused: unknown field, repeated field, missing field, blank line, stray text.
# A signer reads the document they sign, so a line this door ignores is a line
# somebody was shown and the machine was not bound by.

req_line_count="$(grep -c '' "$REQ_FILE" 2>/dev/null || echo 0)"
[ "$req_line_count" -ge 8 ] || { say "REFUSED: the request holds ${req_line_count} lines. It is not a request this door can read."; exit 1; }

first_line="$(head -1 "$REQ_FILE")"
[ "$first_line" = "$DOC_VERSION" ] || {
  say "REFUSED: the request does not begin with '${DOC_VERSION}'."
  say "It begins with '${first_line}'. A document of another version is refused rather than guessed at, because a field this door read under the wrong rules is a field the signer did not agree to."
  exit 1
}

declare -A F=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno+1))
  [ "$lineno" -eq 1 ] && continue
  case "$line" in
    '') say "REFUSED: the request carries a blank line at line ${lineno}. Every line in a signed document is read, so an empty one is refused rather than skipped."; exit 1 ;;
    *": "*) : ;;
    *) say "REFUSED: line ${lineno} of the request is not a 'field: value' line: '${line}'"; exit 1 ;;
  esac
  key="${line%%: *}"
  val="${line#*: }"
  case "$key" in
    *[!a-z0-9-]*) say "REFUSED: '${key}' at line ${lineno} is not a field name this document format uses."; exit 1 ;;
  esac
  [ -z "${F[$key]+set}" ] || { say "REFUSED: the request names '${key}' more than once. A repeated field has two readings and the signer only agreed to one."; exit 1; }
  [ -n "$val" ] || { say "REFUSED: '${key}' at line ${lineno} carries no value."; exit 1; }
  F[$key]="$val"
done < "$REQ_FILE"

# ---- the operation the caller typed and the operation the signer signed ----
#
# ASKED BEFORE THE FIELD SET, because which fields a document should carry is
# decided by which operation it is. With the order the other way round, applying
# a grant-door under the wrong flag reports a field list that does not match --
# which is true, and useless: the caller reads a parse error where the answer is
# that they named the wrong operation.
[ -n "${F[operation]+set}" ] || { say "REFUSED: the request names no operation."; exit 1; }
[ "${F[operation]}" = "$OPERATION" ] || {
  say "REFUSED: you asked to apply a ${OPERATION} and the signed document is a ${F[operation]}."
  say "The signature covers the document, so applying it under another name would be running an operation nobody approved."
  exit 1
}

# The fields every request carries, and then the ones this operation carries.
# The union is compared as a SET against what the document holds, so an extra
# field fails just as loudly as a missing one.
COMMON_FIELDS="claw operation request-id drafted-by drafted-at not-after"
case "$OPERATION" in
  grant-door)     OP_FIELDS="name group sha256" ;;
  revoke-door)    OP_FIELDS="name" ;;
  add-admin)      OP_FIELDS="person key" ;;
  remove-admin)   OP_FIELDS="person" ;;
  transfer-owner) OP_FIELDS="person key" ;;
esac
WANT_FIELDS="$(printf '%s %s' "$COMMON_FIELDS" "$OP_FIELDS" | tr ' ' '\n' | LC_ALL=C sort)"
HAVE_FIELDS="$(printf '%s\n' "${!F[@]}" | LC_ALL=C sort)"
[ "$WANT_FIELDS" = "$HAVE_FIELDS" ] || {
  say "REFUSED: the request's fields are not the fields a ${OPERATION} carries."
  say "  it holds:   $(printf '%s' "$HAVE_FIELDS" | tr '\n' ' ')"
  say "  it needs:   $(printf '%s' "$WANT_FIELDS" | tr '\n' ' ')"
  exit 1
}

# ---- this claw ----
THIS_CLAW="$(hostname)"
[ "${F[claw]}" = "$THIS_CLAW" ] || {
  say "REFUSED: the request names claw '${F[claw]}' and this claw is '${THIS_CLAW}'."
  say "An approval is for one machine. The same signature arriving on a second claw is the case this line exists for."
  exit 1
}

# ---- the deadline ----
#
# The comparison is on the parsed epoch, never on the strings. Two timestamps
# compared as text agree with a real comparison right up to the digit that
# changes width, which is the comparison this bound turns on.
NOT_AFTER_EPOCH="$(date -u -d "${F[not-after]}" +%s 2>/dev/null || true)"
[ -n "$NOT_AFTER_EPOCH" ] || { say "REFUSED: '${F[not-after]}' is not a timestamp this door can read."; exit 1; }
DRAFTED_EPOCH="$(date -u -d "${F[drafted-at]}" +%s 2>/dev/null || true)"
[ -n "$DRAFTED_EPOCH" ] || { say "REFUSED: '${F[drafted-at]}' is not a timestamp this door can read."; exit 1; }
NOW_EPOCH="$(date -u +%s)"

# HAS THE WINDOW CLOSED. Asked first because it is the question the person
# holding the document is most likely to have got wrong, and it deserves its own
# answer rather than a complaint about the shape of their timestamps.
[ "$NOW_EPOCH" -le "$NOT_AFTER_EPOCH" ] || {
  say "REFUSED: this request stopped being applicable at ${F[not-after]} and it is now $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  say "Draft it again and have it signed again. An approval with no deadline is an approval nobody remembers giving."
  exit 1
}

# IS THE WINDOW BOUNDED. A different question from the one above, and the one
# this door was not asking.
#
# The span is measured from `drafted-at` rather than from now, because now moves
# and the document does not: measuring from now would make the same bytes legal
# for thirty days every day somebody re-ran them. `drafted-at` is inside the
# signed bytes, so a drafter cannot stretch the window after the signature and a
# signer can see both numbers they are agreeing to.
[ "$DRAFTED_EPOCH" -le $(( NOW_EPOCH + MAX_CLOCK_SKEW )) ] || {
  say "REFUSED: the request says it was drafted at ${F[drafted-at]} and it is now $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  say "A drafting time in the future is what a document looks like when the window below is being measured from a moment that has not happened yet."
  exit 1
}
REQ_SPAN_DAYS=$(( ( NOT_AFTER_EPOCH - DRAFTED_EPOCH + 86399 ) / 86400 ))
[ $(( NOT_AFTER_EPOCH - DRAFTED_EPOCH )) -le $(( MAX_DAYS * 86400 + MAX_CLOCK_SKEW )) ] || {
  say "REFUSED: this request is drafted to stay applicable for ${REQ_SPAN_DAYS} days, and this claw's bound is ${MAX_DAYS}."
  say "  drafted at: ${F[drafted-at]}"
  say "  not after:  ${F[not-after]}"
  say "An approval that outlives everybody's memory of giving it is the thing the deadline exists to prevent, so the length of the window is checked here rather than left to whoever reads the timestamps."
  exit 1
}
# A `not-after` BEHIND `drafted-at` gets no line of its own, deliberately: it
# cannot reach here. The expiry check above refuses anything whose `not-after` is
# behind now, and the skew check refuses a `drafted-at` ahead of now, so the two
# together leave no document where the second timestamp precedes the first. A
# guard written for it would be a guard that cannot fire.

# ---- the request id, used once ----
REQUEST_ID="${F[request-id]}"
case "$REQUEST_ID" in
  *[!0-9A-Za-z-]*) say "REFUSED: '${REQUEST_ID}' is not a usable request id."; exit 1 ;;
esac
[ "${#REQUEST_ID}" -le 64 ] || { say "REFUSED: the request id is longer than 64 characters."; exit 1; }
# THE REPLAY LOOKUP ITSELF IS BELOW, beside the registry validations rather than
# here. The ledger it reads is a file in the registry's own directory and it now
# gets the registry's own checks, and a file has to be validated before it is
# read rather than after. Order the refusals the way the reader expects them too:
# a claw whose registry is broken says so first.

# ---------------------------------------------------------------- the signature
#
# TWO STEPS, AND BOTH ARE NEEDED. `find-principals` answers which identity in a
# registry file holds the key that made this signature; it says nothing about
# whether the signature covers these bytes. `verify` is what checks the bytes and
# the namespace. Either one alone is a check that passes on the case it exists to
# catch.
#
# THE OWNER FILE IS TRIED FIRST, so the tier a signature carries is decided by
# which registry file holds the key rather than by anything in the document. A
# document cannot claim a tier, because a document is written by whoever drafted
# it and the drafter is not the authority.

# THE REGISTRY IS VALIDATED AT THE TOP LEVEL, NEVER INSIDE A SUBSTITUTION, and
# this is not a style preference. An `exit` inside `$( )` ends the subshell and
# leaves the caller running with an empty answer, so a refusal written there is a
# comment: the door would read "no principal found" where the registry was a
# symlink and refuse for the wrong reason, or worse, take the next file's answer.
# This door's own rig caught exactly that, with the symlink refusal reported as a
# missing key.
validate_signer_file() {   # validate_signer_file <file> required|optional <max-lines>
  local file="$1" required="$2" max="$3" lines
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    [ "$required" = "optional" ] && return 0
    say "REFUSED: ${file} is missing."; exit 1
  fi
  [ ! -L "$file" ] || { say "REFUSED: ${file} is a symlink. The registry is a file, not a name for one."; exit 1; }
  [ -f "$file" ] || { say "REFUSED: ${file} is not a regular file."; exit 1; }
  [ "$(stat -c %U "$file")" = "root" ] || {
    say "REFUSED: ${file} is owned by $(stat -c %U "$file"), not by root. A registry its subject can edit is not a registry."
    exit 1
  }
  lines="$(grep -c '' "$file" 2>/dev/null || true)"
  [ "${lines:-0}" -le "$max" ] || {
    say "REFUSED: ${file} holds ${lines} lines, past the ${max} this door reads. Look at it by hand."
    exit 1
  }
  return 0
}

validate_signer_file "$OWNER_FILE" required "$MAX_SIGNER_LINES"
validate_signer_file "$ADMINS_FILE" optional "$MAX_SIGNER_LINES"

# THE LEDGER IS A REGISTRY FILE AND IS NOW TREATED AS ONE. `requests-seen` sits
# in the same root-owned directory as `owner` and `admins`, it decides whether a
# signed document may be applied again, and it was read with a bare test and a
# grep while the two files beside it were checked for being a symlink, a regular
# file, root-owned and bounded.
#
# What that cost is the same shape as every other guard this door has had to
# repair: a ledger pointed somewhere unreadable answered "not seen before" for
# every request, so a document already spent could be applied again, and the only
# thing that noticed was a read-back AFTER the act. A guard that reports an act
# it could not stop is not a guard. This one refuses before anything is read from
# it.
#
# OPTIONAL, because a claw that has applied nothing has no ledger yet, and the
# first request must be able to land. Absence is a state; a symlink is a lie.
validate_signer_file "$SEEN_FILE" optional "$MAX_SEEN_LINES"

# EXACTLY ONE OWNER, CHECKED HERE RATHER THAN ASSUMED. A claw has one owner: the
# provisioning run lays one and a transfer writes one, so the shipped paths
# cannot produce a second. A registry repaired by hand can, and this door read
# only the first line of the file, so the second person would be invisible to the
# refusal that stops the owner being made an admin -- and would end up holding
# two tiers, which is the one thing the roster must never say about somebody.
#
# The file legitimately holds several LINES for one person, one per key they
# have, so the count is of people and not of lines.
OWNER_COUNT="$(awk '!/^#/ && NF {print $1}' "$OWNER_FILE" | LC_ALL=C sort -u | grep -c '' || true)"
[ "${OWNER_COUNT:-0}" -eq 1 ] || {
  say "REFUSED: ${OWNER_FILE} names ${OWNER_COUNT} people, and a claw has exactly one owner."
  say "This door reads the first of them and every tier check it makes would be about that one, so it refuses rather than picking. Somebody edited the registry by hand; look at the file."
  exit 1
}

# ---- the request id, looked up now that the ledger has been validated ----
if [ -f "$SEEN_FILE" ] && grep -qxF "$REQUEST_ID" "$SEEN_FILE"; then
  say "REFUSED: request ${REQUEST_ID} was already applied on this claw."
  say "A signed document stays valid bytes forever, so replaying one is how a decision somebody reversed comes back. Draft a new request."
  exit 1
fi

principals_in() {   # principals_in <signers-file> -> every identity holding the signing key
  [ -s "$1" ] || return 0
  ssh-keygen -Y find-principals -s "$SIG_FILE" -f "$1" 2>/dev/null || true
}

SIGNER_HITS="$(principals_in "$OWNER_FILE")"
if [ -n "$SIGNER_HITS" ]; then
  SIGNER_TIER="owner"; SIGNER_FILE="$OWNER_FILE"
else
  SIGNER_HITS="$(principals_in "$ADMINS_FILE")"
  [ -z "$SIGNER_HITS" ] || { SIGNER_TIER="admin"; SIGNER_FILE="$ADMINS_FILE"; }
fi

if [ -n "$SIGNER_HITS" ]; then
  # One identity. A key listed under two of them is a registry somebody has to
  # fix by hand, and taking the first would take it silently.
  [ "$(printf '%s\n' "$SIGNER_HITS" | grep -c '')" -eq 1 ] || {
    say "REFUSED: the key that made this signature appears in ${SIGNER_FILE} under more than one identity."
    exit 1
  }
  SIGNER="$SIGNER_HITS"
fi

[ -n "$SIGNER" ] || {
  say "REFUSED: the key that made this signature is not in this claw's authority registry."
  say "Only the owner and the admins can approve anything here. A member's own key opens their login and speaks for nobody."
  say "Run 'claw-authority --list' to see who this claw listens to."
  exit 1
}

ssh-keygen -Y verify -f "$SIGNER_FILE" -I "$SIGNER" -n "$NAMESPACE" -s "$SIG_FILE" < "$REQ_FILE" >/dev/null 2>&1 || {
  say "REFUSED: the signature does not verify over these bytes."
  say "The key belongs to ${SIGNER}, so the key is known. What failed is the signature over this document: it was made over different bytes, or under a different namespace, or the document has been edited since."
  say "The namespace this claw accepts is ${NAMESPACE}."
  exit 1
}
ok "signature verifies: ${SIGNER}, tier ${SIGNER_TIER}, over the exact bytes of ${REQ_PATH}"

# ---- what this tier may do ----
#
# THE ROSTER IS THE OWNER'S ALONE. An admin holds every door power and no roster
# power, and this is the line that makes "an admin cannot appoint an admin" a
# property of the machine rather than a sentence in a document.
case "$OPERATION" in
  add-admin|remove-admin|transfer-owner)
    [ "$SIGNER_TIER" = "owner" ] || {
      say "REFUSED: ${SIGNER} is an admin, and ${OPERATION} is the owner's alone."
      say "Admins approve doors. They do not change who holds authority here, because a tier that can widen itself is not a tier."
      exit 1
    }
    ok "${OPERATION} carries the owner's own signature"
    ;;
  grant-door|revoke-door)
    ok "a door decision takes one signature from the owner or an admin, and this one carries ${SIGNER_TIER}'s"
    ;;
esac

# ---------------------------------------------------------------- the subject

check_door_name() {   # check_door_name <value>
  case "$1" in
    [a-z]*) : ;;
    *) say "REFUSED: '$1' is not a door name: it must start with a lowercase letter."; exit 1 ;;
  esac
  case "$1" in
    *[!a-z0-9-]*) say "REFUSED: '$1' is not a door name: lowercase letters, digits and hyphen only."; exit 1 ;;
  esac
  [ "${#1}" -le 48 ] || { say "REFUSED: '$1' is longer than 48 characters."; exit 1; }
}

check_unix_name() {   # check_unix_name <value>
  case "$1" in
    [a-z]*) : ;;
    *) say "REFUSED: '$1' is not a usable username: it must start with a lowercase letter."; exit 1 ;;
  esac
  case "$1" in
    *[!a-z0-9_-]*) say "REFUSED: '$1' is not a usable username: lowercase letters, digits, hyphen and underscore only."; exit 1 ;;
  esac
  [ "${#1}" -le 32 ] || { say "REFUSED: '$1' is longer than 32 characters."; exit 1; }
}

# A key line as it will be written into an allowed-signers file. It goes in
# beside a principal, so anything that could end the principal field or start a
# second line is refused rather than escaped.
check_key_line() {   # check_key_line <value>
  local line="$1" type ok=0 t
  local types=("ssh-ed25519" "ecdsa-sha2-nistp256" "sk-ssh-ed25519@openssh.com" "sk-ecdsa-sha2-nistp256@openssh.com")
  case "$line" in
    *"PRIVATE KEY"*|*"BEGIN OPENSSH"*)
      say "REFUSED: the request carries what looks like a PRIVATE key. Nothing about this design needs one, and the registry is world-readable."
      exit 1 ;;
  esac
  case "$line" in
    *$'\n'*|*$'\r'*|*$'\t'*) say "REFUSED: the key in the request carries a line break or a tab."; exit 1 ;;
  esac
  type="${line%% *}"
  for t in "${types[@]}"; do [ "$type" = "$t" ] && { ok=1; break; }; done
  [ "$ok" = 1 ] || { say "REFUSED: '${type}' is not a key type this claw accepts. Accepted: ${types[*]}"; exit 1; }
  printf '%s\n' "$line" > "${WORK}/keyline"
  ssh-keygen -l -f "${WORK}/keyline" >/dev/null 2>&1 || {
    say "REFUSED: the key in the request is not a public key the key tool can read."
    exit 1
  }
}

case "$OPERATION" in
  grant-door|revoke-door)
    DOOR_NAME="${F[name]}"
    check_door_name "$DOOR_NAME"
    SUBJECT="$DOOR_NAME"
    ;;
  add-admin|remove-admin|transfer-owner)
    PERSON="${F[person]}"
    check_unix_name "$PERSON"
    SUBJECT="$PERSON"
    ;;
esac

if [ "$OPERATION" = "grant-door" ]; then
  DOOR_GROUP="${F[group]}"
  case "$DOOR_GROUP" in
    "$GROUP_MEMBERS"|"$GROUP_ADMIN") : ;;
    *) say "REFUSED: '${DOOR_GROUP}' is not a group a door may be granted to. This claw grants to ${GROUP_MEMBERS} or ${GROUP_ADMIN} and to nothing else."; exit 1 ;;
  esac
  getent group "$DOOR_GROUP" >/dev/null 2>&1 || { say "REFUSED: no ${DOOR_GROUP} group on this claw."; exit 1; }
  DOOR_SHA="${F[sha256]}"
  case "$DOOR_SHA" in
    *[!0-9a-f]*) say "REFUSED: the sha256 in the request is not lowercase hex."; exit 1 ;;
  esac
  [ "${#DOOR_SHA}" -eq 64 ] || { say "REFUSED: the sha256 in the request is ${#DOOR_SHA} characters; a sha256 is 64."; exit 1; }

  # The name may not shadow a door this claw already carries from the vendor
  # plane. Two different scripts answering to one name is the confusion a grant
  # cannot afford, and the vendor plane's names are not the tenant's to take.
  if [ -e "${OPT_ROOT}/provision-claw/scripts/${DOOR_NAME}.sh" ]; then
    say "REFUSED: '${DOOR_NAME}' is the name of a script on the vendor plane. Pick another."
    exit 1
  fi
fi

if [ "$OPERATION" = "add-admin" ] || [ "$OPERATION" = "transfer-owner" ]; then
  PERSON_KEY="${F[key]}"
  check_key_line "$PERSON_KEY"
fi

# ---- a tier describes a person who exists here ----
if [ -n "$PERSON" ]; then
  getent passwd "$PERSON" >/dev/null 2>&1 || {
    say "REFUSED: no such person on this claw: '${PERSON}'."
    say "A tier is a fact about somebody with a login here. This door creates nobody -- that is the onboarding door."
    exit 1
  }
  case " $(id -nG "$PERSON" 2>/dev/null || true) " in
    *" ${MEMBERS_GROUP} "*) : ;;
    *) say "REFUSED: '${PERSON}' is not in ${MEMBERS_GROUP}, so they are not a person this claw onboarded."
       say "Run the onboarding door first."
       exit 1 ;;
  esac
fi

# ---------------------------------------------------------------- the source bytes

OWNER_PRINCIPAL="$(awk '!/^#/ && NF {print $1; exit}' "$OWNER_FILE")"

if [ "$OPERATION" = "grant-door" ]; then
  [ -n "$SRC_SCRIPT" ] || {
    say "REFUSED: a grant-door needs --script <path>: the file whose bytes were approved."
    say "The request carries the hash of those bytes. This door will not install anything whose hash differs from it, so the file has to be here."
    exit 1
  }
  [ ! -L "$SRC_SCRIPT" ] || { say "REFUSED: '${SRC_SCRIPT}' is a symlink. Name the file whose bytes were approved."; exit 1; }
  [ -f "$SRC_SCRIPT" ] || { say "REFUSED: '${SRC_SCRIPT}' is not a regular file."; exit 1; }
  [ "$(stat -c %h "$SRC_SCRIPT")" = "1" ] || {
    say "REFUSED: '${SRC_SCRIPT}' carries $(stat -c %h "$SRC_SCRIPT") hard links, so another path on this claw is the same bytes."
    exit 1
  }
  SRC_SIZE="$(stat -c %s "$SRC_SCRIPT")"
  [ "$SRC_SIZE" -gt 0 ] || { say "REFUSED: '${SRC_SCRIPT}' is empty."; exit 1; }
  [ "$SRC_SIZE" -le "$MAX_SCRIPT_BYTES" ] || {
    say "REFUSED: '${SRC_SCRIPT}' is ${SRC_SIZE} bytes, past the ${MAX_SCRIPT_BYTES} a door may be. A door is an operation, not a payload."
    exit 1
  }
  case "$(cd "$(dirname "$SRC_SCRIPT")" && pwd -P)/" in
    "${WORKSPACE_ROOT}"/*) : ;;
    *) say "REFUSED: '${SRC_SCRIPT}' is outside ${WORKSPACE_ROOT}."
       say "A door is drafted in the tenant's own plane. That plane is where members write, and it is the plane the backup rail keeps, so the source of an approved door survives a restore."
       exit 1 ;;
  esac

  # THE DOOR INSTALLS ONLY BYTES ITS CALLER COULD ALREADY READ. This process is
  # root and the path came from the caller, so without this line a member could
  # have any file root can read installed as a door and run it. The hash in the
  # request does not close it: a signer approving a hash is shown a hash, and a
  # hash of /etc/shadow looks like a hash of anything else.
  if [ "$BY" != "root" ]; then
    runuser -u "$BY" -- test -r "$SRC_SCRIPT" 2>/dev/null || {
      say "REFUSED: ${BY} cannot read '${SRC_SCRIPT}'."
      say "This door installs only bytes its caller could already read, because it reads them as root and a signer approving a hash cannot see what the bytes are."
      exit 1
    }
    ok "the caller ${BY} can read the source themselves, so root is not reading something on their behalf"
  else
    warn "the caller is root directly rather than through sudo, so the read-as-the-caller control did not run. An unrun control is not a passed one."
  fi

  # ONE READ. The bytes are copied once, and the copy is what gets hashed and
  # what gets installed. Hashing the caller's path and then installing from it
  # again would be two reads of a file the caller controls, with a window
  # between them.
  cp -- "$SRC_SCRIPT" "${WORK}/candidate" || { say "REFUSED: could not read '${SRC_SCRIPT}'."; exit 1; }
  GOT_SHA="$(sha256sum "${WORK}/candidate" | cut -d' ' -f1)"
  [ "$GOT_SHA" = "$DOOR_SHA" ] || {
    say "REFUSED: THE BYTES ARE NOT THE BYTES ANYBODY APPROVED."
    say "  approved: ${DOOR_SHA}"
    say "  found:    ${GOT_SHA}"
    say "Nothing was installed. The file has changed since the request was drafted, or it is a different file."
    exit 1
  }
  ok "the source bytes hash to exactly what ${SIGNER} approved"

  [ -r "$WRAPPER_TEMPLATE" ] || {
    say "REFUSED: the wrapper template is missing at ${WRAPPER_TEMPLATE}."
    say "A granted door is the wrapper; without it a grant would name a path with nothing behind it."
    exit 1
  }

  # THE WRAPPER IS CHECKED BEFORE IT IS INSTALLED, against the number this door
  # carries. Every granted door on this claw is a copy of this one file, and it
  # is the file that re-checks the approved hash and writes the member-plane row.
  # Bytes that are not it are a door with no hash check and no row, wearing the
  # name of one that has both.
  WRAPPER_GOT_SHA="$(sha256sum "$WRAPPER_TEMPLATE" | cut -d' ' -f1)"
  [ "$WRAPPER_GOT_SHA" = "$WRAPPER_SHA256" ] || {
    say "REFUSED: the wrapper template at ${WRAPPER_TEMPLATE} is not the wrapper this release ships."
    say "  expected: ${WRAPPER_SHA256}"
    say "  found:    ${WRAPPER_GOT_SHA}"
    say "Nothing was installed. Either this claw's provisioning tree was tampered with, or it is a release whose wrapper changed without this door being told."
    exit 1
  }
  ok "the wrapper template is the one this release ships"
fi

# ---------------------------------------------------------------- what would change

is_admin_principal() {   # is_admin_principal <person>
  [ -f "$ADMINS_FILE" ] || return 1
  awk -v p="$1" '!/^#/ && NF && $1 == p {found=1} END {exit found?0:1}' "$ADMINS_FILE"
}

case "$OPERATION" in
  grant-door)
    if [ -f "${DOORS_DIR}/${DOOR_NAME}.json" ]; then
      HAD_SHA="$(sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p' "${DOORS_DIR}/${DOOR_NAME}.json" | head -1)"
      HAD_GROUP="$(sed -n 's/.*"group": *"\([^"]*\)".*/\1/p' "${DOORS_DIR}/${DOOR_NAME}.json" | head -1)"
      if [ "$HAD_SHA" = "$DOOR_SHA" ] && [ "$HAD_GROUP" = "$DOOR_GROUP" ]; then
        ACTION="unchanged"
      else
        ACTION="replaced"
        warn "'${DOOR_NAME}' already exists on this claw and this approval replaces it. Was ${HAD_SHA} for ${HAD_GROUP}."
      fi
    else
      ACTION="granted"
    fi
    ;;
  revoke-door)
    if [ -f "${DOORS_DIR}/${DOOR_NAME}.json" ]; then ACTION="revoked"; else ACTION="unchanged"; fi
    ;;
  add-admin)
    if [ "$PERSON" = "$OWNER_PRINCIPAL" ]; then
      say "REFUSED: ${PERSON} is this claw's owner. The owner already holds everything an admin holds, and a person sitting in two tiers is a roster with two answers about them."
      exit 1
    fi
    if is_admin_principal "$PERSON" && grep -qxF "${PERSON} ${PERSON_KEY}" "$ADMINS_FILE"; then
      ACTION="unchanged"
    elif is_admin_principal "$PERSON"; then
      ACTION="added-key"
    else
      ACTION="added"
    fi
    ;;
  remove-admin)
    if is_admin_principal "$PERSON"; then ACTION="removed"; else ACTION="unchanged"; fi
    ;;
  transfer-owner)
    if [ "$PERSON" = "$OWNER_PRINCIPAL" ] && grep -qxF "${PERSON} ${PERSON_KEY}" "$OWNER_FILE"; then
      ACTION="unchanged"
    else
      ACTION="transferred"
    fi
    ;;
esac

# ---------------------------------------------------------------- the sudoers file
#
# THE TENANT'S GRANTS LIVE IN THEIR OWN DROP-IN, NEVER IN THE VENDOR'S. A
# provisioning run rewrites `commonclaw-claw-admin` on every ride, so a tenant
# grant written into that file would be erased by the next release with nothing
# telling the firm. Two files, two writers, and neither touches the other's.
#
# IT IS REGENERATED FROM THE REGISTRY, NEVER APPENDED TO. A revoke has to be able
# to remove a line, and a file built by appending has no way to. The registry is
# the truth and this file is derived from it, which also means a hand-edit here
# is undone by the next act rather than surviving quietly.
#
# IT IS COMPOSED AND PARSED BEFORE ANYTHING IS INSTALLED, and that ordering is a
# repair. This door used to write the record, install the approved bytes, install
# the wrapper, and only then compose the grant file and hand it to `visudo`. When
# `visudo` refused it the run reported `ok: false` and the firm read that as an
# act that did not happen -- while the record was on disk, the door and its
# wrapper were installed, the member-plane row was written and the request id was
# spent. Nothing there was reversible by the person reading the refusal. Worse,
# the grant file is derived whole from the registry on every act, so the next
# grant, the next revoke or the next provisioning ride read that record and wrote
# the line: the door the firm was told was refused opened later, on somebody
# else's operation, with nothing naming it.
#
# A guard that fires after the act it exists to prevent is not a guard. So the
# file is composed from the registry PLUS the change this run intends, parsed
# while nothing has been written, and a file that will not parse ends the run
# with nothing installed, nothing recorded and the request NOT consumed.

# The pending change is passed in rather than read from disk, because at this
# point it is not on disk: a grant's record is not written yet and a revoke's
# record is still there and is going.
compose_tenant_sudoers() {   # compose_tenant_sudoers <outfile> <name> <group-or-empty-to-drop>
  local out="$1" pend_name="$2" pend_grp="$3"
  local rec name grp rows=""
  shopt -s nullglob
  for rec in "$DOORS_DIR"/*.json; do
    name="$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$rec" | head -1)"
    grp="$(sed -n 's/.*"group": *"\([^"]*\)".*/\1/p' "$rec" | head -1)"
    case "$name" in ''|*[!a-z0-9-]*) continue ;; esac
    case "$grp" in "$GROUP_MEMBERS"|"$GROUP_ADMIN") : ;; *) continue ;; esac
    [ "$name" != "$pend_name" ] || continue
    rows="${rows}${name} ${grp}"$'\n'
  done
  shopt -u nullglob
  [ -z "$pend_grp" ] || rows="${rows}${pend_name} ${pend_grp}"$'\n'

  {
    printf '# Managed by manage-claw-authority.sh. Do not edit on the claw.\n'
    printf '#\n'
    printf '# The firm approved each line below by signing for it. Every entry names a\n'
    printf '# wrapper, never a tenant script: the wrapper re-checks the approved content\n'
    printf '# hash on every run and writes the member-plane row, and a tenant script placed\n'
    printf '# in the grant directly would do neither.\n'
    printf '#\n'
    printf '# This file is DERIVED from %s. It is rewritten whole on every act, so a line\n' "$DOORS_DIR"
    printf '# added here by hand is removed by the next one.\n'
    printf '#\n'
    printf '# NOPASSWD is required rather than convenient: accounts on a claw are created\n'
    printf '# without a password, so a grant that prompts is a grant that never opens.\n'
    printf '\n'
  } > "$out"

  # Sorted, so the bytes depend on which doors are approved and not on the order
  # a directory happened to be read in. The provisioning run derives the same
  # file from the same records, and two writers producing different bytes for the
  # same state is a diff somebody has to explain every ride.
  TENANT_DOOR_NAMES=""
  while read -r name grp; do
    [ -n "$name" ] || continue
    printf '%%%s ALL=(root) NOPASSWD: %s/%s\n' "$grp" "$TENANT_DOOR_ROOT" "$name" >> "$out"
    TENANT_DOOR_NAMES="${TENANT_DOOR_NAMES}${name} "
  done <<< "$(printf '%s' "$rows" | LC_ALL=C sort)"
}

# Called only after the file above parsed. It moves a validated file into place
# and decides nothing.
install_tenant_sudoers() {   # install_tenant_sudoers <validated-file>
  if [ -z "$TENANT_DOOR_NAMES" ]; then
    # No doors left. The file goes rather than sitting empty, so `ls` in the
    # drop-in directory says what is true.
    rm -f "$TENANT_SUDOERS"
    ok "no tenant doors remain, so ${TENANT_SUDOERS} was removed rather than left empty"
  else
    install -m 0440 -o root -g root "$1" "$TENANT_SUDOERS"
    ok "the grant file that was parsed before any install is the one now at ${TENANT_SUDOERS}: ${TENANT_DOOR_NAMES}"
  fi
}

TENANT_DOOR_NAMES=""
TENANT_SUDO_NEW="${WORK}/tenant-sudoers"
case "$OPERATION" in
  grant-door)  compose_tenant_sudoers "$TENANT_SUDO_NEW" "$DOOR_NAME" "$DOOR_GROUP" ;;
  revoke-door) compose_tenant_sudoers "$TENANT_SUDO_NEW" "$DOOR_NAME" "" ;;
esac

case "$OPERATION" in
  grant-door|revoke-door)
    # VALIDATED BEFORE IT IS INSTALLED, AND BEFORE ANYTHING ELSE IS. A malformed
    # file in the drop-in directory breaks sudo for every caller on the claw,
    # including the one holding the only door.
    if visudo -cf "$TENANT_SUDO_NEW" >/dev/null 2>&1; then
      ok "the grant file this act would produce parses under visudo, checked while nothing has been written"
    else
      say "REFUSED: the tenant grant file this act would produce does not parse under visudo."
      visudo -cf "$TENANT_SUDO_NEW" 2>&1 | sed 's/^/    /' >&2 || true
      say "Nothing was installed, nothing was recorded, and request ${REQUEST_ID} was NOT consumed."
      say "The grant file is derived whole from ${DOORS_DIR} on every act, so this had to refuse here: a record written now would have been granted by the next act somebody else ran."
      ACTION="refused"
      bad "the grant file does not parse under visudo -- nothing installed, nothing recorded, the request not consumed"
      finish
    fi
    ;;
esac

# ---------------------------------------------------------------- the dry run
#
# ABOVE EVERY WRITE AND BELOW EVERY REFUSAL, DELIBERATELY. A dry run that skipped
# the refusals would report a plan for an act that would not happen, which is the
# opposite of what somebody runs one for.

if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "  DRY RUN. Nothing below happened."
  say "  operation:  ${OPERATION}"
  say "  subject:    ${SUBJECT}"
  say "  approved by ${SIGNER} (${SIGNER_TIER}), verified"
  say "  action:     ${ACTION}"
  case "$OPERATION" in
    grant-door)
      say "  would write ${DOORS_DIR}/${DOOR_NAME}.sh and .json"
      say "  would install ${TENANT_DOOR_ROOT}/${DOOR_NAME} and ${DOOR_NAME}.script"
      say "  would grant ${DOOR_GROUP} a NOPASSWD line on ${TENANT_DOOR_ROOT}/${DOOR_NAME}" ;;
    revoke-door)
      say "  would remove the record, the installed script, the wrapper and the grant line" ;;
    add-admin)
      say "  would add ${PERSON} to ${ADMINS_FILE} and to ${CLAW_ADMIN_GROUP}" ;;
    remove-admin)
      say "  would remove every ${PERSON} line from ${ADMINS_FILE} and take them out of ${CLAW_ADMIN_GROUP}" ;;
    transfer-owner)
      say "  would replace ${OWNER_FILE} with ${PERSON}'s key, add them to ${CLAW_ADMIN_GROUP}, and take ${OWNER_PRINCIPAL} out of it" ;;
  esac
  say "  would append one row to ${ADMIN_LOG}"
  say "  would record request ${REQUEST_ID} as used"
  say "  the request is NOT consumed by a dry run: apply it for real when you are ready"
  finish
fi

# ---------------------------------------------------------------- the acts

install -d -m 0755 -o root -g root "$AUTHORITY_ROOT"
install -d -m 0755 -o root -g root "$DOORS_DIR"

case "$OPERATION" in

  grant-door)
    install -d -m 0755 -o root -g root "$OPT_ROOT"
    install -d -m 0750 -o root -g root "$TENANT_DOOR_ROOT"

    install -m 0640 -o root -g root "${WORK}/candidate" "${DOORS_DIR}/${DOOR_NAME}.sh"
    {
      printf '{\n'
      printf '  "name": "%s",\n'          "$(json_esc "$DOOR_NAME")"
      printf '  "group": "%s",\n'         "$(json_esc "$DOOR_GROUP")"
      printf '  "sha256": "%s",\n'        "$DOOR_SHA"
      printf '  "approved_by": "%s",\n'   "$(json_esc "$SIGNER")"
      printf '  "approved_tier": "%s",\n' "$(json_esc "$SIGNER_TIER")"
      printf '  "approved_at": "%s",\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '  "request_id": "%s",\n'    "$(json_esc "$REQUEST_ID")"
      printf '  "applied_by": "%s"\n'     "$(json_esc "$BY")"
      printf '}\n'
    } > "${WORK}/record"
    install -m 0644 -o root -g root "${WORK}/record" "${DOORS_DIR}/${DOOR_NAME}.json"

    install -m 0750 -o root -g root "${WORK}/candidate" "${TENANT_DOOR_ROOT}/${DOOR_NAME}.script"
    install -m 0750 -o root -g root "$WRAPPER_TEMPLATE" "${TENANT_DOOR_ROOT}/${DOOR_NAME}"
    install_tenant_sudoers "$TENANT_SUDO_NEW"
    ;;

  revoke-door)
    rm -f "${DOORS_DIR}/${DOOR_NAME}.json" "${DOORS_DIR}/${DOOR_NAME}.sh"
    rm -f "${TENANT_DOOR_ROOT}/${DOOR_NAME}" "${TENANT_DOOR_ROOT}/${DOOR_NAME}.script"
    install_tenant_sudoers "$TENANT_SUDO_NEW"
    if [ "$ACTION" = "unchanged" ]; then
      warn "this claw carried no door called '${DOOR_NAME}'. Nothing was removed, and the paths were cleared anyway so a half-removed door cannot survive a revoke."
    fi
    ;;

  add-admin)
    if [ "$ACTION" != "unchanged" ]; then
      touch "$ADMINS_FILE"
      printf '%s %s\n' "$PERSON" "$PERSON_KEY" >> "$ADMINS_FILE"
    fi
    chmod 0644 "$ADMINS_FILE"; chown root:root "$ADMINS_FILE"
    gpasswd -a "$PERSON" "$CLAW_ADMIN_GROUP" >/dev/null 2>&1 || bad "could not add ${PERSON} to ${CLAW_ADMIN_GROUP}"
    ;;

  remove-admin)
    if [ "$ACTION" = "removed" ]; then
      awk -v p="$PERSON" '!(!/^#/ && NF && $1 == p)' "$ADMINS_FILE" > "${WORK}/admins"
      install -m 0644 -o root -g root "${WORK}/admins" "$ADMINS_FILE"
      gpasswd -d "$PERSON" "$CLAW_ADMIN_GROUP" >/dev/null 2>&1 || warn "${PERSON} was not in ${CLAW_ADMIN_GROUP} to begin with"
    else
      warn "${PERSON} is not an admin on this claw. Nothing was removed. 'claw-authority --list' says who is."
    fi
    ;;

  transfer-owner)
    if [ "$ACTION" = "transferred" ]; then
      printf '%s %s\n' "$PERSON" "$PERSON_KEY" > "${WORK}/owner"
      install -m 0644 -o root -g root "${WORK}/owner" "$OWNER_FILE"
      # A person holds ONE tier. An incoming owner who was an admin stops being
      # one, so the roster carries one answer about them.
      if [ -f "$ADMINS_FILE" ]; then
        awk -v p="$PERSON" '!(!/^#/ && NF && $1 == p)' "$ADMINS_FILE" > "${WORK}/admins"
        install -m 0644 -o root -g root "${WORK}/admins" "$ADMINS_FILE"
      fi
      gpasswd -a "$PERSON" "$CLAW_ADMIN_GROUP" >/dev/null 2>&1 || bad "could not add ${PERSON} to ${CLAW_ADMIN_GROUP}"
      # THE OUTGOING OWNER BECOMES NOTHING, and it is said loudly rather than
      # assumed. A handover that quietly left the old owner holding every door
      # would be a handover in name. If the firm wants them kept as an admin,
      # the new owner signs an add-admin, which is one act and is visible.
      if [ -n "$OWNER_PRINCIPAL" ] && [ "$OWNER_PRINCIPAL" != "$PERSON" ]; then
        if is_admin_principal "$OWNER_PRINCIPAL"; then
          warn "${OWNER_PRINCIPAL} is also listed as an admin, so they keep that tier and stay in ${CLAW_ADMIN_GROUP}."
        else
          gpasswd -d "$OWNER_PRINCIPAL" "$CLAW_ADMIN_GROUP" >/dev/null 2>&1 || true
          warn "${OWNER_PRINCIPAL} holds nothing on this claw now. Ownership does not leave an admin behind; if the firm wants them kept as one, ${PERSON} signs an add-admin."
        fi
      fi
    fi
    ;;
esac

# ---------------------------------------------------------------- the record

WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$OPERATION" in
  grant-door)     LOG_ACTION="granted a tenant door";      LOG_SUBJECT="${DOOR_NAME} to ${DOOR_GROUP}, approved by ${SIGNER}" ;;
  revoke-door)    LOG_ACTION="revoked a tenant door";      LOG_SUBJECT="${DOOR_NAME}, approved by ${SIGNER}" ;;
  add-admin)      LOG_ACTION="appointed a claw admin";     LOG_SUBJECT="${PERSON}, approved by ${SIGNER}" ;;
  remove-admin)   LOG_ACTION="removed a claw admin";       LOG_SUBJECT="${PERSON}, approved by ${SIGNER}" ;;
  transfer-owner) LOG_ACTION="transferred claw ownership"; LOG_SUBJECT="to ${PERSON}, approved by ${SIGNER}" ;;
esac

# The row is written for every applied request, including one whose action was
# `unchanged`. A signature was spent and a request id was consumed, so something
# happened even where nothing changed, and a log that only records changes would
# leave the firm unable to see an approval that was already satisfied.
printf '| %s | %s | %s | %s |\n' "$WHEN" "$BY" "$LOG_ACTION" "$LOG_SUBJECT" >> "$ADMIN_LOG"

# The request id is recorded LAST among the writes and it is recorded whatever
# the action was. A request that reached this line has been applied; letting an
# `unchanged` one stay usable would let it be replayed after the state moved.
printf '%s\n' "$REQUEST_ID" >> "$SEEN_FILE"
chmod 0644 "$SEEN_FILE"; chown root:root "$SEEN_FILE"

# ---------------------------------------------------------------- verify
#
# READ BACK FROM DISK. Every claim below is a claim about what is there now, not
# about what a write reported.

say ""
say "=== VERIFY ==="

case "$OPERATION" in
  grant-door)
    if [ -f "${DOORS_DIR}/${DOOR_NAME}.sh" ]; then
      ok "the approved bytes are recorded at ${DOORS_DIR}/${DOOR_NAME}.sh, inside the plane the backup rail keeps"
    else bad "the approved bytes did not reach ${DOORS_DIR}"; fi
    RB="$(sha256sum "${TENANT_DOOR_ROOT}/${DOOR_NAME}.script" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$RB" = "$DOOR_SHA" ]; then ok "the installed script reads back at the approved hash"
    else bad "the installed script reads back at '${RB}', not the approved ${DOOR_SHA}"; fi
    if [ "$(stat -c '%a %U:%G' "${TENANT_DOOR_ROOT}/${DOOR_NAME}" 2>/dev/null || true)" = "750 root:root" ]; then
      ok "the granted wrapper is 750 root:root -- a door its caller can edit is a grant of everything"
    else bad "the granted wrapper is $(stat -c '%a %U:%G' "${TENANT_DOOR_ROOT}/${DOOR_NAME}" 2>/dev/null || echo missing), wanted 750 root:root"; fi
    if [ "$(stat -c '%a %U:%G' "${TENANT_DOOR_ROOT}/${DOOR_NAME}.script" 2>/dev/null || true)" = "750 root:root" ]; then
      ok "the installed script is 750 root:root"
    else bad "the installed script is $(stat -c '%a %U:%G' "${TENANT_DOOR_ROOT}/${DOOR_NAME}.script" 2>/dev/null || echo missing), wanted 750 root:root"; fi
    # READ BACK AGAINST THE PINNED NUMBER, NEVER AGAINST THE TEMPLATE. Comparing
    # the granted path to the file this run just copied from can only catch a
    # copy that failed, and it was reported as evidence that the granted path is
    # the wrapper this release ships. It is that claim the constant makes
    # checkable.
    RB_WRAPPER="$(sha256sum "${TENANT_DOOR_ROOT}/${DOOR_NAME}" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$RB_WRAPPER" = "$WRAPPER_SHA256" ]; then
      ok "the granted path is the wrapper this release ships, hash for hash -- the tenant's script is behind it and is not in the grant"
    else bad "the granted path reads back at '${RB_WRAPPER}', not the ${WRAPPER_SHA256} this release ships"; fi
    if grep -qF "NOPASSWD: ${TENANT_DOOR_ROOT}/${DOOR_NAME}" "$TENANT_SUDOERS" 2>/dev/null; then
      ok "the grant line names the wrapper at ${TENANT_SUDOERS}"
    else bad "no grant line for ${DOOR_NAME} in ${TENANT_SUDOERS}"; fi
    if grep -qF "NOPASSWD: ${TENANT_DOOR_ROOT}/${DOOR_NAME}.script" "$TENANT_SUDOERS" 2>/dev/null; then
      bad "the tenant script is itself in the grant -- it must never be, because it would run with no hash check and no row"
    else ok "the tenant script carries no grant of its own, so nothing reaches it except through the wrapper"; fi
    ;;
  revoke-door)
    for p in "${DOORS_DIR}/${DOOR_NAME}.json" "${DOORS_DIR}/${DOOR_NAME}.sh" \
             "${TENANT_DOOR_ROOT}/${DOOR_NAME}" "${TENANT_DOOR_ROOT}/${DOOR_NAME}.script"; do
      if [ -e "$p" ]; then bad "${p} is still there after a revoke"; else ok "${p} is gone"; fi
    done
    if grep -qF "NOPASSWD: ${TENANT_DOOR_ROOT}/${DOOR_NAME}" "$TENANT_SUDOERS" 2>/dev/null; then
      bad "the grant line for ${DOOR_NAME} survived the revoke"
    else ok "no grant line for ${DOOR_NAME} remains"; fi
    ;;
  add-admin)
    if is_admin_principal "$PERSON"; then ok "${PERSON} is in ${ADMINS_FILE}"
    else bad "${PERSON} is not in ${ADMINS_FILE} after an add"; fi
    case " $(members_of "$CLAW_ADMIN_GROUP") " in
      *" ${PERSON} "*) ok "${PERSON} is in ${CLAW_ADMIN_GROUP}, so the vendor doors open for them" ;;
      *) bad "${PERSON} is not in ${CLAW_ADMIN_GROUP} -- the tier is recorded and opens nothing" ;;
    esac
    warn "a group added while ${PERSON} is logged in does not reach that session. They log in again."
    ;;
  remove-admin)
    if is_admin_principal "$PERSON"; then bad "${PERSON} is still in ${ADMINS_FILE} after a remove"
    else ok "${PERSON} holds no line in ${ADMINS_FILE}"; fi
    case " $(members_of "$CLAW_ADMIN_GROUP") " in
      *" ${PERSON} "*) bad "${PERSON} is still in ${CLAW_ADMIN_GROUP}" ;;
      *) ok "${PERSON} is out of ${CLAW_ADMIN_GROUP}" ;;
    esac
    warn "a session ${PERSON} already had keeps the groups it started with. Removing a tier shuts the door and leaves whoever is inside where they are: check for live sessions."
    ;;
  transfer-owner)
    if [ "$(awk '!/^#/ && NF {print $1; exit}' "$OWNER_FILE")" = "$PERSON" ]; then
      ok "${PERSON} is this claw's owner"
    else bad "${OWNER_FILE} does not name ${PERSON} after a transfer"; fi
    if [ "$(awk '!/^#/ && NF' "$OWNER_FILE" | grep -c '')" -eq 1 ]; then
      ok "the owner file holds exactly one line -- one claw, one owner"
    else bad "the owner file holds $(awk '!/^#/ && NF' "$OWNER_FILE" | grep -c '') lines"; fi
    if is_admin_principal "$PERSON"; then bad "${PERSON} is owner and admin at once"
    else ok "${PERSON} holds one tier"; fi
    # THE HANDOVER IS TWO FACTS AND BOTH ARE READ BACK. An owner who cannot run
    # a single one of their own claw's operations has been handed a title. An
    # outgoing owner still holding the group has handed nothing over.
    case " $(members_of "$CLAW_ADMIN_GROUP") " in
      *" ${PERSON} "*) ok "${PERSON} is in ${CLAW_ADMIN_GROUP}, so the claw's own operations open for them" ;;
      *) bad "${PERSON} is not in ${CLAW_ADMIN_GROUP} -- they hold this claw and cannot run one of its operations" ;;
    esac
    if [ -n "$OWNER_PRINCIPAL" ] && [ "$OWNER_PRINCIPAL" != "$PERSON" ] && ! is_admin_principal "$OWNER_PRINCIPAL"; then
      case " $(members_of "$CLAW_ADMIN_GROUP") " in
        *" ${OWNER_PRINCIPAL} "*) bad "${OWNER_PRINCIPAL} handed this claw over and is still in ${CLAW_ADMIN_GROUP}" ;;
        *) ok "${OWNER_PRINCIPAL} is out of ${CLAW_ADMIN_GROUP}" ;;
      esac
    fi
    ;;
esac

if [ "$(tail -1 "$ADMIN_LOG")" = "| ${WHEN} | ${BY} | ${LOG_ACTION} | ${LOG_SUBJECT} |" ]; then
  ok "one row appended to ${ADMIN_LOG}"
else
  bad "the member-plane row is not the last line of ${ADMIN_LOG}"
fi

if grep -qxF "$REQUEST_ID" "$SEEN_FILE"; then
  ok "request ${REQUEST_ID} is recorded as used and cannot be applied again"
else
  bad "request ${REQUEST_ID} was not recorded, so the same signed document could be applied a second time"
fi

say ""
case "$OPERATION" in
  grant-door)
    say "  ${DOOR_GROUP} can now run: sudo ${TENANT_DOOR_ROOT}/${DOOR_NAME}"
    say "  Every run of it checks the approved hash again and writes a row to ${ADMIN_LOG}."
    say "  A member already logged in when ${DOOR_GROUP} first got a door keeps the groups their session started with." ;;
  add-admin|transfer-owner)
    say "  ${PERSON} approves from their own device. Nothing they need is on this claw."
    say "  Their key opening a login and their key approving an act are two records: revoking one does not revoke the other." ;;
  remove-admin)
    say "  ${PERSON} can no longer approve anything here. Their login is untouched: that is manage-person-keys." ;;
esac

finish
