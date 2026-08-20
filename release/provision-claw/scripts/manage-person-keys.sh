#!/bin/bash
#
# manage-person-keys.sh — add and revoke one existing person's SSH keys.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./manage-person-keys.sh --add-key    alice "ssh-ed25519 AAAA... alice@phone"
#   sudo ./manage-person-keys.sh --revoke-key alice SHA256:2Vd5v...
#   sudo ./manage-person-keys.sh --revoke-key alice "ssh-ed25519 AAAA... alice@laptop"
#   sudo ./manage-person-keys.sh --list       alice
#
#   --last-key-ok  permit a revoke that leaves this person no key at all
#   --dry-run      print the plan, change nothing
#
# GRANTED SCRIPT. A claw-admin runs it through the member plane. It is root-owned
# and unwritable by its caller, it validates its own arguments, and it is
# idempotent in both directions, because the sudo grant carries no validation of
# its own.
#
# THE DOOR EXISTS BECAUSE SELF-SERVICE FAILS AT EXACTLY THE TWO MOMENTS KEY
# MANAGEMENT IS NEEDED. A person edits their own authorized_keys while they still
# hold a working key. Device loss and device theft are the states where that is
# false.
#
#   ADD, after a lost device. The person's only key was on it. They cannot log in
#   to install their second one, and the firm's own admin cannot install it for
#   them, because a home is 0750 and its owner's group. Without this door it is a
#   vendor request.
#
#   REVOKE, after a stolen device. The key is in somebody else's hands and the
#   firm cannot cut it off its own machine. Waiting on the vendor mid-incident is
#   the sharper half of the gap.
#
# IT CREATES NOBODY AND DELETES NOBODY. A person must already exist and already
# be in `claw-members`. Creating a person and managing that person's keys are two
# decisions, so they stay two doors, the same split that keeps workspace creation
# and workspace access apart. A name this door does not find is refused rather
# than made, because converging onto an unknown name would graft a key onto
# whatever account happens to answer to it.
#
# IT APPENDS, NEVER REPLACES. The one failure onboard-person refuses to make is
# the one this door has to avoid on every run: an add leaves every other key
# where it was, and a revoke removes the entries it named and nothing else. Both
# are verified afterwards by reading every line of the file back, not by trusting
# the write.
#
# REVOKE TAKES A FINGERPRINT. Cutting off a key never requires holding a copy of
# it, which is the state a firm is in when the device is gone. A full public key
# line is accepted too and is reduced to its fingerprint before anything is
# matched, so both spellings take the same path.
#
# A REVOKE THAT WOULD LEAVE ZERO KEYS IS REFUSED UNLESS `--last-key-ok` SAYS SO.
# The state is legitimate: a person under investigation, or one whose devices are
# all gone, should be shut out on purpose. It is refused by default because it is
# indistinguishable at the command line from revoking the wrong fingerprint, and
# the person it locks out is the one who would otherwise fix it themselves. The
# flag is the caller saying the lockout is the intent.
#
# A PRIVATE KEY OFFERED HERE IS REFUSED, by the same structural test
# onboard-person runs, for the reason measured on 2026-08-11: `ssh-keygen -l -f`
# prints a fingerprint for a PRIVATE key and exits 0, so a script that trusts
# that exit status installs a secret into a file every session on the claw can
# read. One line only, no PEM armor and no vendor key header, a leading key type
# from the named set, and only then the key tool.
#
# THE KEY TYPES ARE onboard-person's SET, character for character. A person whose
# second device is refused a key type their first device was granted has been
# handed a rule nobody wrote down.
#
# WHAT IT REFUSES TO WRITE THROUGH. This door runs as root inside a directory its
# owner controls, so the path itself is a risk surface. A home, a `.ssh` or an
# `authorized_keys` that is a symlink, that somebody other than the person owns,
# or that carries more than one hard link, is refused. Appending through a
# symlink is how a member turns a key door into a write of their choosing
# somewhere else on the claw.
#
# THE ADMIN-LOG ROW CARRIES THE FINGERPRINT, NEVER THE KEY. The log is
# world-readable. A fingerprint names which key without reprinting it, and it is
# the same string the caller passes to revoke it later.
#
# --list WRITES NOTHING AND RECORDS NOTHING. Reading which keys open an account is
# not an act on the claw, and a row for every question would bury the rows that
# are acts.
#
# WHAT THIS DOOR CANNOT DO, SAID RATHER THAN IMPLIED. Removing a key does not end
# a session that key already opened. Revocation shuts the door and leaves whoever
# is inside where they are. The door says so on every revoke and names the two
# commands that finish the job, because during an incident the gap between
# "revoked" and "gone" is the whole question.
#
# THE CONTRACT WITH onboard-person AND WITH PHASE 8. The `.ssh` directory at 0700
# and `authorized_keys` at 0600, owned by the person, are their values. This door
# creates those two only when a member has neither, and it creates them in
# exactly those modes. Both sides name them and neither may move one alone.
#
set -euo pipefail

