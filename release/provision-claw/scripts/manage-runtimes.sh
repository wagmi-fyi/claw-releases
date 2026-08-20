#!/bin/bash
#
# manage-runtimes.sh — install, remove and list this claw's shared language runtimes.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./manage-runtimes.sh --install node-22 --url https://... --sha256 <64 hex>
#   sudo ./manage-runtimes.sh --remove  node-22
#   sudo ./manage-runtimes.sh --list
#
#   --declared-ok  permit removing a runtime a workspace still declares
#   --dry-run      print the plan, change nothing
#
# GRANTED SCRIPT. A claw-admin runs it through the member plane. It is root-owned
# and unwritable by its caller, it validates its own arguments, and it is
# idempotent in both directions, because the sudo grant carries no validation of
# its own.
#
# THIS DOOR VERIFIES INTEGRITY, THE CALLER VOUCHES FOR AUTHENTICITY. The bytes
# are compared against the hash the caller supplied, before anything lands. The
# door does not know whether that hash is the vendor's, and it has no way to
# find out: a signature check would need a trusted key per runtime family, and a
# hash fetched from beside the payload is signed by whoever served the payload.
# So the caller carries the authenticity claim, and the URL and the hash are
# written into the admin-log row forever. That row is the authority trail: it
# names who decided, what they pointed at, and which bytes they vouched for.
#
# ALL THREE ARGUMENTS ARE REQUIRED TO INSTALL. A URL with no hash is a download,
# not an install, and this door will not perform one. There is no default source
# and no "latest": a runtime this claw has never been told about cannot arrive by
# omission.
#
# WHY THE RUNTIME IS SHARED AND THE DEPENDENCIES ARE NOT. One copy per claw,
# root-owned, at a fixed path, on every member's PATH. A project's own
# dependencies stay project-local -- node_modules, a virtual environment, a lock
# file -- because they are the project's decision and they change on the
# project's clock. The runtime is the machine's; the dependencies are the work's.
# `/etc/commonclaw/runtimes.md` is the member's copy of that rule.
#
# MAJOR GRANULARITY. The directory is `<name>-<major>`, so a claw carries one
# copy of a runtime line rather than one copy per patch release. A project that
# needs tighter than a major pins it project-side with its own tooling, which is
# a deliberate exception rather than a gap: the shared copy answers "which line
# does this machine run", and a lock file answers "which build does this project
# run".
#
# THE SYMLINK FARM IS DERIVED, NEVER BOOKKEPT. Every run rebuilds
# `<root>/bin` from what is installed. Each program gets a versioned link
# (`node-22`), which cannot collide across majors, and the bare name (`node`)
# goes to the newest major that provides it. A remove therefore re-points the
# bare name at whatever is left rather than leaving a dangling one on every
# member's PATH. Nothing incremental is recorded anywhere, so the farm cannot
# drift from the trees it points at.
#
# WHAT IT REFUSES TO REPLACE. A tree already sitting at the target path is never
# overwritten, even by an identical payload. Where the recorded pin matches the
# offered one the run is a no-op; where it differs, or where the tree exists with
# no row behind it, the door refuses and names `--remove`. Members hold open
# sessions against these binaries, and replacing a runtime underneath them is a
# decision somebody makes on purpose.
#
# A REMOVE THAT BREAKS A DECLARATION IS REFUSED UNLESS `--declared-ok` SAYS SO.
# A workspace manifest naming a runtime is that workspace saying its work needs
# it. Removing it anyway is legitimate -- the workspace may be finished with it,
# or the declaration may be stale -- and it is indistinguishable at the command
# line from removing the wrong one, so the flag is the caller saying the break is
# the intent.
#
# THE RECORD IS THE PIN STORE. There is no separate manifest of what this claw
# was told to install. The admin log's install rows carry the URL and the hash,
# they are append-only and world-readable, and they are inside the backed-up
# root while the runtime trees under `/opt` are not. That is deliberate: a claw
# restored from backup carries the pins and not the binaries, and provisioning
# re-derives the second from the first.
#
# WHAT THIS DOOR CANNOT DO, SAID RATHER THAN IMPLIED. `/etc/profile.d` is read by
# LOGIN shells. A systemd unit, a cron entry and a non-login `ssh host command`
# get no PATH from it, so anything unattended names the full path under
# `<root>/bin`. Installing a runtime also does nothing for a shell that is
# already open; that member's next login picks it up.
#
set -euo pipefail

MODE=""; RUNTIME=""; URL=""; SHA256=""; DRY_RUN=0; DECLARED_OK=0

ADMIN_LOG="/etc/commonclaw/admin-log.md"
RUNTIMES_ROOT="/opt/commonclaw/runtimes"
FARM="${RUNTIMES_ROOT}/bin"
WORKSPACE_ROOT="/srv/workspaces"

# The row this door writes and reads back. ONE spelling, used by the writer, by
# the pin reader here, and by the provisioning phase that converges a claw to its
# declarations. A second spelling anywhere is a pin store that goes silently
# unreadable.
LOG_INSTALL_ACTION="installed a shared runtime"
LOG_REMOVE_ACTION="removed a shared runtime"

# A bound on what this door will pull down. A wrong URL that answers with
# something enormous fills the disk of a machine whose whole job is holding
# somebody's work. The refusal names the number, so a real runtime that outgrows
# it gets an answer rather than a full filesystem.
MAX_PAYLOAD_BYTES=1073741824      # 1 GiB
MAX_ARCHIVE_MEMBERS=200000
FETCH_TIMEOUT=900

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

