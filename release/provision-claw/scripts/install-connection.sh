#!/bin/bash
#
# install-connection.sh: stand one connection service on this claw.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
#
# USAGE
#   sudo ./install-connection.sh <name>
#   sudo ./install-connection.sh <name> --manifest FILE
#   sudo ./install-connection.sh <name> --dry-run
#
# WHAT A CONNECTION SERVICE IS. One process that holds a credential for the
# whole firm and hands a calling session what it needs over a UNIX socket. The
# author of a service writes the program, its adapters and a short manifest.
# This script writes everything else, the same way for every service:
#
#   the account     svc-{name}, a system account with no shell
#   the home        /srv/connections/{name}/, with state/ and log/
#   the conf        /etc/commonclaw/conn-{name}.conf, adopted as it stands
#   the references  /etc/commonclaw/conn-{name}.env, for a service that reads
#                   a vault, holding references and never values
#   the data key    /etc/commonclaw/credentials/conn-{name}-key.cred, 32 bytes
#                   minted once and sealed by the host key
#   the units       commonclaw-conn-{name}.service and .socket
#   the socket      /run/commonclaw-conn-{name}/sock
#   the program     /opt/commonclaw/bin/commonclaw-conn-{name}
#   the library     /opt/commonclaw/lib/python/commonclaw_connection
#
# THE MANIFEST is payload/connection/{name}/manifest unless --manifest names
# another. One KEY="value" per line, read as data and never sourced:
#
#   NAME          the connection's name, equal to the argument
#   PROGRAM       the program, relative to the manifest's directory
#   READS_VAULT   yes when the service resolves a reference through the claw's
#                 machine credential. Only then does the unit carry it
#   POSTS_BUS     yes when the service posts to the session bus. Only then is
#                 the account put in claw-bus
#   SOCKET_GROUP  the socket's group when the conf is first seeded
#   ADAPTERS      optional: a directory of adapters beside the program
#   CONF          optional: the program's own conf keys, appended to the
#                 shared ones when the conf is seeded
#   ENV           optional: the env template for a service that reads a vault.
#                 {{VAULT}} and {{HOSTNAME}} are filled in
#   COMMAND       optional: the member command, a file beside the manifest. Its
#                 name is the name a person types: it installs as
#                 /opt/commonclaw/bin/commonclaw-conn-{name}-command, and
#                 /usr/local/bin/{COMMAND} links to it
#
# A SERVICE ACCOUNT IS NEVER A PERSON AND NEVER IN A PEOPLE GROUP. It is made
# with `useradd --system`, which allocates below the login range, and this run
# refuses to finish when the account it got is a person by scripts/person.sh.
# It joins claw-bus, the group that may post to the bus, when the manifest says
# it posts. It joins no other group.
#
# ADOPTION, NOT REVERSION. A re-run adopts what it finds: the conf and the env
# keep every key they have and gain a missing one with its shipped default, a
# data key that is present is never minted again, and a unit somebody disabled
# stays disabled. A second run changes nothing and says so.
#
# NOT READY IS NOT A FAILURE. A connection nobody has wired yet reads not-ready
# in its health line, and this script prints that line as a note.
#
# EXIT CODES. 0 the connection is installed and enabled. 1 something this
# script owns did not take, or a refusal. 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${HERE}/../payload/connection"
TEMPLATE_DIR="${HERE}/../templates"
LIB_SRC="${PAYLOAD_DIR}/lib/commonclaw_connection"

# A SCRATCH ROOT FOR THE CONTROLS. Every path this script writes lies under it,
# and the text of a unit it renders names the real paths. Nothing on a claw
# sets it.
R="${COMMONCLAW_CONN_ROOT:-}"

NAME=""; MANIFEST=""; MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --dry-run)  MODE="dry-run"; shift ;;
    -h|--help)  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
    -*)         printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    *)          if [ -z "$NAME" ]; then NAME="$1"; shift
                else printf 'one connection per run: %s is a second name\n' "$1" >&2; exit 2; fi ;;
  esac
done

FAILED=0
CHANGED=0
DRY=""; [ "$MODE" = dry-run ] && DRY="would "
ok()   { printf '  ok    %s\n' "$1" >&2; }
warn() { printf '  note  %s\n' "$1" >&2; }
bad()  { printf '  BAD   %s\n' "$1" >&2; FAILED=1; }
did()  { printf '  did   %s\n' "$1" >&2; CHANGED=$((CHANGED + 1)); }

STATE="unknown"
HEALTH="{}"
verdict() {  # verdict <stage>
  # The name as typed may carry anything, so the JSON carries only the
  # characters a connection name may hold.
  local jn
  jn="$(printf '%s' "$NAME" | tr -cd 'a-z0-9-')"
  printf '{"ok":%s,"mode":"%s","stage":"%s","connection":"%s","account":"%s","unit":"%s","changed":%d,"state":"%s","health":%s}\n' \
    "$([ "$FAILED" = 0 ] && echo true || echo false)" "$MODE" "$1" "$jn" \
    "svc-${jn}" "commonclaw-conn-${jn}.service" "$CHANGED" "$STATE" "$HEALTH"
}
refuse() {   # refuse <stage> <sentence> [exit]
  bad "$2"
  verdict "$1"
  exit "${3:-1}"
}