MODE=""; PERSON=""; TARGET=""; DRY_RUN=0; LAST_KEY_OK=0

ADMIN_LOG="/etc/commonclaw/admin-log.md"
MEMBERS_GROUP="claw-members"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"

# The file this door edits, spelled the way sshd's own default spells it. The
# sshd control below compares against this suffix.
AK_RELATIVE=".ssh/authorized_keys"

# onboard-person's set, character for character. RSA is deliberately absent
# there: the mobile app rejects it. A door that accepted it here would install a
# key that fails at the last step of somebody's own onboarding.
KEY_TYPES=(
  "ssh-ed25519"
  "ecdsa-sha2-nistp256"
  "sk-ssh-ed25519@openssh.com"
  "sk-ecdsa-sha2-nistp256@openssh.com"
)

# A bound on what this door will read and fingerprint. One process per key line
# is fine for a person's own file and is not fine for a file somebody filled. The
# refusal names the number, so a real claw that outgrows it gets an answer rather
# than a hang.
MAX_ENTRIES=256
MAX_AK_BYTES=262144

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

# `shift N` returns non-zero when fewer than N arguments remain, and under
# `set -e` that ends the script with status 1 and NOTHING printed. A caller who
# typed `--add-key alice` and forgot the key would get silence and a failure
# code. So the count is checked first and the miss is named.
need() {
  [ "$1" -ge "$2" ] || { printf '%s needs %s value(s)\n' "$3" "$(( $2 - 1 ))" >&2; usage; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --add-key)     need $# 3 "--add-key <person> <key>";                 MODE="add";    PERSON="$2"; TARGET="$3"; shift 3 ;;
    --revoke-key)  need $# 3 "--revoke-key <person> <fingerprint-or-key>"; MODE="revoke"; PERSON="$2"; TARGET="$3"; shift 3 ;;
    --list)        need $# 2 "--list <person>";                          MODE="list";   PERSON="$2"; shift 2 ;;
    --last-key-ok) LAST_KEY_OK=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; FINGERPRINT=""; HOME_DIR=""; AK=""; SSH_DIR=""; PGROUP=""
ENTRIES_BEFORE=0; ENTRIES_AFTER=0; MATCHED=0; TMP=""

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
  printf '  "script": "manage-person-keys",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "mode": "%s",\n' "$(json_esc "$MODE")"
  printf '  "person": "%s",\n' "$(json_esc "$PERSON")"
  printf '  "fingerprint": "%s",\n' "$(json_esc "$FINGERPRINT")"
  printf '  "keys_before": %s,\n' "$ENTRIES_BEFORE"
  printf '  "keys_after": %s,\n' "$ENTRIES_AFTER"
  printf '  "entries_matched": %s,\n' "$MATCHED"
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

[ -n "$MODE" ] || { say "pick one: --add-key, --revoke-key or --list"; usage; }
[ -n "$PERSON" ] || { say "missing the person"; usage; }

if [ "$MODE" = "list" ] && [ "$LAST_KEY_OK" -eq 1 ]; then
  say "--last-key-ok belongs to a revoke. --list changes nothing, so there is nothing for it to permit."
  exit 1
fi
if [ "$MODE" = "add" ] && [ "$LAST_KEY_OK" -eq 1 ]; then
  say "--last-key-ok belongs to a revoke. An add cannot leave somebody with no key."
  exit 1
fi

# ---- the person's name ----
#
# Constrained the same way the onboarding door and the access door constrain it,
# and for the same reason: this value lands in a world-readable record and in
# commands that read another account's home. TWO patterns, and the second one is
# the control. A shell case pattern is anchored at both ends, so the positive
# form alone validates the first character and nothing after it.
case "$PERSON" in
  [a-z]*) : ;;
  *) say "'${PERSON}' is not a usable username: it must start with a lowercase letter."; exit 1 ;;
esac
case "$PERSON" in
  *[!a-z0-9_-]*) say "'${PERSON}' is not a usable username: use lowercase letters, digits, hyphen and underscore only."; exit 1 ;;
esac

getent passwd "$PERSON" >/dev/null 2>&1 || {
  say "no such person on this claw: '${PERSON}'."
  say "This door manages the keys of somebody who already has a login here. It creates nobody -- that is the onboarding door."
  exit 1
}