# `shift N` returns non-zero when fewer than N arguments remain, and under
# `set -e` that ends the script with status 1 and NOTHING printed. A caller who
# typed `--install` and forgot the name would get silence and a failure code. So
# the count is checked first and the miss is named.
need() {
  [ "$1" -ge "$2" ] || { printf '%s needs %s value(s)\n' "$3" "$(( $2 - 1 ))" >&2; usage; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --install)     need $# 2 "--install <name>-<major>"; MODE="install"; RUNTIME="$2"; shift 2 ;;
    --remove)      need $# 2 "--remove <name>-<major>";  MODE="remove";  RUNTIME="$2"; shift 2 ;;
    --list)        MODE="list"; shift ;;
    --url)         need $# 2 "--url <link>";             URL="$2";       shift 2 ;;
    --sha256)      need $# 2 "--sha256 <64 hex>";        SHA256="$2";    shift 2 ;;
    --declared-ok) DECLARED_OK=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

CHK_DESC=(); CHK_OK=(); NOTES=(); FAILED=0
ACTION="none"; DEST=""; STAGE=""; WORK=""
NAME=""; MAJOR=""; BYTES=0; PROGRAMS=0; LINKS=0
INSTALLED=(); DECLARED=(); PIN_ROWS=(); RECORDED_URL=""; RECORDED_SHA=""

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
  printf '  "script": "manage-runtimes",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "mode": "%s",\n' "$(json_esc "$MODE")"
  printf '  "runtime": "%s",\n' "$(json_esc "$RUNTIME")"
  printf '  "url": "%s",\n' "$(json_esc "$URL")"
  printf '  "sha256": "%s",\n' "$(json_esc "$SHA256")"
  printf '  "bytes": %s,\n' "$BYTES"
  printf '  "programs": %s,\n' "$PROGRAMS"
  printf '  "links": %s,\n' "$LINKS"
  printf '  "action": "%s",\n' "$(json_esc "$ACTION")"
  printf '  "installed": ['
  first=1
  for i in "${INSTALLED[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "$i")"; first=0
  done
  printf '],\n'
  printf '  "declared": ['
  first=1
  for i in "${DECLARED[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "$i")"; first=0
  done
  printf '],\n'
  # THE PIN STORE, READ OUT THROUGH THE ONE PARSER THAT UNDERSTANDS IT. The
  # provisioning phase converges a claw from this array rather than reading the
  # log itself: a second reader of a row this door writes is a second answer to
  # "where did this runtime come from", and the two would drift on the day the
  # row's shape changes.
  printf '  "pins": ['
  first=1
  for i in "${PIN_ROWS[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '%s' "$i"; first=0
  done
  printf '],\n'
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

# The staging tree is inside the runtimes root, so a killed run leaves it there
# rather than in a temp directory nobody looks at. Both are removed on every
# exit path, including a refusal.
cleanup() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  [ -n "${STAGE:-}" ] && rm -rf "$STAGE"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || { say "run this as root"; exit 1; }

[ -n "$MODE" ] || { say "pick one: --install, --remove or --list"; usage; }

# The fetch arguments belong to an install and to nothing else. Accepting them
# silently on a remove would let a caller believe a hash had been checked.
if [ "$MODE" != "install" ] && { [ -n "$URL" ] || [ -n "$SHA256" ]; }; then
  say "--url and --sha256 belong to --install. A ${MODE} fetches nothing, so there are no bytes for them to describe."
  exit 1
fi
if [ "$MODE" != "remove" ] && [ "$DECLARED_OK" -eq 1 ]; then
  say "--declared-ok belongs to a remove. Nothing else here can break a workspace's declaration."
  exit 1
fi

# ---- the runtime name ----
#
# It becomes a directory under a root-owned prefix and a link name on every
# member's PATH, so it is constrained the same way this claw constrains a
# workspace name and a person's name. TWO patterns per part, and the second one
# is the control: a shell case pattern is anchored at both ends, so the positive
# form alone validates the first character and nothing after it.
# ONE validator, two voices. The loud one refuses a caller's argument and names
# the rule it broke; the quiet one filters what a workspace manifest declares,
# where several entries are read at once and the caller reports them together. A
# second copy of these patterns is a second answer to "is this a runtime name".
RID_QUIET=0
rsay() { [ "$RID_QUIET" -eq 1 ] || say "$@"; }

validate_runtime_id() {
  local id="$1"
  [ -n "$id" ] || { rsay "missing the runtime name"; return 1; }
  [ "${#id}" -le 64 ] || { rsay "'${id}' is longer than 64 characters, which no runtime name is"; return 1; }
  case "$id" in
    *-*) : ;;
    *) rsay "'${id}' is not a runtime name: it must be <name>-<major>, for example node-22."; return 1 ;;
  esac
  NAME="${id%-*}"; MAJOR="${id##*-}"
  case "$NAME" in
    [a-z]*) : ;;
    *) rsay "'${NAME}' is not a usable runtime name: it must start with a lowercase letter."; return 1 ;;
  esac
  case "$NAME" in
    *[!a-z0-9-]*) rsay "'${NAME}' is not a usable runtime name: use lowercase letters, digits and hyphen only."; return 1 ;;
  esac
  # The major is digits, and dots are allowed inside it because some runtime
  # lines spell their major with one: python's is 3.12, not 3. A leading or
  # doubled dot is refused, so the value cannot be a relative path.
  case "$MAJOR" in
    [0-9]*) : ;;
    *) rsay "'${MAJOR}' is not a version line: the part after the last hyphen must start with a digit."; return 1 ;;
  esac
  case "$MAJOR" in
    *[!0-9.]*) rsay "'${MAJOR}' is not a version line: use digits and dots only."; return 1 ;;
    *..*) rsay "'${MAJOR}' carries two dots in a row."; return 1 ;;
    *.) rsay "'${MAJOR}' ends in a dot."; return 1 ;;
  esac
  return 0
}