# ------------------------------------------------------------------ the name
#
# Lowercase letters, digits and hyphens, because the name becomes an account, a
# unit, a directory and a credential's name at once, and each of those has its
# own rules. 28 characters leaves `svc-` room inside useradd's 32. `lib` is the
# shared code's directory beside the manifests.
[ -n "$NAME" ] || { printf 'usage: install-connection.sh <name> [--manifest FILE] [--dry-run]\n' >&2; exit 2; }
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || refuse name "'${NAME}' is not a connection name: lowercase letters, digits and hyphens only, starting with a letter or a digit" 2
[ "${#NAME}" -le 28 ] || refuse name "'${NAME}' is ${#NAME} characters; a connection name is 28 at most, so svc-${NAME} fits an account name" 2
[ "$NAME" != lib ] || refuse name "'lib' is the shared code's directory and cannot name a connection" 2

[ "$(id -u)" = 0 ] || refuse root "this makes an account and writes /etc, /opt, /srv and systemd, so it needs root" 2

ACCOUNT="svc-${NAME}"
UNIT="commonclaw-conn-${NAME}.service"
SOCK_UNIT="commonclaw-conn-${NAME}.socket"
BIN_DIR="${R}/opt/commonclaw/bin"
PROGRAM_DEST="${BIN_DIR}/commonclaw-conn-${NAME}"
ADAPTERS_DEST="${PROGRAM_DEST}-adapters"
LIB_ROOT="${R}/opt/commonclaw/lib/python"
LIB_DEST="${LIB_ROOT}/commonclaw_connection"
CONN_ROOT="${R}/srv/connections"
HOME_DIR="${CONN_ROOT}/${NAME}"
ETC="${R}/etc/commonclaw"
CONF="${ETC}/conn-${NAME}.conf"
ENVF="${ETC}/conn-${NAME}.env"
CRED_DIR="${ETC}/credentials"
CRED="${CRED_DIR}/conn-${NAME}-key.cred"
CRED_NAME="conn-${NAME}-key"
UNIT_DIR="${R}/etc/systemd/system"
BUS_DIR="/var/lib/commonclaw/bus"
BUS_GROUP="claw-bus"
PEOPLE_GROUP="claw-members"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-connection.XXXXXX")" || refuse work "no scratch directory could be made"
trap 'rm -rf -- "$WORK"' EXIT

printf 'install-connection: %s (%s)\n' "$NAME" "$MODE" >&2

# ------------------------------------------------------------- the manifest
[ -n "$MANIFEST" ] || MANIFEST="${PAYLOAD_DIR}/${NAME}/manifest"
[ -r "$MANIFEST" ] || refuse manifest "no manifest at ${MANIFEST}. A connection ships one beside its program"
MDIR="$(cd "$(dirname "$MANIFEST")" && pwd)"

M_NAME=""; M_PROGRAM=""; M_READS_VAULT=""; M_POSTS_BUS=""; M_SOCKET_GROUP=""
M_ADAPTERS=""; M_CONF=""; M_ENV=""; M_COMMAND=""
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] \
    || refuse manifest "${MANIFEST} line ${lineno} is not KEY=\"value\""
  k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
  v="${v%%[[:space:]]#*}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; esac
  case "$k" in
    NAME)         M_NAME="$v" ;;
    PROGRAM)      M_PROGRAM="$v" ;;
    READS_VAULT)  M_READS_VAULT="$v" ;;
    POSTS_BUS)    M_POSTS_BUS="$v" ;;
    SOCKET_GROUP) M_SOCKET_GROUP="$v" ;;
    ADAPTERS)     M_ADAPTERS="$v" ;;
    CONF)         M_CONF="$v" ;;
    ENV)          M_ENV="$v" ;;
    COMMAND)      M_COMMAND="$v" ;;
    *) refuse manifest "${MANIFEST} line ${lineno} names ${k}, which a manifest does not carry" ;;
  esac
done < "$MANIFEST"

[ "$M_NAME" = "$NAME" ] || refuse manifest "${MANIFEST} names the connection '${M_NAME}', and this run was asked for '${NAME}'"
for pair in "READS_VAULT:${M_READS_VAULT}" "POSTS_BUS:${M_POSTS_BUS}"; do
  case "${pair#*:}" in yes|no) : ;; *) refuse manifest "${MANIFEST} says ${pair%%:*}='${pair#*:}'; it is yes or no" ;; esac