# ---- the floor ----
#
# `claw-members` says a person has a login on this claw. A person who is not in
# it was not made by the onboarding door and is something else: a service
# account, or half of a run that stopped. Installing a key on one of those is
# opening an account nobody onboarded.
getent group "$MEMBERS_GROUP" >/dev/null 2>&1 || {
  say "no ${MEMBERS_GROUP} group on this claw, so nothing here says who the people are."
  say "Provisioning creates that group. Run the provisioning plane rather than creating it here."
  exit 1
}

# The empty-group refusal, which is its own case and not a slower way of failing
# the membership test below. A claw whose members group is empty was either never
# provisioned through the onboarding door or has had it emptied, and identity on
# this plane comes from that group alone. Reading a key door as usable there
# would be reading a grant out of an empty list.
MEMBERS_LIST="$(members_of "$MEMBERS_GROUP")"
[ -n "$MEMBERS_LIST" ] || {
  say "REFUSED: ${MEMBERS_GROUP} lists nobody on this claw."
  say "Identity on this plane is that group. An empty one means no person was onboarded through the door, so there is no key of anybody's to manage."
  say "A person carrying ${MEMBERS_GROUP} as their PRIMARY group would not appear in that list either, which is its own fault to fix."
  exit 1
}

case " $(id -nG "$PERSON" 2>/dev/null || true) " in
  *" ${MEMBERS_GROUP} "*) : ;;
  *) say "'${PERSON}' is not in ${MEMBERS_GROUP}, so they are not a person this claw onboarded."
     say "Run the onboarding door first, or resolve the account by hand if it is a service account."
     exit 1 ;;
esac

# ---- the path this door will write through ----
#
# Every check below refuses rather than repairs. The home belongs to its owner,
# so a shape that is not the shape onboarding made is a state somebody else
# created, and a root-owned door that quietly normalises it is a door that writes
# wherever that person points it.
HOME_DIR="$(getent passwd "$PERSON" | cut -d: -f6)"
PGROUP="$(id -gn "$PERSON" 2>/dev/null || true)"
[ -n "$PGROUP" ] || { say "cannot resolve ${PERSON}'s primary group"; exit 1; }