if [ "$MODE" != "list" ]; then
  validate_runtime_id "$RUNTIME" || exit 1
  DEST="${RUNTIMES_ROOT}/${RUNTIME}"
fi

# ---- the record ----
#
# Seeded by provisioning, and a door that finds it missing refuses rather than
# writing its own header: the doors and the file arrive in the same run, so an
# absence means somebody removed it, and an act with nowhere to be recorded
# should not happen quietly. For this door it is sharper than for the others,
# because the row IS the pin: an install nobody recorded cannot be converged
# back after a restore.
if [ "$MODE" != "list" ]; then
  [ -f "$ADMIN_LOG" ] || {
    say "REFUSED: no member-plane record at ${ADMIN_LOG}, so this act has nowhere to be written down."
    say "For this door that record is also the pin store: the row carries the URL and the hash a restore re-derives from."
    say "The log is seeded by provisioning. Run the provisioning plane rather than creating it here."
    exit 1
  }
fi

# ---- the tools ----
missing_tools=""
for t in sha256sum tar; do
  command -v "$t" >/dev/null 2>&1 || missing_tools="${missing_tools} ${t}"
done
if [ "$MODE" = "install" ]; then
  command -v curl >/dev/null 2>&1 || missing_tools="${missing_tools} curl"
fi
[ -z "$missing_tools" ] || {
  say "REFUSED: this claw is missing:${missing_tools}"
  say "Provisioning installs them. Run the provisioning plane rather than fetching them here."
  exit 1
}

# ---------------------------------------------------------------- what is here

# Every installed runtime, newest major first. The order is what decides which
# major owns a bare program name, so it is derived from the version rather than
# from the order a directory listing happens to return.
list_installed() {
  local d
  INSTALLED=()
  [ -d "$RUNTIMES_ROOT" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    INSTALLED+=("$d")
  done < <(find "$RUNTIMES_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
           | grep -v '^bin$' | grep -v '^\.' | LC_ALL=C sort -Vr)
  return 0
}

# The newest install row for one runtime, whether or not a remove followed it.
# A row that survived a remove is still the pin: converging a claw back onto a
# runtime it once carried is the whole reason the URL and the hash are in the
# record rather than in a file somebody could delete.
#
# The log is 0644 root:root, so no member can write a row here. What is parsed
# back is still validated with the same functions that validated it going in,
# because a hand-edited row is a root act and root acts are not always right.
read_pin() {
  local id="$1" row
  RECORDED_URL=""; RECORDED_SHA=""
  [ -f "$ADMIN_LOG" ] || return 0
  row="$(grep -F "| ${LOG_INSTALL_ACTION} | ${id} from " "$ADMIN_LOG" 2>/dev/null | tail -1 || true)"
  [ -n "$row" ] || return 0
  local subject="${row#*| ${LOG_INSTALL_ACTION} | }"
  subject="${subject%% |*}"
  local rest="${subject#${id} from }"
  RECORDED_URL="${rest%% sha256:*}"
  RECORDED_SHA="${rest##* sha256:}"
  case "$RECORDED_SHA" in
    *[!0-9a-f]*|"") RECORDED_URL=""; RECORDED_SHA="" ;;
  esac
  [ "${#RECORDED_SHA}" -eq 64 ] || { RECORDED_URL=""; RECORDED_SHA=""; }
  case "$RECORDED_URL" in
    https://*) : ;;
    *) RECORDED_URL=""; RECORDED_SHA="" ;;
  esac
  return 0
}

# Which workspaces declare this runtime. The manifest is the declaration and the
# only one: a workspace that needs a runtime says so in the file that makes it a
# workspace, so nothing has to be kept in step with it.
#
# Both list forms are read, because both are legitimate YAML and a claw that
# accepted one would refuse a manifest somebody wrote by hand from the other.
declarers_of() {
  local id="$1" man ws out=""
  [ -d "$WORKSPACE_ROOT" ] || { printf ''; return 0; }
  for man in "$WORKSPACE_ROOT"/*/.workspace.yaml; do
    [ -f "$man" ] || continue
    ws="$(basename "$(dirname "$man")")"
    case " $(runtimes_declared_in "$man") " in
      *" ${id} "*) out="${out}${ws} " ;;
    esac
  done
  printf '%s' "$out"
}

# The `runtimes` field of one manifest, as a space-separated list. Flow form
# (`runtimes: [node-22, python-3.12]`) and block form (`runtimes:` then `- node-22`)
# both read; anything that is not a well-formed runtime name is dropped here and
# reported by the caller that cares.
runtimes_declared_in() {
  local man="$1"
  awk '
    /^[[:space:]]*runtimes:[[:space:]]*\[/ {
      line = $0
      sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
      gsub(/,/, " ", line); print line; next
    }
    /^[[:space:]]*runtimes:[[:space:]]*$/ { inblock = 1; next }
    inblock && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
      line = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line); print line; next
    }
    inblock && /^[^[:space:]-]/ { inblock = 0 }
  ' "$man" 2>/dev/null | tr -d '"'\''' | tr '\n' ' '
}

# Every runtime any workspace declares, once each, in the order the manifests
# are read. THIS IS WHAT PROVISIONING CONVERGES TO, and it reads the list out of
# this door's JSON rather than parsing manifests itself: one parser, so the
# declaration a member writes and the set a ride acts on cannot disagree.
#
# A malformed entry is dropped and named. Refusing the whole manifest would let
# one typo take a workspace's other declarations down with it, and silence would
# leave somebody's runtime never arriving with nothing saying why.
collect_declared() {
  local man ws id
  DECLARED=()
  [ -d "$WORKSPACE_ROOT" ] || return 0
  for man in "$WORKSPACE_ROOT"/*/.workspace.yaml; do
    [ -f "$man" ] || continue
    ws="$(basename "$(dirname "$man")")"
    for id in $(runtimes_declared_in "$man"); do
      RID_QUIET=1
      if ! validate_runtime_id "$id"; then
        RID_QUIET=0
        warn "${ws} declares '${id}', which is not a runtime name of the form <name>-<major>. It was ignored."
        continue
      fi
      RID_QUIET=0
      case " ${DECLARED[*]:-} " in *" ${id} "*) continue ;; esac
      DECLARED+=("$id")
    done
  done
  return 0
}