done
[[ "$M_SOCKET_GROUP" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || refuse manifest "${MANIFEST} says SOCKET_GROUP='${M_SOCKET_GROUP}', which is not a group name"
# THE MANIFEST'S PATHS STAY BESIDE IT. A path that climbs out would install a
# file nobody reviewed as this connection's.
for pair in "PROGRAM:${M_PROGRAM}" "ADAPTERS:${M_ADAPTERS}" "CONF:${M_CONF}" "ENV:${M_ENV}"; do
  p="${pair#*:}"
  [ -z "$p" ] && continue
  case "$p" in /*|..|../*|*/..|*/../*) refuse manifest "${MANIFEST} says ${pair%%:*}='${p}'; a manifest names paths inside its own directory" ;; esac
done
[ -n "$M_PROGRAM" ] || refuse manifest "${MANIFEST} names no PROGRAM"
PROGRAM_SRC="${MDIR}/${M_PROGRAM}"
[ -f "$PROGRAM_SRC" ] && [ -x "$PROGRAM_SRC" ] || refuse manifest "the program ${PROGRAM_SRC} is missing or not executable"
[ -z "$M_ADAPTERS" ] || [ -d "${MDIR}/${M_ADAPTERS}" ] || refuse manifest "the adapters directory ${MDIR}/${M_ADAPTERS} is missing"
[ -z "$M_CONF" ] || [ -r "${MDIR}/${M_CONF}" ] || refuse manifest "the conf fragment ${MDIR}/${M_CONF} is missing"
[ -z "$M_ENV" ] || [ -r "${MDIR}/${M_ENV}" ] || refuse manifest "the env template ${MDIR}/${M_ENV} is missing"
# THE COMMAND'S NAME IS WHAT A PERSON TYPES, so it is a plain word and the file
# of that name sits beside the manifest.
if [ -n "$M_COMMAND" ]; then
  [[ "$M_COMMAND" =~ ^[a-z][a-z0-9-]{0,31}$ ]] \
    || refuse manifest "${MANIFEST} says COMMAND='${M_COMMAND}'; a command is one word of lowercase letters, digits and hyphens"
  [ -f "${MDIR}/${M_COMMAND}" ] && [ -x "${MDIR}/${M_COMMAND}" ] \
    || refuse manifest "the command ${MDIR}/${M_COMMAND} is missing or not executable"
fi
ok "the manifest names ${NAME}: reads a vault ${M_READS_VAULT}, posts to the bus ${M_POSTS_BUS}, socket group ${M_SOCKET_GROUP}"

# ---------------------------------------------------------- the stage itself
for f in "${LIB_SRC}/__init__.py" "${TEMPLATE_DIR}/commonclaw-conn.service" \
         "${TEMPLATE_DIR}/commonclaw-conn.socket" "${HERE}/person.sh"; do
  [ -r "$f" ] || refuse payload "no ${f}. Run this from an assembled stage"
done
# shellcheck source=person.sh
. "${HERE}/person.sh"

# in_group <group> <account> ; 0 when the group's row lists the account
in_group() {
  local members
  members="$(cc_group_members "$1")"
  case $'\n'"${members}"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}

# mode_owner <path> ; "<octal mode> <user>:<group>"
mode_owner() { stat -c '%a %U:%G' "$1" 2>/dev/null; }

# put_file <src> <dest> <mode> ; root-owned, installed when the bytes, the mode
# or the owner differ
put_file() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest" \
     && [ "$(mode_owner "$dest")" = "${mode#0} root:root" ]; then
    return 0
  fi
  if [ "$MODE" = dry-run ]; then did "${DRY}install ${dest}"; return 0; fi
  if install -m "$mode" "$src" "$dest" && chown root:root "$dest"; then
    did "installed ${dest}"
  else
    bad "${dest} could not be installed"
  fi
}

# make_dir <path> <mode> <owner:group> ; a directory other rails share, made
# only when it is absent. Its mode and owner are not this script's to rule on.
make_dir() {
  [ -d "$1" ] && return 0
  ensure_dir "$@"
}

# ensure_dir <path> <mode> <owner:group> ; a directory this connection owns,
# held at its mode and owner
ensure_dir() {
  local p="$1" mode="$2" own="$3" have
  if [ -d "$p" ]; then
    have="$(mode_owner "$p")"
    [ "$have" = "${mode#0} ${own}" ] && return 0
    if [ "$MODE" = dry-run ]; then did "${DRY}set ${p} to ${mode} ${own}; it is ${have}"; return 0; fi
    if chmod "$mode" "$p" && chown "$own" "$p"; then
      did "set ${p} to ${mode} ${own}; it was ${have}"
    else
      bad "${p} could not be set to ${mode} ${own}"
    fi
  else
    if [ "$MODE" = dry-run ]; then did "${DRY}create ${p} ${mode} ${own}"; return 0; fi
    if install -d -m "$mode" "$p" && chown "$own" "$p"; then
      did "created ${p} ${mode} ${own}"
    else
      bad "${p} could not be created"
    fi
  fi
}

# ------------------------------------------------------- the sealing library
#
# python3-cryptography, as the distribution packages it. Every claw so far
# carries it because cloud-init depends on it, and the line below costs nothing
# where it does.
if python3 -c 'import cryptography.hazmat.primitives.ciphers.aead' >/dev/null 2>&1; then
  ok "python3-cryptography is present"
elif [ "$MODE" = dry-run ]; then
  did "${DRY}install python3-cryptography from the distribution's archive"
elif DEBIAN_FRONTEND=noninteractive apt-get install -y python3-cryptography >/dev/null 2>&1 \
     && python3 -c 'import cryptography.hazmat.primitives.ciphers.aead' >/dev/null 2>&1; then
  did "installed python3-cryptography from the distribution's archive"
else
  refuse packages "python3-cryptography is missing and could not be installed, so no record could be sealed"
fi

# ----------------------------------------------- what the service runs, digested
#
# Taken before the copy and again after it. A running process holds the bytes
# it started with, so a corrected program installed underneath it changes
# nothing until the unit restarts. The units are in the digest too: a unit that
# changed is a process running under rules it no longer has.
svc_digest() {
  {
    [ -r "$PROGRAM_DEST" ] && sha256sum "$PROGRAM_DEST"
    [ -d "$ADAPTERS_DEST" ] && find "$ADAPTERS_DEST" -type f -print0 | sort -z | xargs -0 -r sha256sum
    [ -d "$LIB_DEST" ] && find "$LIB_DEST" -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 -r sha256sum
    [ -r "${UNIT_DIR}/${UNIT}" ] && sha256sum "${UNIT_DIR}/${UNIT}"
    [ -r "${UNIT_DIR}/${SOCK_UNIT}" ] && sha256sum "${UNIT_DIR}/${SOCK_UNIT}"
  } 2>/dev/null | sed "s#  ${R}/#  /#" | sha256sum | cut -c1-16
}
SVC_BEFORE="$(svc_digest)"
UNIT_EXISTED=0; [ -e "${UNIT_DIR}/${UNIT}" ] && UNIT_EXISTED=1

# ------------------------------------------------------ the program + library
make_dir "$BIN_DIR" 0755 root:root
put_file "$PROGRAM_SRC" "$PROGRAM_DEST" 0755
if [ -n "$M_ADAPTERS" ]; then
  ensure_dir "$ADAPTERS_DEST" 0755 root:root
  for f in "${MDIR}/${M_ADAPTERS}"/*; do
    [ -f "$f" ] || continue
    put_file "$f" "${ADAPTERS_DEST}/$(basename "$f")" 0755
  done
fi
make_dir "$LIB_ROOT" 0755 root:root
ensure_dir "$LIB_DEST" 0755 root:root
for f in "${LIB_SRC}"/*.py; do
  put_file "$f" "${LIB_DEST}/$(basename "$f")" 0644
done
# THE PERSON TEST, from the one source the provisioning run reads. The door
# runs it through bash rather than carrying a Python copy of it, and the two
# digests below must agree, so there is one test on this claw however many
# places it is installed.
put_file "${HERE}/person.sh" "${LIB_DEST}/person.sh" 0644
if [ "$MODE" != dry-run ]; then
  if [ "$(sha256sum < "${HERE}/person.sh")" = "$(sha256sum < "${LIB_DEST}/person.sh" 2>/dev/null)" ]; then
    ok "the door's person test is byte for byte the provisioning run's"
  else
    bad "the door's person test at ${LIB_DEST}/person.sh differs from ${HERE}/person.sh"
  fi
  for f in "${LIB_DEST}"/*.py; do
    [ -e "${LIB_SRC}/$(basename "$f")" ] || warn "${f} is not in this release's library and was left in place"
  done
fi

# ------------------------------------------------------------ the command
#
# ONE COMMAND A PERSON TYPES, reached by name. /opt/commonclaw/bin is on nobody's
# PATH, and phase 25 gives the mail command one link in /usr/local/bin for that
# reason. This is the same link, written once for every connection that ships a
# command. The file installs under the connection's own name, so a command's
# name cannot land on a program already in /opt/commonclaw/bin.
#
# A FILE A PERSON PUT AT THE LINK'S PATH IS THEIR RULING and is left as it is,
# and so is a link to something that is not a connection's command. A link to
# another connection's command is refused: two connections cannot own one name.
if [ -n "$M_COMMAND" ]; then
  COMMAND_DEST="${PROGRAM_DEST}-command"
  COMMAND_TARGET="/opt/commonclaw/bin/commonclaw-conn-${NAME}-command"
  LINK="${R}/usr/local/bin/${M_COMMAND}"
  put_file "${MDIR}/${M_COMMAND}" "$COMMAND_DEST" 0755
  have_link="$(readlink "$LINK" 2>/dev/null || true)"
  if [ -L "$LINK" ] && [ "$have_link" = "$COMMAND_TARGET" ]; then
    ok "${LINK} reaches ${COMMAND_TARGET}"
  elif [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    warn "${LINK} is a file and not a link, so it was left exactly as it is. A person typing '${M_COMMAND}' reaches that file and not ${COMMAND_TARGET}"
  elif [ -L "$LINK" ] && [[ "$have_link" =~ ^/opt/commonclaw/bin/commonclaw-conn-[a-z0-9-]+-command$ ]]; then
    bad "${LINK} already reaches ${have_link}, another connection's command, so ${NAME} cannot take the name '${M_COMMAND}'"
  elif [ -L "$LINK" ]; then
    warn "${LINK} is a link to ${have_link}, which is not a connection's command, so it was left as it is"
  elif [ "$MODE" = dry-run ]; then
    did "${DRY}link ${LINK} to ${COMMAND_TARGET}, so a person reaches it by name"
  else
    make_dir "${R}/usr/local/bin" 0755 root:root
    if ln -sfn "$COMMAND_TARGET" "$LINK" && chown -h root:root "$LINK"; then
      did "linked ${LINK} to ${COMMAND_TARGET}, so a person reaches it by name"
    else
      bad "${LINK} could not be linked to ${COMMAND_TARGET}"
    fi
  fi
fi

# ------------------------------------------------------------- the account
ROW="$(getent passwd "$ACCOUNT" 2>/dev/null || true)"
if [ -z "$ROW" ]; then
  if [ "$MODE" = dry-run ]; then
    did "${DRY}create the system account ${ACCOUNT} with no shell"
  elif useradd --system --user-group --home-dir "/srv/connections/${NAME}" --no-create-home \
               --shell /usr/sbin/nologin "$ACCOUNT" >/dev/null 2>&1; then
    did "created the system account ${ACCOUNT}"
  else
    refuse account "the system account ${ACCOUNT} could not be created"
  fi
  ROW="$(getent passwd "$ACCOUNT" 2>/dev/null || true)"
else
  ok "the account ${ACCOUNT} already exists and was adopted"
fi
if [ -n "$ROW" ]; then
  UID_GOT="$(printf '%s\n' "$ROW" | cut -d: -f3)"
  cc_is_person "$ACCOUNT"; prc=$?
  case "$prc" in
    0) refuse account "${ACCOUNT} has uid ${UID_GOT}, inside this claw's login range, so every rail would read it as a person. A service account sits below that range. This run stops here and leaves the account for a person to look at" ;;
    1) ok "${ACCOUNT} has uid ${UID_GOT}, outside the login range, so no rail reads it as a person" ;;
    *) refuse account "${ACCOUNT} could not be read back after it was made" ;;
  esac
  if in_group "$PEOPLE_GROUP" "$ACCOUNT"; then
    bad "${ACCOUNT} is in ${PEOPLE_GROUP}, which is the claw's people. A service account is in no people group, and this run did not put it there"
  else
    ok "${ACCOUNT} is in no people group"
  fi
fi

# ------------------------------------------------------------------ the bus
#
# claw-bus is the group that may post to the session bus. A service that posts
# is put in it, and in nothing wider. The group is created here when this claw
# does not have it yet, the same way provisioning creates its groups.
if [ "$M_POSTS_BUS" = yes ]; then
  if getent group "$BUS_GROUP" >/dev/null 2>&1; then
    ok "the group ${BUS_GROUP} exists"
  elif [ "$MODE" = dry-run ]; then
    did "${DRY}create the group ${BUS_GROUP}"
  elif groupadd -f --system "$BUS_GROUP" 2>/dev/null || groupadd -f "$BUS_GROUP" 2>/dev/null; then
    did "created the group ${BUS_GROUP}"
  else
    bad "the group ${BUS_GROUP} could not be created, so ${ACCOUNT} cannot post to the bus"
  fi
  if [ -n "$ROW" ] && in_group "$BUS_GROUP" "$ACCOUNT"; then
    ok "${ACCOUNT} is in ${BUS_GROUP}"
  elif [ "$MODE" = dry-run ]; then
    did "${DRY}put ${ACCOUNT} in ${BUS_GROUP}"
  elif usermod -aG "$BUS_GROUP" "$ACCOUNT" >/dev/null 2>&1; then
    did "put ${ACCOUNT} in ${BUS_GROUP}, which is what lets it post to the bus"
  else
    bad "${ACCOUNT} could not be put in ${BUS_GROUP}"
  fi
elif [ -n "$ROW" ] && in_group "$BUS_GROUP" "$ACCOUNT"; then
  warn "${ACCOUNT} is in ${BUS_GROUP} and the manifest says it does not post to the bus. It was left there"
fi

# ------------------------------------------------------------ the directories
#
# /srv/connections is the claw's root for these services and is made only when
# it is absent: its mode is the roots phase's to rule on.
if [ ! -d "$CONN_ROOT" ]; then
  ensure_dir "$CONN_ROOT" 0755 root:root
fi
if [ -n "$ROW" ] || [ "$MODE" = dry-run ]; then
  ensure_dir "$HOME_DIR" 0750 "${ACCOUNT}:${ACCOUNT}"
  ensure_dir "${HOME_DIR}/state" 0700 "${ACCOUNT}:${ACCOUNT}"
  ensure_dir "${HOME_DIR}/log" 0750 "${ACCOUNT}:${ACCOUNT}"
fi

# ------------------------------------------------------------------ the conf
#
# THE SHIPPED CONF COMES FROM THE LIBRARY, so the defaults a claw is seeded with
# and the defaults the service falls back to are one list. The program's own
# keys follow from its manifest.
SHIP_CONF="${WORK}/conf"
if ! PYTHONPATH="${PAYLOAD_DIR}/lib" python3 -B -m commonclaw_connection conf \
       --name "$NAME" --socket-group "$M_SOCKET_GROUP" > "$SHIP_CONF" 2>"${WORK}/conf.err"; then
  refuse conf "the library could not print the shipped conf: $(head -c 300 "${WORK}/conf.err")"
fi
if [ -n "$M_CONF" ]; then
  { printf '\n'; cat "${MDIR}/${M_CONF}"; } >> "$SHIP_CONF"
fi

conf_release_name() {
  local f="${HERE}/../../release.json"
  [ -r "$f" ] || { printf ''; return 0; }
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
}

# conf_add_missing_keys <shipped> <file> ; lifted from install-email-gatekeeper.sh
conf_add_missing_keys() {
  local template="$1" conf="$2" line key added=0 rel
  rel="$(conf_release_name)"
  while IFS= read -r line; do
    case "$line" in
      [A-Z_]*=*) key="${line%%=*}" ;;
      *) continue ;;
    esac
    grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$conf" && continue
    if [ "$MODE" = dry-run ]; then
      did "${DRY}append ${key} to ${conf} with its shipped default"
      added=$((added + 1))
      continue
    fi
    {
      printf '\n'
      if [ -n "$rel" ]; then
        printf '# %s arrived in release %s. This file was seeded before it existed,\n' "$key" "$rel"
      else
        printf '# %s arrived in a release later than the one that seeded this file,\n' "$key"
      fi
      printf '# so the shipped default is appended here.\n'
      printf '%s\n' "$line"
    } >> "$conf"
    did "${key} was missing from ${conf} and its shipped default was appended"
    added=$((added + 1))
  done < "$template"
  [ "$added" -gt 0 ] || ok "${conf} carries every key this release ships"
}

# refs_only <file> <what> ; every non-comment line is KEY=op://..., or the key
# names of the lines that are not are printed. The value never enters a shell
# variable: awk prints the key and the line number and nothing after the "=".
refs_only() {
  awk -F= '/^[[:space:]]*(#|$)/ {next}
           $0 !~ /^[A-Z_][A-Z0-9_]*=op:\/\/[^[:space:]]+$/ { printf "%s line %d ", $1, NR }' "$1"
}

# secret_values_in_conf <file> ; the names of conf keys that name a credential
# and hold something other than an empty value or a reference. A key names one
# when its last word is KEY, TOKEN, SECRET, PASSWORD or CREDENTIAL, so API_KEY
# is read and TOKEN_ENDPOINT is not.
secret_values_in_conf() {
  awk -F= '/^[[:space:]]*(#|$)/ {next}
           $1 ~ /(^|_)(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)[[:space:]]*$/ {
             v = substr($0, index($0, "=") + 1); gsub(/["'"'"'[:space:]]/, "", v)
             if (v != "" && v !~ /^op:\/\//) printf "%s line %d ", $1, NR }' "$1"
}

hits="$(secret_values_in_conf "$SHIP_CONF")"
[ -z "$hits" ] || refuse conf "the shipped conf for ${NAME} holds a value where a reference belongs: ${hits}"
if [ -e "$CONF" ]; then
  ok "${CONF} already exists and its keys were left exactly as they are"
  conf_add_missing_keys "$SHIP_CONF" "$CONF"
elif [ "$MODE" = dry-run ]; then
  did "${DRY}seed ${CONF}"
else
  make_dir "$ETC" 0755 root:root
  if install -m 0644 "$SHIP_CONF" "$CONF" && chown root:root "$CONF"; then
    did "seeded ${CONF}"
  else
    bad "${CONF} could not be seeded"
  fi
fi
if [ -r "$CONF" ]; then
  hits="$(secret_values_in_conf "$CONF")"
  if [ -z "$hits" ]; then
    ok "${CONF} holds no value where a reference belongs"
  else
    bad "${CONF} holds a value where a reference belongs: ${hits}. Move the value into this claw's machine vault and put its op:// reference in ${ENVF}"
  fi
fi

# THE SOCKET'S GROUP IS THE CONF'S, read after adoption, so a firm's ruling
# reaches the socket unit at the next apply.
SOCKET_GROUP="$M_SOCKET_GROUP"
if [ -r "$CONF" ]; then
  g="$(sed -n 's/^[[:space:]]*SOCKET_GROUP[[:space:]]*=[[:space:]]*["'"'"']\{0,1\}\([a-z_][a-z0-9_-]*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' "$CONF" | tail -1)"
  [ -z "$g" ] || SOCKET_GROUP="$g"
fi
if getent group "$SOCKET_GROUP" >/dev/null 2>&1; then
  ok "the socket's group is ${SOCKET_GROUP}"
elif [ "$MODE" = dry-run ]; then
  warn "the socket's group ${SOCKET_GROUP} does not exist on this claw, and a real run would stop here"
else
  # REFUSED BEFORE THE UNITS ARE RENDERED, so the socket unit on the claw keeps
  # the group it had and nothing is left naming a group that is not there.
  refuse conf "the socket's group ${SOCKET_GROUP} does not exist on this claw, so nobody could open the socket. Name a group that exists in SOCKET_GROUP in ${CONF}"
fi

# --------------------------------------------------------------- the references
#
# A REFERENCE, NEVER A VALUE, and only for a service that reads a vault. The
# vault and the hostname come from the run that calls this, as they do for the
# mail gatekeeper, and from this box's own hostname when nobody passes them.
if [ "$M_READS_VAULT" = yes ]; then
  if [ -n "$M_ENV" ]; then
    HOSTN="${COMMONCLAW_CONN_HOSTNAME:-$(hostname -s)}"
    VAULT="${COMMONCLAW_CONN_VAULT:-}"
    [ -n "$VAULT" ] || VAULT="${HOSTN}-machine"
    SHIP_ENV="${WORK}/env"
    sed -e "s/{{VAULT}}/${VAULT}/g" -e "s/{{HOSTNAME}}/${HOSTN}/g" "${MDIR}/${M_ENV}" > "$SHIP_ENV"
    hits="$(refs_only "$SHIP_ENV")"
    [ -z "$hits" ] || refuse env "the env template for ${NAME} holds a value where a reference belongs: ${hits}"
    if [ -e "$ENVF" ]; then
      ok "${ENVF} already exists and its references were left exactly as they are"
      conf_add_missing_keys "$SHIP_ENV" "$ENVF"
    elif [ "$MODE" = dry-run ]; then
      did "${DRY}seed ${ENVF} with this claw's references"
    elif [ -z "$HOSTN" ]; then
      warn "this claw reports no short hostname, so ${ENVF} was not seeded. Pass COMMONCLAW_CONN_HOSTNAME, or give the box a hostname, then run this again"
    elif install -m 0644 "$SHIP_ENV" "$ENVF" && chown root:root "$ENVF"; then
      did "seeded ${ENVF} with this claw's references"
    else
      bad "${ENVF} could not be seeded"
    fi
  else
    warn "the manifest says ${NAME} reads a vault and names no env template, so no reference was seeded"
  fi
  if [ -r "$ENVF" ]; then
    hits="$(refs_only "$ENVF")"
    if [ -z "$hits" ]; then
      ok "${ENVF} holds references and no value"
    else
      bad "${ENVF} holds a value where a reference belongs: ${hits}. A value rests in this claw's machine vault and this file carries its op:// reference"
    fi
  fi
elif [ -e "$ENVF" ]; then
  warn "${ENVF} exists and ${NAME} does not read a vault, so its unit carries no machine credential to resolve it. It was left as it is"
fi

# ------------------------------------------------------------- the data key
#
# MINTED ONCE, SEALED BY THE HOST KEY, NEVER MINTED AGAIN. 32 random bytes go
# from the kernel into systemd-creds on a descriptor, and the sealed file is the
# only place they rest. The key is never on a command line and never in a
# variable. The read-back counts bytes and prints the count.
#
# A PRESENT KEY THAT DOES NOT OPEN IS A PERSON'S DECISION. Minting over it would
# orphan every record sealed under it, and nothing brings those back. On a
# rebuilt claw the old key belongs to the old host key; the sentence below says
# how a person moves it aside.
key_bytes() { systemd-creds decrypt --name="$CRED_NAME" "$1" - 2>/dev/null | wc -c | tr -d '[:space:]'; }
if [ -e "$CRED" ]; then
  n="$(key_bytes "$CRED")"
  if [ "$n" = 32 ]; then
    ok "the data key ${CRED} is present and opens on this box; it is never minted again"
  else
    bad "the data key ${CRED} is present and does not open on this box. It was left as it is. If this claw was rebuilt, that key belongs to the old host: move it aside and run this again, and the service starts with an empty store"
  fi
elif [ "$MODE" = dry-run ]; then
  did "${DRY}mint a 32-byte data key and seal it into ${CRED}"
else
  make_dir "$CRED_DIR" 0700 root:root
  tmp="$(mktemp "${CRED_DIR}/.conn-key.XXXXXX")"
  rm -f -- "$tmp"
  if systemd-creds encrypt --name="$CRED_NAME" - "$tmp" < <(head -c 32 /dev/urandom) >/dev/null 2>&1; then
    mv -f -- "$tmp" "$CRED"
    chmod 0600 "$CRED"; chown root:root "$CRED"
    n="$(key_bytes "$CRED")"
    if [ "$n" = 32 ]; then
      did "minted a 32-byte data key and sealed it into ${CRED}"
    else
      # This run made the file and the claw had none before it, so taking it
      # back leaves the claw as this run found it.
      rm -f -- "$CRED"
      bad "the data key sealed into ${CRED} read back as ${n:-0} bytes, so it was taken back"
    fi
  else
    rm -f -- "$tmp"
    bad "the host credential store refused to seal a data key for ${NAME}; nothing was written"
  fi
fi

# ------------------------------------------------------------------ the units
# render_unit <template> <out> ; the marked lines kept or dropped, the names filled in
render_unit() {
  awk -v name="$NAME" -v group="$SOCKET_GROUP" -v busdir="$BUS_DIR" \
      -v vault="$M_READS_VAULT" -v bus="$M_POSTS_BUS" '
    /^#\[vault\] / { if (vault != "yes") next; sub(/^#\[vault\] /, "") }
    /^#\[bus\] /   { if (bus != "yes") next;   sub(/^#\[bus\] /, "") }
    { gsub(/\{\{NAME\}\}/, name); gsub(/\{\{SOCKET_GROUP\}\}/, group); gsub(/\{\{BUS_DIR\}\}/, busdir); print }
  ' "$1" > "$2"
}
UNITS_CHANGED=0
for pair in "commonclaw-conn.service:${UNIT}" "commonclaw-conn.socket:${SOCK_UNIT}"; do
  t="${pair%%:*}"; u="${pair#*:}"
  render_unit "${TEMPLATE_DIR}/${t}" "${WORK}/${u}"
  if [ -e "${UNIT_DIR}/${u}" ] && cmp -s "${WORK}/${u}" "${UNIT_DIR}/${u}"; then
    ok "${UNIT_DIR}/${u} is as this release renders it"
    continue
  fi
  [ -e "${UNIT_DIR}/${u}" ] && warn "${UNIT_DIR}/${u} differed from this release and is converged"
  make_dir "$UNIT_DIR" 0755 root:root
  put_file "${WORK}/${u}" "${UNIT_DIR}/${u}" 0644
  UNITS_CHANGED=1
done
if [ "$MODE" != dry-run ]; then
  grep -qx 'NoNewPrivileges=yes' "${UNIT_DIR}/${UNIT}" 2>/dev/null \
    && ok "${UNIT} sets NoNewPrivileges" || bad "${UNIT} does not set NoNewPrivileges"
  if [ "$UNITS_CHANGED" = 1 ]; then systemctl daemon-reload >/dev/null 2>&1; fi
fi
SVC_AFTER="$(svc_digest)"

# --------------------------------------------------------------- enable it
if [ "$MODE" = dry-run ]; then
  ok "${DRY}enable and start ${SOCK_UNIT} and ${UNIT}"
elif [ "$FAILED" != 0 ]; then
  warn "${UNIT} was not started, because a step above did not take"
elif [ "$UNIT_EXISTED" = 1 ] && [ "$(systemctl is-enabled "$UNIT" 2>/dev/null || true)" = disabled ]; then
  warn "${UNIT} is deliberately disabled and was left off"
else
  WAS_ACTIVE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  for u in "$SOCK_UNIT" "$UNIT"; do
    if [ "$(systemctl is-enabled "$u" 2>/dev/null || true)" != enabled ]; then
      systemctl enable "$u" >/dev/null 2>&1 && did "enabled ${u}" || bad "${u} could not be enabled"
    fi
  done
  if [ "$WAS_ACTIVE" = active ] && [ "$SVC_BEFORE" != "$SVC_AFTER" ]; then
    # The socket goes round with the service, so a group the conf changed
    # reaches the socket file. A caller that arrives in between waits.
    systemctl stop "$UNIT" >/dev/null 2>&1
    systemctl restart "$SOCK_UNIT" >/dev/null 2>&1
    systemctl start "$UNIT" >/dev/null 2>&1
    did "${UNIT} was running ${SVC_BEFORE} and this run installed ${SVC_AFTER}, so it was restarted onto the new bytes"
  else
    for u in "$SOCK_UNIT" "$UNIT"; do
      if [ "$(systemctl is-active "$u" 2>/dev/null || true)" != active ]; then
        systemctl start "$u" >/dev/null 2>&1 && did "started ${u}" || warn "${u} did not start. journalctl -u ${u} says why"
      fi
    done
  fi
  [ "$(systemctl is-enabled "$UNIT" 2>/dev/null || true)" = enabled ] \
    && ok "${UNIT} is enabled" || bad "${UNIT} is not enabled"
  STATE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
fi

# ------------------------------------------------------------ the health line
if [ "$MODE" != dry-run ] && [ -x "$PROGRAM_DEST" ]; then
  COMMONCLAW_CONN_NAME="$NAME" PYTHONPATH="$LIB_ROOT" \
  COMMONCLAW_CONN_CONF="$CONF" COMMONCLAW_CONN_ENV="$ENVF" COMMONCLAW_CONN_UNIT_DIR="$UNIT_DIR" \
    "$PROGRAM_DEST" --check > "${WORK}/health" 2>/dev/null
  HEALTH="$(python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read().strip().splitlines()[-1])
    assert isinstance(d, dict)
except Exception:
    d = {}
print(json.dumps(d, sort_keys=True))' < "${WORK}/health")"
  case "$HEALTH" in
    *'"ready": true'*) ok "health: ${HEALTH}" ;;
    '{}') warn "health: the program printed no health line" ;;
    *) warn "health: ${HEALTH}. Not ready is the ordinary state of a connection nobody has wired yet, and it is not a failure" ;;
  esac
fi

if [ "$CHANGED" = 0 ] && [ "$FAILED" = 0 ]; then
  ok "nothing changed: this claw already carries ${NAME} as this release ships it"
fi
verdict "done"
exit "$FAILED"