case "$HOME_DIR" in
  /*) : ;;
  *) say "${PERSON}'s home is not an absolute path: '${HOME_DIR}'"; exit 1 ;;
esac
# THE SYMLINK TEST COMES FIRST, EVERY TIME, and it is the only test here that
# does not follow the link. `-e` and `-d` resolve what a symlink points at, so a
# DANGLING one answers false to both and falls out of a guard written the other
# way round. Measured in this door's own rig on 2026-08-14: with the ordering
# inverted, a dangling `authorized_keys` symlink passed every check below it and
# the door then created the file at the far end of the link. A member owns their
# own home, so this is the door's whole risk surface, and the order of two lines
# is what decides it.
[ ! -L "$HOME_DIR" ] || { say "REFUSED: ${PERSON}'s home '${HOME_DIR}' is a symlink. This door will not write through one."; exit 1; }
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { say "${PERSON} has no home directory at '${HOME_DIR}'"; exit 1; }
[ "$(stat -c %U "$HOME_DIR")" = "$PERSON" ] || {
  say "REFUSED: ${HOME_DIR} is owned by $(stat -c %U "$HOME_DIR"), not by ${PERSON}."
  say "A key installed under a home somebody else owns opens an account for whoever owns the directory."
  exit 1
}

SSH_DIR="${HOME_DIR}/.ssh"
AK="${HOME_DIR}/${AK_RELATIVE}"

# `-L` before the block, not inside it: a dangling link is a link, and the test
# that admits the path to be examined must not be one that resolves it.
[ ! -L "$SSH_DIR" ] || { say "REFUSED: ${SSH_DIR} is a symlink. This door will not write through one."; exit 1; }
if [ -e "$SSH_DIR" ]; then
  [ -d "$SSH_DIR" ]   || { say "REFUSED: ${SSH_DIR} is not a directory."; exit 1; }
  [ "$(stat -c %U "$SSH_DIR")" = "$PERSON" ] || {
    say "REFUSED: ${SSH_DIR} is owned by $(stat -c %U "$SSH_DIR"), not by ${PERSON}."; exit 1; }
fi

[ ! -L "$AK" ] || { say "REFUSED: ${AK} is a symlink. Appending through one writes a key line into whatever it points at."; exit 1; }
if [ -e "$AK" ]; then
  [ -f "$AK" ]   || { say "REFUSED: ${AK} is not a regular file."; exit 1; }
  [ "$(stat -c %U "$AK")" = "$PERSON" ] || {
    say "REFUSED: ${AK} is owned by $(stat -c %U "$AK"), not by ${PERSON}."; exit 1; }
  # More than one name for these bytes means another path is written through
  # this one. The kernel's protected_hardlinks stops most ways of arranging it
  # and this door does not depend on that being switched on.
  [ "$(stat -c %h "$AK")" = "1" ] || {
    say "REFUSED: ${AK} carries $(stat -c %h "$AK") hard links, so another path on this claw is the same bytes."; exit 1; }
  [ "$(stat -c %s "$AK")" -le "$MAX_AK_BYTES" ] || {
    say "REFUSED: ${AK} is $(stat -c %s "$AK") bytes, past the ${MAX_AK_BYTES} this door reads."
    say "A person's key file is not this size. Look at it by hand before anything else edits it."
    exit 1; }
fi

# ---- does sshd read the file this door edits ----
#
# THE COST-AND-TIMING CASE FOR THIS DOOR. A claw whose sshd names a different
# AuthorizedKeysFile takes every add and every revoke here without either one
# reaching a login decision. The add reads as done and the person still cannot
# get in; the revoke reads as done and the stolen key still opens the machine.
# The price lands in the sshd plane, which nothing about a key door names, and it
# is armed by a config edit nobody associates with it.
#
# EVERY occurrence is read, from the main file and the drop-ins, and every one
# must name this path. sshd takes the first value it obtains and the include
# order decides which that is; this door does not guess which, so one occurrence
# that disagrees is a refusal.
#
# The directive names are matched without regard to case, because sshd reads
# them that way and a claw that spells one in lower case would otherwise pass a
# control that never saw it.
sshd_directive() {
  local name="$1" f
  for f in "$SSHD_CONFIG" "$SSHD_CONFIG_DIR"/*.conf; do
    [ -f "$f" ] || continue
    sed -n -E "s/^[[:space:]]*Authorized${name}[[:space:]]+//Ip" "$f" || true
  done
}

if [ "$MODE" != "list" ]; then
  akf_bad=""
  while IFS= read -r akf; do
    [ -n "$akf" ] || continue
    case " $akf " in
      *" ${AK_RELATIVE} "*|*" %h/${AK_RELATIVE} "*) : ;;
      *) akf_bad="${akf_bad}${akf}; " ;;
    esac
  done <<< "$(sshd_directive KeysFile)"
  if [ -n "$akf_bad" ]; then
    say "REFUSED: sshd on this claw is configured to read keys from somewhere else: ${akf_bad}"
    say "This door edits ${AK_RELATIVE}. Editing it here would change nothing that decides a login,"
    say "so an add would look installed while the person stayed locked out, and a revoke would look done while the key still opened the machine."
    exit 1
  fi

  akc="$(sshd_directive KeysCommand | grep -v '^none$' || true)"
  if [ -n "$akc" ]; then
    warn "sshd also runs an AuthorizedKeysCommand on this claw. It can serve keys this file does not hold, so a revoke here is not necessarily the whole revoke."
  fi
fi

if [ "$MODE" != "list" ]; then
  [ -f "$ADMIN_LOG" ] || {
    say "REFUSED: no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down."
    say "The log is seeded by provisioning. Run the provisioning plane rather than creating it here."
    exit 1
  }
fi

# ---------------------------------------------------------------- reading keys

WORK="$(mktemp -d)"; chmod 0700 "$WORK"
cleanup() { rm -rf "$WORK"; [ -n "${TMP:-}" ] && rm -f "$TMP"; return 0; }
trap cleanup EXIT

# The fingerprint of one authorized_keys line, or a non-zero status.
#
# IT RETURNS AND NEVER EXITS. This runs inside a command substitution, where an
# exit kills the subshell and leaves the caller running. A refusal that cannot
# halt what it guards is a comment.
#
# The line is written to a root-only directory with no `.pub` sibling, so the key
# tool reads exactly the line it was handed rather than a file beside it.
fp_of_line() {
  local line="$1" out fp
  printf '%s\n' "$line" > "${WORK}/one" || return 1
  out="$(ssh-keygen -l -f "${WORK}/one" 2>/dev/null)" || return 1
  fp="$(printf '%s\n' "$out" | awk 'NR==1 {print $2}')"
  case "$fp" in
    SHA256:?*) printf '%s' "$fp" ;;
    *) return 1 ;;
  esac
}

# Every line of the file, and a fingerprint for each one that has one. The whole
# file is read: a count over a sample is not a measurement of the file, and the
# claims made after a write are claims about every line in it.
AK_LINES=(); AK_FPS=(); AK_UNREADABLE=0
load_ak() {
  AK_LINES=(); AK_FPS=(); AK_UNREADABLE=0; ENTRIES_BEFORE=0
  [ -f "$AK" ] || return 0
  local line trimmed fp
  while IFS= read -r line || [ -n "$line" ]; do
    AK_LINES+=("$line")
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      ''|'#'*) AK_FPS+=(""); continue ;;
    esac
    ENTRIES_BEFORE=$(( ENTRIES_BEFORE + 1 ))
    if fp="$(fp_of_line "$line")" && [ -n "$fp" ]; then
      AK_FPS+=("$fp")
    else
      AK_FPS+=("")
      AK_UNREADABLE=$(( AK_UNREADABLE + 1 ))
    fi
  done < "$AK"
  return 0
}

load_ak
[ "$ENTRIES_BEFORE" -le "$MAX_ENTRIES" ] || {
  say "REFUSED: ${AK} holds ${ENTRIES_BEFORE} key entries, past the ${MAX_ENTRIES} this door reads."
  exit 1
}

# ---------------------------------------------------------------- list

if [ "$MODE" = "list" ]; then
  ACTION="listed"
  ENTRIES_AFTER="$ENTRIES_BEFORE"
  say ""
  say "=== ${PERSON}'s keys ==="
  say "  file:    ${AK}"
  say "  entries: ${ENTRIES_BEFORE}"
  say ""
  if [ "$ENTRIES_BEFORE" -eq 0 ]; then
    say "  none. This person cannot log in with a key today."
  else
    for i in "${!AK_LINES[@]}"; do
      [ -n "${AK_FPS[$i]}" ] || continue
      say "  $(ssh-keygen -l -f <(printf '%s\n' "${AK_LINES[$i]}") 2>/dev/null | head -1)"
    done
  fi
  say ""
  if [ "$AK_UNREADABLE" -gt 0 ]; then
    warn "${AK_UNREADABLE} line(s) in ${AK} could not be fingerprinted and are not listed above. They are not this door's to interpret and were left alone."
  fi
  if [ "$ENTRIES_BEFORE" -gt 0 ]; then
    say "  Revoke one with:  sudo $(basename "$0") --revoke-key ${PERSON} <fingerprint>"
  else
    warn "${PERSON} holds no key on this claw."
    say "  Install one with: sudo $(basename "$0") --add-key ${PERSON} \"<their public key>\""
  fi
  finish
fi

# ---------------------------------------------------------------- the target

# The key line's structural refusals. Each leg covers what the others miss, and
# the order matters: the cheapest and most decisive refusals run before anything
# parses the blob. Returns rather than exits, so both callers decide.
validate_key_line() {
  local key="$1" t type_ok=0 field_count
  case "$key" in
    *[$'\n\r']*) say "the key must be ONE line. A multi-line block is a private key, not a public key."; return 1 ;;
  esac
  case "$key" in
    *"-----BEGIN"*|*"PRIVATE KEY"*|*"PuTTY-User-Key-File"*)
      say "that is a PRIVATE key. It is not installed, and it is compromised by having left your machine."
      say "Mint a replacement, keep the private half in your own private vault that nobody else and no service account can read, and send the .pub half only."
      return 1 ;;
  esac
  [ -n "${key//[[:space:]]/}" ] || { say "the key is empty"; return 1; }
  [ "${#key}" -le 4096 ] || { say "the key line is longer than 4096 characters, which no public key is"; return 1; }
  case "$key" in
    *[![:print:][:space:]]*) say "the key line carries a control character"; return 1 ;;
  esac
  for t in "${KEY_TYPES[@]}"; do [ "${key%% *}" = "$t" ] && { type_ok=1; break; }; done
  if [ "$type_ok" -eq 0 ]; then
    say "'${key%% *}' is not a key type this claw installs."
    say "A desktop key opens with ssh-ed25519. A phone key opens with ecdsa-sha2-nistp256."
    say "Accepted: ${KEY_TYPES[*]}"
    say "A line that does not START with one of those -- an authorized_keys option, for instance -- is refused here."
    say "To revoke an entry of that shape, read its fingerprint with --list and pass the fingerprint."
    return 1
  fi
  field_count="$(printf '%s' "$key" | awk '{print NF}')"
  case "$field_count" in
    2|3) : ;;
    *) say "the key line has ${field_count} fields; a public key has the type, the blob, and at most one comment"; return 1 ;;
  esac
  return 0
}

case "$TARGET" in
  SHA256:*)
    if [ "$MODE" = "add" ]; then
      say "--add-key takes the key itself, not a fingerprint. A fingerprint cannot be installed: it is a digest, and nothing can recover the key from it."
      exit 1
    fi
    # The shape OpenSSH prints: SHA256 plus 43 characters of unpadded base64.
    case "$TARGET" in
      *[!A-Za-z0-9+/:_-]*) say "'${TARGET}' is not a SHA256 fingerprint: it carries characters no base64 digest holds."; exit 1 ;;
    esac
    [ "${#TARGET}" -eq 50 ] || {
      say "'${TARGET}' is ${#TARGET} characters; an OpenSSH SHA256 fingerprint is 50 (the prefix and 43 of digest)."
      say "Read one with: ssh-keygen -lf <keyfile>, or from this door's --list."
      exit 1
    }
    FINGERPRINT="$TARGET"
    ;;
  MD5:*|*:*:*)
    say "this door matches SHA256 fingerprints only, and '${TARGET}' is not one."
    say "Read the SHA256 form with: ssh-keygen -lf <keyfile>, or from this door's --list."
    exit 1
    ;;
  *)
    validate_key_line "$TARGET" || exit 1
    FINGERPRINT="$(fp_of_line "$TARGET")" || {
      say "the key tool refuses this line: it is not a public key of type ${TARGET%% *}"
      exit 1
    }
    ;;
esac

BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z_]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac
WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Which lines carry this fingerprint. Every line is compared, not the first
# match: a file holding the same key twice is revoked once and stays open.
KEEP=(); MATCHED=0
for i in "${!AK_LINES[@]}"; do
  if [ "${AK_FPS[$i]}" = "$FINGERPRINT" ]; then
    MATCHED=$(( MATCHED + 1 ))
  else
    KEEP+=("${AK_LINES[$i]}")
  fi
done

say ""
say "=== ${MODE} ${PERSON} ==="
say "  file:        ${AK}"
say "  fingerprint: ${FINGERPRINT}"
say "  entries now: ${ENTRIES_BEFORE}"
say "  by:          ${BY}"
say ""

# ---------------------------------------------------------------- idempotency
#
# Both directions converge, and neither writes a row for a change that did not
# happen. A log of acts that records non-acts stops being a log of acts.

if [ "$MODE" = "add" ] && [ "$MATCHED" -gt 0 ]; then
  ACTION="unchanged"
  ENTRIES_AFTER="$ENTRIES_BEFORE"
  say "  ${PERSON} already holds this key. Nothing changed and no row was written."
  warn "the key was already installed, so this run changed nothing"
  finish
fi

if [ "$MODE" = "revoke" ] && [ "$MATCHED" -eq 0 ]; then
  ACTION="unchanged"
  ENTRIES_AFTER="$ENTRIES_BEFORE"
  say "  no entry with that fingerprint. Nothing changed and no row was written."
  warn "no key with fingerprint ${FINGERPRINT} was installed for ${PERSON}"
  if [ "$AK_UNREADABLE" -gt 0 ]; then
    warn "${AK_UNREADABLE} line(s) in ${AK} could not be fingerprinted, so this door did not examine them. The absence above is an absence from the lines it could read."
  fi
  finish
fi

# ---------------------------------------------------------------- the lockout

# THE REFUSAL RUNS BEFORE THE DRY-RUN BRANCH, deliberately. A rehearsal that
# passes where the real run refuses is the register's own sharp edge: a plan
# nobody can execute reads as a plan that was checked.
if [ "$MODE" = "revoke" ]; then
  ENTRIES_AFTER=$(( ENTRIES_BEFORE - MATCHED ))
  if [ "$ENTRIES_AFTER" -eq 0 ] && [ "$LAST_KEY_OK" -ne 1 ]; then
    say "REFUSED: this is ${PERSON}'s last key. Removing it locks them out of this claw."
    say ""
    say "  They could not log in to install a replacement, and this door only manages"
    say "  the keys of somebody who already exists, so the way back is an admin running"
    say "  --add-key with their new public key."
    say ""
    say "  If the lockout IS the intent -- a stolen device with nothing else on the"
    say "  account, or a person being shut out on purpose -- say so:"
    say ""
    say "    sudo $(basename "$0") --revoke-key ${PERSON} ${FINGERPRINT} --last-key-ok"
    say ""
    exit 1
  fi
else
  ENTRIES_AFTER=$(( ENTRIES_BEFORE + 1 ))
fi

# ---------------------------------------------------------------- dry run

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-${MODE}"
  if [ "$MODE" = "add" ]; then
    say "  would append one key to ${AK}, leaving ${ENTRIES_BEFORE} other entr(ies) untouched"
    [ -e "$AK" ] || say "  would create ${SSH_DIR} at 0700 and ${AK} at 0600, owned by ${PERSON}:${PGROUP}"
  else
    say "  would remove ${MATCHED} entr(ies) carrying ${FINGERPRINT}, leaving ${ENTRIES_AFTER}"
    [ "$ENTRIES_AFTER" -gt 0 ] || say "  would leave ${PERSON} with NO key, which --last-key-ok permits"
  fi
  say "  would append one row to ${ADMIN_LOG}"
  ENTRIES_AFTER="$ENTRIES_BEFORE"
  warn "dry run: nothing was changed"
  finish
fi

# ---------------------------------------------------------------- the change

if [ "$MODE" = "add" ]; then
  # The two modes are onboard-person's and phase 8's, and they are written here
  # only into an absence. A member with no `.ssh` is a person whose onboarding
  # predates it or who removed it; either way the shape they get is the shape
  # every other person on the claw has.
  [ -d "$SSH_DIR" ] || install -d -m 0700 -o "$PERSON" -g "$PGROUP" "$SSH_DIR"
  [ -e "$AK" ]      || install -m 0600 -o "$PERSON" -g "$PGROUP" /dev/null "$AK"

  # A file somebody edited by hand can end without a newline, and appending to
  # that file joins the new key onto the end of their last one. Both keys then
  # stop working and the file still looks right in a terminal.
  if [ -s "$AK" ] && [ -n "$(tail -c 1 "$AK")" ]; then
    printf '\n' >> "$AK"
    warn "${AK} did not end with a newline. One was added before the key, so the last entry stayed intact."
  fi

  # APPEND. Ownership and mode belong to the file and an append does not touch
  # either. This is the same write onboard-person makes.
  printf '%s\n' "$TARGET" >> "$AK"
  ACTION="added"
  LOG_ACTION="added an SSH key"
  LOG_SUBJECT="${FINGERPRINT} for ${PERSON}"
else
  # THE REWRITE, and the ownership rule it has to survive. A temp file made
  # somewhere else and moved in carries ITS OWN ownership onto the destination,
  # which is how a root-owned key file appears under somebody's home and stops
  # being theirs to manage. So the temp is created in the same directory, given
  # the target's exact ownership and mode first, and only then renamed over it.
  # A rename inside one directory is atomic, so a kill at any point leaves either
  # the old file or the new one and never a truncated one.
  TMP="$(mktemp "${SSH_DIR}/.authorized_keys.XXXXXX")"
  chown --reference="$AK" "$TMP"
  chmod --reference="$AK" "$TMP"
  if [ "${#KEEP[@]}" -gt 0 ]; then
    printf '%s\n' "${KEEP[@]}" > "$TMP"
  else
    : > "$TMP"
  fi
  mv -f "$TMP" "$AK"
  TMP=""
  ACTION="revoked"
  LOG_ACTION="revoked an SSH key"
  if [ "$MATCHED" -gt 1 ]; then
    LOG_SUBJECT="${FINGERPRINT} from ${PERSON}, ${MATCHED} entries"
  else
    LOG_SUBJECT="${FINGERPRINT} from ${PERSON}"
  fi
  [ "$ENTRIES_AFTER" -gt 0 ] || LOG_SUBJECT="${LOG_SUBJECT}, their last key"
fi

# ---------------------------------------------------------------- the record

# One row, one append, one call. Nobody reads this file and writes it back, so
# two writers in the same second cannot lose each other's row. The caller behind
# sudo, never root, because a record of who decided is the point. The subject
# carries the fingerprint and not the key: this file is world-readable, and a
# fingerprint names which key without reprinting it.
printf '| %s | %s | %s | %s |\n' "$WHEN" "$BY" "$LOG_ACTION" "$LOG_SUBJECT" >> "$ADMIN_LOG"

# ---------------------------------------------------------------- verify

say ""
say "=== VERIFY ==="

# Read the file back rather than trusting the write, and read ALL of it. Every
# claim below is a claim about every line in the file, so every line is
# fingerprinted again from the bytes on disk.
BEFORE_FPS=("${AK_FPS[@]}")
BEFORE_UNREADABLE="$AK_UNREADABLE"
BEFORE_COUNT="$ENTRIES_BEFORE"
# load_ak recounts into ENTRIES_BEFORE, because it is the same reader either
# side of the write. The count taken before the change is held here and put
# back, so the JSON reports both numbers and not the later one twice.
load_ak
ENTRIES_AFTER="$ENTRIES_BEFORE"
ENTRIES_BEFORE="$BEFORE_COUNT"

ak_stat="$(stat -c '%a %U:%G' "$AK")"
if [ "$ak_stat" = "600 ${PERSON}:${PGROUP}" ]; then
  ok "authorized_keys is 600 ${PERSON}:${PGROUP}"
else
  bad "authorized_keys is ${ak_stat}, wanted 600 ${PERSON}:${PGROUP}"
fi

if [ ! -L "$AK" ] && [ -f "$AK" ] && [ "$(stat -c %h "$AK")" = "1" ]; then
  ok "authorized_keys is one regular file with one name"
else
  bad "authorized_keys is a symlink, not a regular file, or carries more than one hard link"
fi

# The target fingerprint, counted over every line.
now_count=0
for f in "${AK_FPS[@]:-}"; do [ "$f" = "$FINGERPRINT" ] && now_count=$(( now_count + 1 )); done
if [ "$MODE" = "add" ]; then
  if [ "$now_count" -eq 1 ]; then
    ok "the offered key appears exactly once in authorized_keys"
  else
    bad "the offered key appears ${now_count} times in authorized_keys"
  fi
else
  if [ "$now_count" -eq 0 ]; then
    ok "no entry carries ${FINGERPRINT} any more"
  else
    bad "${now_count} entr(ies) still carry ${FINGERPRINT}"
  fi
fi

# THE SET DIFFERENCE, which is the check that says nothing else moved. A count
# alone passes on a file where one key replaced another.
lost=""
for f in "${BEFORE_FPS[@]:-}"; do
  [ -n "$f" ] || continue
  [ "$f" = "$FINGERPRINT" ] && continue
  found=0
  for g in "${AK_FPS[@]:-}"; do [ "$g" = "$f" ] && { found=1; break; }; done
  [ "$found" -eq 1 ] || lost="${lost}${f} "
done
gained=""
for g in "${AK_FPS[@]:-}"; do
  [ -n "$g" ] || continue
  [ "$g" = "$FINGERPRINT" ] && continue
  found=0
  for f in "${BEFORE_FPS[@]:-}"; do [ "$f" = "$g" ] && { found=1; break; }; done
  [ "$found" -eq 1 ] || gained="${gained}${g} "
done
if [ -z "$lost" ] && [ -z "$gained" ]; then
  ok "every other key ${PERSON} held is still there, and no key arrived that nobody asked for"
else
  bad "keys changed besides the one named: lost '${lost}' gained '${gained}'"
fi

if [ "$AK_UNREADABLE" -eq "$BEFORE_UNREADABLE" ]; then
  ok "${AK_UNREADABLE} line(s) this door cannot fingerprint, the same number as before: nothing was mangled"
else
  bad "lines this door cannot fingerprint went from ${BEFORE_UNREADABLE} to ${AK_UNREADABLE}, so a line was damaged"
fi

if [ "$(tail -1 "$ADMIN_LOG")" = "| ${WHEN} | ${BY} | ${LOG_ACTION} | ${LOG_SUBJECT} |" ]; then
  ok "one row appended to ${ADMIN_LOG}"
else
  bad "the member-plane log does not end with this act's row"
fi

# The floor is not what a key is made of, and this door does not touch it.
case " $(id -nG "$PERSON" 2>/dev/null || true) " in
  *" ${MEMBERS_GROUP} "*) ok "${PERSON} is still in ${MEMBERS_GROUP}: this door does not touch the floor" ;;
  *) bad "${PERSON} left ${MEMBERS_GROUP} -- a key change must not touch the claw's own membership" ;;
esac

say ""
if [ "$MODE" = "revoke" ]; then
  # SAID ON EVERY REVOKE. The door closes and whoever is already inside stays
  # inside. During an incident that gap is the whole question, so it is printed
  # rather than left in a document.
  say "  REVOKING A KEY DOES NOT END A SESSION IT ALREADY OPENED."
  say "  Look:  who -u | grep '^${PERSON} '   and   ps -u ${PERSON} -o pid,lstart,cmd"
  say "  Close: pkill -KILL -u ${PERSON}      (this ends every session that person has, including their own)"
  if [ "$ENTRIES_AFTER" -eq 0 ]; then
    say ""
    say "  ${PERSON} NOW HOLDS NO KEY and cannot log in to this claw. An admin here"
    say "  installs their next device with --add-key. Nothing they do on their own machine reaches it."
    warn "${PERSON} holds no key on this claw. They are locked out until an admin adds one."
  fi
else
  say "  ${PERSON} can use this key at their next connection. There is no group change here,"
  say "  so nothing waits for a fresh login."
fi

finish