# ---------------------------------------------------------------- the farm
#
# DERIVED FROM WHAT IS INSTALLED, on every run that changes anything. Nothing
# incremental is recorded, so the farm cannot fall out of step with the trees.
#
# THE COST THIS CARRIES, NAMED. Rebuilding moves the bare name to the newest
# installed major, which is a change every member's shell sees at their next
# command. Installing a second major of a runtime therefore moves `node` for
# everybody on the claw, and the run says so rather than leaving it to be
# discovered. The versioned links never move, which is what a project pins
# against when it needs the older line.
rebuild_farm() {
  local id prog target link claimed=" " conflicts=""
  LINKS=0
  install -d -m 0755 -o root -g root "$FARM"

  list_installed
  for id in "${INSTALLED[@]:-}"; do
    [ -n "$id" ] || continue
    [ -d "${RUNTIMES_ROOT}/${id}/bin" ] || continue
    local id_major="${id##*-}"
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      prog="$(basename "$target")"
      # The versioned link. It carries the major, so two majors of one runtime
      # cannot collide on it and a project can name the line it wants.
      link="${FARM}/${prog}-${id_major}"
      if [ -e "$link" ] && [ ! -L "$link" ]; then
        conflicts="${conflicts}${prog}-${id_major} "
      else
        ln -sfn "../${id}/bin/${prog}" "$link"
        LINKS=$(( LINKS + 1 ))
      fi
      # The bare name goes to the first claimant in newest-first order, which is
      # the newest major that ships this program.
      case "$claimed" in
        *" ${prog} "*) continue ;;
      esac
      link="${FARM}/${prog}"
      if [ -e "$link" ] && [ ! -L "$link" ]; then
        conflicts="${conflicts}${prog} "
      else
        ln -sfn "../${id}/bin/${prog}" "$link"
        claimed="${claimed}${prog} "
        LINKS=$(( LINKS + 1 ))
      fi
    done < <(find "${RUNTIMES_ROOT}/${id}/bin" -mindepth 1 -maxdepth 1 \
                  \( -type f -o -type l \) -executable -print 2>/dev/null | LC_ALL=C sort)
  done

  # Every link that no longer resolves into an installed tree comes off. This is
  # what makes a remove safe: a bare `node` pointing into a directory that is
  # gone would be on every member's PATH and would fail at every invocation.
  for link in "$FARM"/*; do
    [ -e "$link" ] || [ -L "$link" ] || continue
    if [ ! -L "$link" ]; then
      conflicts="${conflicts}$(basename "$link") "
      continue
    fi
    [ -e "$link" ] || { rm -f "$link"; continue; }
    case "$(readlink -f "$link")" in
      "${RUNTIMES_ROOT}"/*) : ;;
      *) rm -f "$link" ;;
    esac
  done

  if [ -n "$conflicts" ]; then
    bad "the farm holds real file(s) where links belong: ${conflicts}-- somebody put them there by hand and this door will not delete them"
  fi
  return 0
}

# ---------------------------------------------------------------- list

# Reads the pin and remembers it for the JSON. The read comes FIRST and happens
# every time: the caller prints RECORDED_URL and RECORDED_SHA straight after,
# and an early return that skipped the read would leave it printing the previous
# runtime's pin against this one's name.
add_pin_row() {
  local id="$1"
  read_pin "$id"
  [ -n "$RECORDED_SHA" ] || return 0
  case " $(printf '%s' "${PIN_ROWS[*]:-}") " in
    *"\"runtime\": \"${id}\""*) return 0 ;;
  esac
  PIN_ROWS+=("{\"runtime\": \"$(json_esc "$id")\", \"url\": \"$(json_esc "$RECORDED_URL")\", \"sha256\": \"$(json_esc "$RECORDED_SHA")\"}")
  return 0
}

if [ "$MODE" = "list" ]; then
  ACTION="listed"
  list_installed
  say ""
  say "=== shared runtimes on this claw ==="
  say "  root: ${RUNTIMES_ROOT}"
  say "  PATH: ${FARM}"
  say ""
  if [ "${#INSTALLED[@]}" -eq 0 ]; then
    say "  none installed."
  else
    for id in "${INSTALLED[@]}"; do
      n="$(find "${RUNTIMES_ROOT}/${id}/bin" -mindepth 1 -maxdepth 1 -executable 2>/dev/null | wc -l)"
      add_pin_row "$id"
      say "  ${id}"
      say "    programs: ${n}"
      if [ -n "$RECORDED_SHA" ]; then
        say "    pinned:   ${RECORDED_URL}"
        say "    sha256:   ${RECORDED_SHA}"
      else
        say "    pinned:   NO INSTALL ROW IN ${ADMIN_LOG} -- a restore cannot re-derive this one"
      fi
    done
  fi
  say ""
  say "=== what the workspaces declare ==="
  collect_declared
  if [ "${#DECLARED[@]}" -eq 0 ]; then
    say "  no workspace declares a runtime."
  else
    for id in "${DECLARED[@]}"; do
      if [ -d "${RUNTIMES_ROOT}/${id}" ]; then
        say "  ${id} -- installed, declared by: $(declarers_of "$id")"
      else
        add_pin_row "$id"
        if [ -n "$RECORDED_SHA" ]; then
          say "  ${id} -- NOT installed, declared by: $(declarers_of "$id")"
          say "     a ride converges this one from the recorded pin"
        else
          say "  ${id} -- NOT installed and NOT recorded, declared by: $(declarers_of "$id")"
          say "     no ride can satisfy this: give it a URL and a hash once, with --install"
        fi
      fi
    done
  fi
  say ""
  say "  Reading is not an act on this claw, so nothing was recorded."
  finish
fi

# ---------------------------------------------------------------- the caller

BY="${SUDO_USER:-$(id -un)}"
case "$BY" in
  [a-z_]*) : ;;
  *) BY="root" ;;
esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac
WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------- remove

if [ "$MODE" = "remove" ]; then
  say ""
  say "=== remove ${RUNTIME} ==="
  say "  path: ${DEST}"
  say "  by:   ${BY}"
  say ""

  if [ ! -d "$DEST" ]; then
    ACTION="unchanged"
    list_installed
    say "  nothing is installed at ${DEST}. Nothing changed and no row was written."
    if [ "${#INSTALLED[@]}" -gt 0 ]; then
      say "  installed here: ${INSTALLED[*]}"
    else
      say "  this claw carries no shared runtime at all."
    fi
    warn "no runtime named ${RUNTIME} is installed on this claw"
    finish
  fi

  # THE REFUSAL RUNS BEFORE THE DRY-RUN BRANCH, deliberately. A rehearsal that
  # passes where the real run refuses is a plan nobody can execute reading as a
  # plan that was checked.
  DECLARERS="$(declarers_of "$RUNTIME")"
  if [ -n "${DECLARERS// /}" ] && [ "$DECLARED_OK" -ne 1 ]; then
    say "REFUSED: ${RUNTIME} is declared by: ${DECLARERS}"
    say ""
    say "  A manifest naming a runtime is that workspace saying its work needs it."
    say "  Removing it takes the runtime out from under work that says it depends on it,"
    say "  and the next provisioning run will try to put it back from the recorded pin."
    say ""
    say "  If the removal IS the intent -- the declaration is stale, or the work is done --"
    say "  drop the runtimes line from those manifests, or say so here:"
    say ""
    say "    sudo $(basename "$0") --remove ${RUNTIME} --declared-ok"
    say ""
    exit 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    ACTION="would-remove"
    say "  would remove ${DEST} and rebuild ${FARM} from what is left"
    say "  would append one row to ${ADMIN_LOG}"
    warn "dry run: nothing was changed"
    finish
  fi

  rm -rf "$DEST"
  rebuild_farm
  ACTION="removed"
  LOG_ACTION="$LOG_REMOVE_ACTION"
  LOG_SUBJECT="$RUNTIME"
  [ -n "${DECLARERS// /}" ] && LOG_SUBJECT="${RUNTIME}, still declared by ${DECLARERS% }"

  printf '| %s | %s | %s | %s |\n' "$WHEN" "$BY" "$LOG_ACTION" "$LOG_SUBJECT" >> "$ADMIN_LOG"

  say ""
  say "=== VERIFY ==="
  check_gone() { [ ! -e "$DEST" ]; }
  if check_gone; then ok "${DEST} is gone"; else bad "${DEST} is still on disk"; fi

  dangling=""
  for link in "$FARM"/*; do
    [ -L "$link" ] || continue
    [ -e "$link" ] || dangling="${dangling}$(basename "$link") "
  done
  if [ -z "$dangling" ]; then
    ok "every link in ${FARM} resolves: the removal left nothing broken on a member's PATH"
  else
    bad "dangling link(s) in ${FARM}: ${dangling}"
  fi

  if [ "$(tail -1 "$ADMIN_LOG")" = "| ${WHEN} | ${BY} | ${LOG_ACTION} | ${LOG_SUBJECT} |" ]; then
    ok "one row appended to ${ADMIN_LOG}"
  else
    bad "the member-plane log does not end with this act's row"
  fi

  read_pin "$RUNTIME"
  if [ -n "$RECORDED_SHA" ]; then
    ok "the install row survives the removal, so provisioning can converge this runtime back from the record"
  else
    warn "no install row for ${RUNTIME} in ${ADMIN_LOG}: putting it back needs its URL and hash again"
  fi

  say ""
  say "  A MEMBER'S OPEN SESSION KEEPS THE BINARY IT ALREADY EXECUTED."
  say "  Removal takes the path away and leaves running processes where they are."
  if [ -n "${DECLARERS// /}" ]; then
    say ""
    say "  STILL DECLARED BY: ${DECLARERS}"
    say "  The next provisioning ride reads those manifests and reinstalls it from the recorded pin."
    say "  Drop the runtimes line from them if that is not what you want."
    warn "${RUNTIME} was removed while ${DECLARERS% } still declares it"
  fi
  finish
fi

# ---------------------------------------------------------------- install

# All three, and the refusal names what is missing and why the door will not
# proceed without it.
if [ -z "$URL" ] || [ -z "$SHA256" ]; then
  [ -z "$URL" ]    && say "REFUSED: --install needs --url. This door has no default source and no 'latest'."
  [ -z "$SHA256" ] && say "REFUSED: --install needs --sha256. Fetching bytes nobody vouched for is a download, not an install."
  say ""
  say "  sudo $(basename "$0") --install ${RUNTIME} --url <link> --sha256 <64 hex>"
  say ""
  say "  The hash is the caller's claim about which bytes these are. This door checks the"
  say "  bytes against it before anything lands, and records both in ${ADMIN_LOG} forever."
  exit 1
fi

case "$URL" in
  https://*) : ;;
  *) say "REFUSED: '${URL}' is not an https URL. A runtime this claw runs is not fetched over a channel anybody can rewrite."; exit 1 ;;
esac
[ "${#URL}" -le 2048 ] || { say "REFUSED: the URL is longer than 2048 characters."; exit 1; }
case "$URL" in
  *[[:space:]]*) say "REFUSED: the URL carries whitespace."; exit 1 ;;
  *[![:print:]]*) say "REFUSED: the URL carries a control character."; exit 1 ;;
esac

SHA256="$(printf '%s' "$SHA256" | tr 'A-F' 'a-f')"
case "$SHA256" in
  *[!0-9a-f]*) say "REFUSED: '${SHA256}' is not a sha256: it carries characters no hex digest holds."; exit 1 ;;
esac
[ "${#SHA256}" -eq 64 ] || {
  say "REFUSED: '${SHA256}' is ${#SHA256} characters; a sha256 is 64."
  say "Read one with: sha256sum <file>, or from the vendor's own checksums file."
  exit 1
}

say ""
say "=== install ${RUNTIME} ==="
say "  path:   ${DEST}"
say "  url:    ${URL}"
say "  sha256: ${SHA256}"
say "  by:     ${BY}"
say ""

# ---- idempotency, and the refusal beside it ----
#
# Three states, and they are not the same act. An identical payload already in
# place is a converged claw and writes no row. A different payload under the same
# name is a replacement, which members hold open sessions against. A tree with no
# row behind it is a runtime this claw cannot re-derive after a restore, and
# neither of those is this door's to resolve quietly.
read_pin "$RUNTIME"
if [ -d "$DEST" ]; then
  if [ "$RECORDED_SHA" = "$SHA256" ] && [ "$RECORDED_URL" = "$URL" ]; then
    ACTION="unchanged"
    say "  ${RUNTIME} is already installed from exactly these bytes. Nothing was fetched and no row was written."
    warn "the runtime was already installed from this URL and hash, so nothing was fetched or recorded"
    # THE FARM IS STILL REBUILT, and this is the one place where "unchanged"
    # can change something. The farm is derived, so rebuilding it repairs a link
    # somebody deleted by hand; a re-install is the cheapest way anybody has to
    # ask for that repair. The line below says what it did rather than leaving
    # a run that reported no change to have quietly made one.
    if [ "$DRY_RUN" -eq 0 ]; then
      rebuild_farm
      say "  ${FARM} rebuilt from what is installed (${LINKS} link(s)). The farm is derived, so this repairs a link somebody removed."
    fi
    finish
  fi
  say "REFUSED: ${DEST} already exists and does not carry these bytes."
  if [ -n "$RECORDED_SHA" ]; then
    say ""
    say "  installed pin: ${RECORDED_URL}"
    say "                 sha256:${RECORDED_SHA}"
    say "  offered pin:   ${URL}"
    say "                 sha256:${SHA256}"
  else
    say ""
    say "  There is no install row for ${RUNTIME} in ${ADMIN_LOG}, so this claw cannot say where"
    say "  the tree on disk came from. That is the state a restore cannot reproduce."
  fi
  say ""
  say "  Replacing a runtime under members who hold open sessions on it is a decision, not a retry:"
  say ""
  say "    sudo $(basename "$0") --remove ${RUNTIME}"
  say "    sudo $(basename "$0") --install ${RUNTIME} --url ${URL} --sha256 ${SHA256}"
  say ""
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  ACTION="would-install"
  say "  would fetch ${URL} (at most ${MAX_PAYLOAD_BYTES} bytes)"
  say "  would refuse unless the bytes hash to ${SHA256}"
  say "  would unpack to ${DEST}, root-owned 0755, and rebuild ${FARM}"
  say "  would append one row to ${ADMIN_LOG}"
  warn "dry run: nothing was fetched and nothing was changed"
  finish
fi

# ---- the fetch ----
#
# INTO A ROOT-ONLY DIRECTORY. The payload is unverified until the next step, and
# an unverified payload sitting where a member can read or replace it is a file
# this door would then hash and install.
install -d -m 0755 -o root -g root "$RUNTIMES_ROOT"
WORK="$(mktemp -d)"; chmod 0700 "$WORK"
PAYLOAD="${WORK}/payload"

say "  fetching..."
if ! curl --proto '=https' --tlsv1.2 --location --fail --silent --show-error \
          --max-time "$FETCH_TIMEOUT" --max-filesize "$MAX_PAYLOAD_BYTES" \
          --output "$PAYLOAD" "$URL" 2>"${WORK}/curl.err"; then
  say "REFUSED: the fetch failed."
  sed 's/^/    /' "${WORK}/curl.err" >&2 2>/dev/null || true
  say "  Nothing was installed and no row was written."
  exit 1
fi

[ -s "$PAYLOAD" ] || { say "REFUSED: the fetch returned an empty file."; exit 1; }
BYTES="$(stat -c %s "$PAYLOAD")"
[ "$BYTES" -le "$MAX_PAYLOAD_BYTES" ] || {
  say "REFUSED: the payload is ${BYTES} bytes, past the ${MAX_PAYLOAD_BYTES} this door installs."
  exit 1
}

# ---- the integrity check, and it comes before anything is examined ----
#
# THE ONE THING THIS DOOR IS FOR. Nothing has been unpacked, nothing has been
# read as an archive, and nothing is on the runtime path. A tar listing of an
# unverified payload is already trusting bytes nobody vouched for.
GOT="$(sha256sum "$PAYLOAD" | awk '{print $1}')"
if [ "$GOT" != "$SHA256" ]; then
  say "REFUSED: THE BYTES ARE NOT THE BYTES YOU VOUCHED FOR."
  say ""
  say "  expected: ${SHA256}"
  say "  received: ${GOT}"
  say "  from:     ${URL}"
  say "  size:     ${BYTES} bytes"
  say ""
  say "  The payload was deleted unread. Nothing was installed and no row was written."
  say "  Either the hash is wrong, or what that URL serves today is not what it served"
  say "  when the hash was taken. Both are answered off this claw, not on it."
  exit 1
fi
ok "the payload hashes to the sha256 the caller supplied (${BYTES} bytes)"

# ---- the archive's shape ----
#
# Read only after the hash matched. Every refusal here is about what the tree
# would look like on the claw, not about what the payload claims to be.
LISTING="${WORK}/listing"
if ! tar -tf "$PAYLOAD" > "$LISTING" 2>"${WORK}/tar.err"; then
  say "REFUSED: this is not a tar archive this claw can read."
  sed 's/^/    /' "${WORK}/tar.err" >&2 2>/dev/null || true
  say "  Supported: a tar archive, compressed or not. A zip or an installer is not one."
  exit 1
fi

MEMBERS="$(wc -l < "$LISTING")"
[ "$MEMBERS" -gt 0 ] || { say "REFUSED: the archive is empty."; exit 1; }
[ "$MEMBERS" -le "$MAX_ARCHIVE_MEMBERS" ] || {
  say "REFUSED: the archive holds ${MEMBERS} entries, past the ${MAX_ARCHIVE_MEMBERS} this door unpacks."
  exit 1
}

# An absolute path or a `..` segment is an archive that writes outside the tree
# it is unpacked into. GNU tar strips and warns about both; this door refuses
# instead, because a warning on a machine nobody is watching is a silent accept.
if grep -qE '^/|(^|/)\.\.(/|$)' "$LISTING"; then
  say "REFUSED: the archive carries an absolute path or a '..' segment, so unpacking it would write outside ${DEST}."
  exit 1
fi

TOPS="$(sed 's#/.*##' "$LISTING" | LC_ALL=C sort -u | grep -v '^$' || true)"
if [ "$(printf '%s\n' "$TOPS" | wc -l)" -ne 1 ]; then
  say "REFUSED: the archive has more than one top-level entry: $(printf '%s' "$TOPS" | tr '\n' ' ')"
  say "  This door unpacks one runtime directory. An archive that spreads across several is not one."
  exit 1
fi
TOP="$TOPS"

# A runtime with no `bin` is inert here: the farm is what puts it on a member's
# PATH, and the farm is built from that directory alone.
# Matched by position rather than by pattern: the top-level directory carries
# whatever characters the vendor chose, and a runtime named `node-v22.23.2` puts
# three regex metacharacters into a check that would then quietly over-match.
if ! awk -v p="${TOP}/bin/" 'index($0, p) == 1 && length($0) > length(p) { found = 1; exit } END { exit !found }' "$LISTING"; then
  say "REFUSED: the archive carries no ${TOP}/bin/ directory."
  say "  This door puts a runtime on every member's PATH through ${FARM}, which links what is in bin/."
  say "  An archive with no bin/ would install a tree nobody can reach by name."
  exit 1
fi

# ---- unpack, then land ----
#
# STAGED INSIDE THE RUNTIMES ROOT so the move onto the final path is a rename
# within one directory: atomic, so a kill at any moment leaves either no runtime
# or a whole one, never half of one on a member's PATH.
#
# The ownership rule this claw learned under /srv does not bite here -- both
# sides are root:root with no setgid anywhere -- but the reason it does not is
# worth being explicit about, because the shape is the same one that dropped a
# workspace's group: a tree created somewhere else and moved in carries its own
# ownership with it. So ownership is set here, on this side of the move.
STAGE="${RUNTIMES_ROOT}/.staging-${RUNTIME}.$$"
rm -rf "$STAGE"
install -d -m 0755 -o root -g root "$STAGE"
say "  unpacking..."
if ! tar -xf "$PAYLOAD" -C "$STAGE" --strip-components=1 --no-same-owner --no-same-permissions 2>"${WORK}/untar.err"; then
  say "REFUSED: unpacking failed."
  sed 's/^/    /' "${WORK}/untar.err" >&2 2>/dev/null || true
  exit 1
fi

chown -R root:root "$STAGE"
# Readable and traversable by every member, writable by root alone. `a+rX` sets
# the execute bit on directories and on files that already carry one, so the
# runtime's own binaries stay executable and its data files do not become so.
chmod -R a+rX,go-w "$STAGE"

PROGRAMS="$(find "${STAGE}/bin" -mindepth 1 -maxdepth 1 -executable 2>/dev/null | wc -l)"
[ "$PROGRAMS" -gt 0 ] || {
  say "REFUSED: ${TOP}/bin holds no executable file, so this runtime puts nothing on a member's PATH."
  exit 1
}

mv "$STAGE" "$DEST"
STAGE=""
rebuild_farm

# ---------------------------------------------------------------- the record

# One row, one append, one call. The caller behind sudo, never root, because a
# record of who decided is the point. The subject carries the URL and the hash:
# this door checked the bytes against that hash, and the row is the only place
# this claw says who vouched for it and what they pointed at.
ACTION="installed"
LOG_ACTION="$LOG_INSTALL_ACTION"
LOG_SUBJECT="${RUNTIME} from ${URL} sha256:${SHA256}"
printf '| %s | %s | %s | %s |\n' "$WHEN" "$BY" "$LOG_ACTION" "$LOG_SUBJECT" >> "$ADMIN_LOG"

# ---------------------------------------------------------------- verify

say ""
say "=== VERIFY ==="

# Read the tree back rather than trusting the write.
if [ -d "$DEST" ] && [ "$(stat -c '%a %U:%G' "$DEST")" = "755 root:root" ]; then
  ok "${DEST} is 0755 root:root"
else
  bad "${DEST} is $(stat -c '%a %U:%G' "$DEST" 2>/dev/null || echo absent), wanted 755 root:root"
fi

# SYMLINKS ARE EXCLUDED, and the reason is not a convenience. A symlink's own
# mode bits are 777 on Linux and cannot be changed; what decides access is the
# target, which this scan reaches through its own path. Measured in this door's
# rig on 2026-08-16: node's `bin/npm` is a symlink, so the scan reported the
# runtime as world-writable on every install and the door failed its own verify
# on a tree that was correct.
writable="$(find "$DEST" ! -type l -perm /022 -print -quit 2>/dev/null || true)"
if [ -z "$writable" ]; then
  ok "nothing under ${DEST} is writable by anybody but root"
else
  bad "group- or world-writable path under ${DEST}: ${writable}"
fi

if [ "$(find "${DEST}/bin" -mindepth 1 -maxdepth 1 -executable 2>/dev/null | wc -l)" -eq "$PROGRAMS" ]; then
  ok "${PROGRAMS} program(s) in ${DEST}/bin, the same number that survived the unpack"
else
  bad "the program count under ${DEST}/bin changed between the unpack and now"
fi

# The farm is the half a member actually touches, so it is measured rather than
# assumed: every link resolves, and at least one of them points into this tree.
dangling=""; mine=0
for link in "$FARM"/*; do
  [ -L "$link" ] || continue
  if [ ! -e "$link" ]; then dangling="${dangling}$(basename "$link") "; continue; fi
  case "$(readlink -f "$link")" in
    "${DEST}"/*) mine=$(( mine + 1 )) ;;
  esac
done
if [ -z "$dangling" ]; then
  ok "every link in ${FARM} resolves"
else
  bad "dangling link(s) in ${FARM}: ${dangling}"
fi
if [ "$mine" -gt 0 ]; then
  ok "${mine} link(s) in ${FARM} point into ${RUNTIME}, so it is reachable by name"
else
  bad "no link in ${FARM} points into ${RUNTIME}, so nothing on a member's PATH reaches it"
fi

if [ "$(tail -1 "$ADMIN_LOG")" = "| ${WHEN} | ${BY} | ${LOG_ACTION} | ${LOG_SUBJECT} |" ]; then
  ok "one row appended to ${ADMIN_LOG}"
else
  bad "the member-plane log does not end with this act's row"
fi

# THE PIN, READ BACK THROUGH THE SAME PARSER PROVISIONING USES. A row that this
# door writes and its own reader cannot parse is a runtime no restore can
# re-derive, and nothing else on the claw would ever say so.
read_pin "$RUNTIME"
if [ "$RECORDED_SHA" = "$SHA256" ] && [ "$RECORDED_URL" = "$URL" ]; then
  ok "the recorded pin reads back as the URL and hash this run installed"
else
  bad "the recorded pin does not read back: url '${RECORDED_URL}', sha256 '${RECORDED_SHA}'"
fi

say ""
say "  ${RUNTIME} is on ${FARM}. A member picks it up at their NEXT LOGIN, because"
say "  the PATH entry is a /etc/profile.d drop-in and a shell reads that when it starts."
say "  Anything unattended -- a systemd unit, a cron entry, a non-login ssh command --"
say "  gets no PATH from that file and names ${FARM}/<program> in full."
say ""
say "  Dependencies stay project-local. This is the runtime, not the project's packages:"
say "  ${ADMIN_LOG} and /etc/commonclaw/runtimes.md both say why."

finish
