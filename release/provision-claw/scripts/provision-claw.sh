#!/bin/bash
#
# provision-claw.sh — the automatable subset of a firm-VM build.
#
# AGENT-INVOKED. Structured JSON to stdout, progress to stderr.
# The JSON is the check: `ok` is true only when every verification passed.
#
# USAGE
#   sudo ./provision-claw.sh --project wagmi --hostname wagmi-claw \
#        --timezone America/Chicago --keys ./staff-keys.txt --bucket <bucket>
#
#   --project <slug>       the firm this claw belongs to, recorded in the claw
#                          config. It shapes no path and no escrow name:
#                          workspaces live at /srv/workspaces on every claw, and
#                          escrow items carry the hostname.
#   --vault <name>         1Password vault holding this claw's escrow items.
#                          Defaults to the hostname with a -machine suffix.
#                          One vault per claw, always. Three claws sharing a
#                          vault means compromising one of them exposes the
#                          backup credentials of all three.
#   --bucket <name>        object-store bucket. Defaults to the WAGMI bucket.
#                          Names are globally unique and cannot be renamed in
#                          place, so confirm it exists before the first run.
#                          Claws write here only.
#   --s3-endpoint <host>   default s3.us-east-005.backblazeb2.com
#   --claw-admins <list>   comma-separated unix usernames who hold the claw-admin
#                          role: the firm's own responsible people. They get a
#                          narrow sudo grant on the claw's own scaffold script,
#                          and nothing wider. They are NOT put in the sudo group.
#   --skills-manifest <f>  the fleet skills manifest. Declares which skills every
#                          claw carries. Without it the machine-wide skill tier
#                          is left alone and the phase reports itself not run.
#   --skills-root <dir>    what a manifest's relative source paths resolve
#                          against. Defaults to the manifest file's own directory.
#   --release-channel <c>  which tier's releases this claw takes: staging, wagmi
#                          or tenants. Defaults to tenants, which is the safe
#                          default because it is the last tier a change reaches.
#   --release-repo <o/r>   where this claw pulls its releases from, seeded into
#                          the updater config on the run that creates it. A claw
#                          told nothing pulls from nowhere, which is the safe
#                          default: a repository nobody chose for this claw is
#                          not a default.
#   --release-notes <f>    member-facing prose for this run's changelog entry.
#                          REQUIRED. The run writes the entry itself, so a ride
#                          can no longer finish quietly without one.
#   --release-class <c>    fix | feature | fix and feature | security fix |
#                          security fix and feature. REQUIRED.
#   --revision <rev>       the commit this run was staged from. REQUIRED.
#   --only <phase>         run one phase
#   --dry-run              print the plan, change nothing
#
# --keys IS OPTIONAL, and its absence is what makes an unattended run safe.
# A keys file is a BUILD input: it names the people this claw is being made for.
# A release carries code and no identity, so an update has none to pass. Without
# it the people set is read from the claw's own `claw-members` group and no
# account is created and no key is written. An update therefore CANNOT re-create
# somebody who was offboarded, because it never holds key material at all.
#
# staff-keys.txt: one SSH PUBLIC key per line, the comment being the unix
# username. A public key is not a secret.
#     ssh-ed25519 AAAA... alice
#
# A person with several devices gets SEVERAL LINES under one username. The
# keys accumulate; the account, the home and the seat are made once.
#     ssh-ed25519         AAAA... alice        (laptop)
#     ecdsa-sha2-nistp256 AAAA... alice        (phone)
#
# WHAT THIS SCRIPT REFUSES (human-only; see operations/provision-claw.md):
#   core logins, device authorizations, credential provisioning, repository
#   initialization, enabling the backup timer, tailscale authorization,
#   and wiping anything. A script that did these could lose a repository or
#   leak a token.
#
# SIBLING FILES. Phase 7 installs the workspace conventions from ../templates,
# reconciles every workspace briefing against ../templates/workspace-
# instructions.md, and seeds the claw-wide briefing from
# ../templates/claw-instructions.md; both this script and scaffold-workspace.sh
# source the one substitution rule from render-template.sh beside them;
# phase 11 and 12 install commonclaw-backup.sh and commonclaw-seat-check.sh from
# beside this file; phase 13 installs every script beside this one into the
# granted prefix, and grants the four it names. Copy the whole skill directory
# to the claw. A missing sibling fails the run rather than being skipped.
#
# IDEMPOTENCY. Safe to re-run; reasoned per phase:
#   1  preflight     read-only.
#   2  identity      hostnamectl/timedatectl set an end state; config rewritten.
#   3  packages      apt install is a no-op on an installed package.
#   4  upgrades      enable is a no-op when already enabled.
#   5  ssh           one drop-in file, overwritten. Never edits sshd_config.
#                    The reload is a real action, so this is idempotent in
#                    effect, not inert. Existing sessions survive.
#   6  firewall      ufw dedups identical rules.
#   7  roots         install -d sets an end state; the conventions file is
#                    overwritten, which is how a convention change reaches a claw.
#                    The briefing reconcile writes only a file that reproduces a
#                    known template generation byte for byte, so the second run
#                    finds every one of them already current and writes nothing.
#                    A member-authored briefing is never written at all.
#                    groupadd -f for the members group. The CLAW-WIDE briefing is
#                    seeded only into an absence; where it exists its bytes are
#                    never touched and only its group and mode converge.
#   8  users         useradd guarded; each key line, each home symlink, and each
#                    pointer line guarded, never doubled. gpasswd -a is a
#                    no-op on a person already in the members group.
#   9  codex         skipped when the installed version is AT OR ABOVE the floor.
#                    When it does install it replaces the binaries; a running
#                    session keeps its handle, a new exec takes the new binary.
#   10 claude        skipped per person when they are at or above the floor, so
#                    the ordinary run touches nobody's core. When it does install
#                    it names the floor version explicitly and keeps the
#                    installer's exit status. Three states per person, each with
#                    its own branch: no core installs the floor, below the floor
#                    installs the floor, and a core whose version cannot be read
#                    is refused rather than guessed at.
#   Both cores       A FLOOR IS A MINIMUM, NEVER A TARGET: at or above it is a
#                    skip, below it is an install, and neither phase can move an
#                    installed core backwards under any argument.
#   11 backup        files overwritten; the timer installed DISABLED.
#   12 seat check    script and cron entry overwritten. The seat ROSTER is state
#                    and is seeded once, never rewritten: it carries decisions
#                    somebody took about this claw. The settle run appends only
#                    what it has not already recorded, so a second run in the
#                    same minute adds nothing.
#   13 admin door    groupadd -f; the installed tree and the sudoers drop-in are
#                    overwritten, which is how a changed script reaches a claw.
#                    The member-plane LOG is state and is seeded once, never
#                    rewritten: it records what the firm did to its own claw.
#   14 skill plane   content-addressed: a skill whose digest already matches is
#                    left untouched, so a re-run rewrites nothing. Skills the
#                    manifest no longer declares are removed, which is what makes
#                    the declaration the truth rather than a high-water mark. The
#                    dropped-segment directory converges to absent.
# No phase deletes user data. No phase depends on being the first run.
#
set -euo pipefail

# ---------------------------------------------------------------- parameters

PROJECT=""; TARGET_HOSTNAME=""; TIMEZONE=""; KEYS_FILE=""
VAULT=""                         # defaults to {hostname}-machine once arguments are parsed
B2_BUCKET="wagmi-fleet-backups"  # default; confirm it exists before the first run
S3_ENDPOINT="s3.us-east-005.backblazeb2.com"
CLAW_ADMINS_ARG=""
SKILLS_MANIFEST=""; SKILLS_ROOT=""
ONLY=""; DRY_RUN=0

# The changelog entry's three fields. Required, because a run that can finish
# without an entry is a run whose record depends on somebody remembering, and
# that dependency has failed three times in one week.
RELEASE_NOTES=""; RELEASE_CLASS=""; REVISION=""
RELEASE_REPO=""; RELEASE_CHANNEL="tenants"

# THE CORE VERSION FLOORS. A minimum, never a target: a run guarantees each core
# is AT LEAST this version and never moves an installed one backwards. At or
# above the floor is a skip; below it, or absent, is an install OF THE FLOOR.
#
# WHY A FLOOR AND NOT A PIN. A pin says "exactly this", so a claw carrying
# something newer gets it taken away, which is a downgrade nobody asked for and
# nothing announced. Measured 2026-08-13: the vendor installer for the
# persistent-session core downgrades on request -- asked for 2.1.222 with 2.1.229
# installed, it installed 2.1.222 -- so refusing to downgrade is OUR job and
# cannot be delegated to either vendor.
#
# WHY INSTALL THE FLOOR RATHER THAN THE NEWEST. The floor is a version we have
# ridden. `latest` is whatever shipped this morning, so two claws provisioned a
# day apart would carry different cores and neither number would appear in any
# record. A floor is deterministic, it is what the changelog entry names, and a
# claw already above it keeps what it has.
#
# RAISING ONE is an edit here, a commit, and a ride through the promotion tiers
# -- staging, then wagmi-claw, then tenants. There is deliberately no per-claw
# override and no flag: a floor that a run could lower is not a floor, and a
# per-claw value would let a box sit below the fleet's minimum with nothing
# saying so. The two lines below are the one place either version is stated.
CODEX_FLOOR="0.147.0"     # the per-task core, phase 9
CLAUDE_FLOOR="2.1.227"    # the persistent-session core, phase 10
WARN_DAYS_DEFAULT=14

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
# Programs that run on the MEMBER plane rather than the provisioning one. They
# are staged here so the phase that installs them names one source directory,
# the way the templates do.
PAYLOAD_DIR="${SCRIPT_DIR}/../payload"

# The workspace-template substitution, sourced from the one file that holds it.
# Phase 7 reproduces an existing briefing to decide whether a member has edited
# it, and it has to do that with the SAME function that wrote the file, which is
# scaffold-workspace.sh's. A second copy here would drift from that one, and the
# verdict it drifts on is "nobody wrote this, so it is safe to overwrite".
# Preflight requires the sibling as well; this guard is for the sourcing itself,
# which happens before preflight runs.
[ -r "${SCRIPT_DIR}/render-template.sh" ] || {
  printf 'missing sibling: %s/render-template.sh -- copy the whole skill directory\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=render-template.sh
. "${SCRIPT_DIR}/render-template.sh"

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)     PROJECT="${2:-}"; shift 2 ;;
    --hostname)    TARGET_HOSTNAME="${2:-}"; shift 2 ;;
    --timezone)    TIMEZONE="${2:-}"; shift 2 ;;
    --keys)        KEYS_FILE="${2:-}"; shift 2 ;;
    --vault)       VAULT="${2:-}"; shift 2 ;;
    --bucket)      B2_BUCKET="${2:-}"; shift 2 ;;
    --s3-endpoint) S3_ENDPOINT="${2:-}"; shift 2 ;;
    --claw-admins) CLAW_ADMINS_ARG="${2:-}"; shift 2 ;;
    --skills-manifest) SKILLS_MANIFEST="${2:-}"; shift 2 ;;
    --skills-root)     SKILLS_ROOT="${2:-}"; shift 2 ;;
    --release-repo)    RELEASE_REPO="${2:-}"; shift 2 ;;
    --release-channel) RELEASE_CHANNEL="${2:-}"; shift 2 ;;
    --release-notes)   RELEASE_NOTES="${2:-}"; shift 2 ;;
    --release-class)   RELEASE_CLASS="${2:-}"; shift 2 ;;
    --revision)        REVISION="${2:-}"; shift 2 ;;
    --only)        ONLY="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

# One vault per claw, always. Three claws sharing a vault means compromising one
# of them exposes the backup credentials of all three.
#
# The vault is named for who is kept out of it, prefixed by the machine it is
# scoped to, and this default composes that name. Everything in it is read by the
# machine and by nobody's agent session, which is the boundary the wall is for.
#
# The override stays because the vault sits in the owner's manager and may
# already carry a name of their choosing. Passing it names a different vault for
# this claw. It does not put two claws in one.
VAULT="${VAULT:-${TARGET_HOSTNAME}-machine}"

# The served-data root, and the two trees beneath it. Workspaces are governed by
# their manifests; connections are not workspaces, so they sit beside them rather
# than inside the tree a workspace sweep reads.
SRV_ROOT="/srv"
WORKSPACE_ROOT="${SRV_ROOT}/workspaces"
CONNECTIONS_ROOT="${SRV_ROOT}/connections"

ETC_ROOT="/etc/commonclaw"
CRED_DIR="${ETC_ROOT}/credentials"
CONF="${ETC_ROOT}/provision.conf"
ENV_FILE="${ETC_ROOT}/backup.env"
CONVENTIONS="${ETC_ROOT}/workspace-conventions.md"
SKILLS_DECLARATION="${ETC_ROOT}/skills.yaml"

# The seat roster. Which core seats this claw EXPECTS, declared rather than
# inferred from what happens to be installed.
#
# Provisioning seeds it, and the seat check never creates it. That is what makes
# its ABSENCE a stable state rather than a window: a claw without one keeps
# inferring expectation from core directories, exactly as every claw did before
# rosters existed, and it keeps doing so until a provisioning run says otherwise.
# A check that created its own roster would migrate every claw it runs on into
# declared mode on the first morning after a login, with nobody deciding.
SEATS_ROSTER="${ETC_ROOT}/seats.yaml"

# The member plane's own record. Every granted script appends one row here when
# it changes the claw, and nothing else writes it.
#
# It is NOT the changelog. The changelog is what provisioning gave this claw,
# written by the operator who rode the change; this file is what the firm's own
# admins did to the claw themselves. Two authors, two audiences, two sets of
# fields, and collapsing them would let a member's act arrive wearing a
# provisioning run's clothes. `reference/claw-conventions.md` carries the split.
#
# Seeded here, and only here, so one writer owns the header. A granted script
# that finds it missing refuses rather than creating its own: the doors and this
# file arrive in the same provisioning run, so its absence means somebody took
# it away, and an act with nowhere to be recorded should not happen quietly.
ADMIN_LOG="${ETC_ROOT}/admin-log.md"

# The release rail. Two files with different lifetimes, which is why they are
# two files rather than one.
#
# UPDATER_CONF is a DECISION the firm took about its own claw, so it follows the
# law the seat roster and the member-plane log follow: seeded once into an
# absence and never rewritten. A run that rewrote it would silently flip a firm
# that chose manual back to auto, with nothing telling them.
#
# The claw's record of WHICH release it carries is /etc/commonclaw/release.json,
# and it is deliberately not named here. The updater writes it, because this
# script is what a release applies and a thing cannot record its own application.
UPDATER_CONF="${ETC_ROOT}/updater.conf"

# The provisioning plane, installed on the claw at a fixed root-owned path.
#
# It has to be a fixed prefix carrying scripts AND templates together, because
# the scaffold resolves its templates as SCRIPT_DIR/../templates and exits at
# preflight when one is missing. A lone script dropped beside other payload
# would look for them one directory up from wherever it landed and fail every
# run. An operator's working copy is not an answer either: a sudo grant must
# name a path that is part of the claw, not part of whoever last copied a
# directory in.
#
# 0750 root:root throughout. sudo resolves and executes as root, so a member
# never needs to read any of it, and a vendor-plane script a member CAN read is
# a copy of the private plane sitting on a tenant machine.
OPT_ROOT="/opt/commonclaw"
INSTALL_PREFIX="${OPT_ROOT}/provision-claw"
GRANTED_SCAFFOLD="${INSTALL_PREFIX}/scripts/scaffold-workspace.sh"
GRANTED_RETIRE="${INSTALL_PREFIX}/scripts/retire-seat.sh"
GRANTED_ONBOARD="${INSTALL_PREFIX}/scripts/onboard-person.sh"
GRANTED_TOKEN="${INSTALL_PREFIX}/scripts/install-machine-token.sh"
GRANTED_MODE="${INSTALL_PREFIX}/scripts/set-update-mode.sh"
GRANTED_DESTROY="${INSTALL_PREFIX}/scripts/destroy-workspace.sh"
GRANTED_ACCESS="${INSTALL_PREFIX}/scripts/manage-workspace-access.sh"
GRANTED_PERSON_KEYS="${INSTALL_PREFIX}/scripts/manage-person-keys.sh"

# ONE list, four uses: what preflight requires beside this script, what the
# sudoers alias names, what the scope control requires the member's listing to
# hold, and nothing else. Adding an operation to the member plane is adding its
# script here; the control then fails until the alias and this list agree.
GRANTED_SCRIPTS=("$GRANTED_SCAFFOLD" "$GRANTED_RETIRE" "$GRANTED_ONBOARD" "$GRANTED_TOKEN" \
                 "$GRANTED_MODE" "$GRANTED_DESTROY" "$GRANTED_ACCESS" "$GRANTED_PERSON_KEYS")

# The adjacent script the grant does NOT name. It is installed deliberately: a
# refusal only proves scope when the refused path exists, is root-owned, and
# sits in the same directory as the granted one. Refusing a path that is not
# there refuses for the wrong reason and would pass a per-directory grant.
DECOY_SCRIPT="${INSTALL_PREFIX}/scripts/provision-claw.sh"

CLAW_ADMIN_GROUP="claw-admin"
SUDOERS_DROPIN="/etc/sudoers.d/commonclaw-claw-admin"

# The group every person on this claw belongs to, and the one thing it owns.
#
# WHY IT HAS TO EXIST. A person holds one `ws-` group per workspace they reach,
# and `claw-admin` is a role most of them never hold, so there is NO group every
# person on a claw shares. A file at the workspace root therefore has no group
# to belong to, and the only owners left are one account or root. One account
# makes a claw-wide surface that a second person can read and cannot write. Root
# puts it out of reach of every session on the claw, and the file is those
# sessions' own working substrate.
#
# IT CARRIES NO PRIVILEGE. No sudoers file names it and it owns exactly one
# path, which phase 8 proves rather than states. A group that owns one file
# carries what that file carries.
MEMBERS_GROUP="claw-members"

# The claw-wide briefing. One file for the whole claw, beside the workspaces
# rather than inside any of them, with the other core's convention symlinked at
# it exactly as a workspace does.
CLAW_BRIEFING="${WORKSPACE_ROOT}/CLAUDE.md"
CLAW_BRIEFING_LINK="${WORKSPACE_ROOT}/AGENTS.md"

# The fleet skill plane. One canonical copy per skill, symlinked into both
# cores' machine-wide directories.
#
# These two paths are measured, not assumed, and the first one is easy to get
# wrong: the inner .claude segment is real. A wrong path here loads zero skills
# and logs nothing that says so, so the phase carries a control that plants a
# skill at the wrong path and requires it to stay invisible.
#
# 0755 here, unlike the provisioning prefix above: these are read by every
# member's own session, so they must be world-readable. The two trees under
# /opt/commonclaw have opposite audiences and therefore opposite modes.
SKILLS_CANON="${OPT_ROOT}/skills"
CLAUDE_MACHINE_SKILLS="/etc/claude-code/.claude/skills"
CODEX_MACHINE_SKILLS="/etc/codex/skills"

# ---- the claw's shared session bus ----
#
# One rail every member's sessions land on, so an agent of one person can reach
# an agent of another. A bus inside somebody's home cannot do that: unix keeps
# the homes apart, which is what homes are for.
#
# THE MESSAGES ARE VISIBLE TO EVERY MEMBER, BY DESIGN. The bus home is group
# `claw-members` and group-writable, so anybody with a login here reads every
# inbox on it. That is the trust plane this claw already runs on and not a
# weakening of it. The standing law is unchanged and applies here in full: a
# credential never goes in a message body. See ${BUS_DOC}.
STATE_ROOT="/var/lib/commonclaw"
BUS_HOME="${STATE_ROOT}/bus"
BUS_DOC="${ETC_ROOT}/session-bus.md"

# The member-facing programs. 0755 root:root beside the skill tree, for the
# same reason and with the same audience: every member's session runs these,
# and a program a member can edit is a program a member can rewrite for
# everybody. The provisioning prefix next door stays 0750 and unreadable.
CLAW_BIN="${OPT_ROOT}/bin"
BUS_CLI="${CLAW_BIN}/bus"
BUS_JOIN_HOOK="${CLAW_BIN}/claw-bus-join"

# THE AUTO-JOIN, AND WHY IT IS HERE RATHER THAN IN A BRIEFING. A sentence in a
# CLAUDE.md asks a model to run something; it lands or it does not, and nothing
# reports which. The machine-wide harness settings are read by the harness
# itself on every session start, so the join is a fact about the machine rather
# than an instruction somebody's session may reinterpret.
MANAGED_SETTINGS="/etc/claude-code/managed-settings.json"

# The same path with the inner segment DROPPED. It is where the machine-path
# control plants the probe that must stay invisible, and it is therefore the one
# directory this script creates on purpose and must not leave behind.
WRONG_MACHINE_SKILLS="/etc/claude-code/skills"

# The two global instructions files, one per core, named rather than repeated as
# literals: what goes in BOTH and what goes in ONE now differ, and a difference
# spelled out at each site is one a later edit collapses by accident.
PERSISTENT_CORE_FILE=".claude/CLAUDE.md"   # walks up from the working directory
PER_TASK_CORE_FILE=".codex/AGENTS.md"      # does not

# The convention has ONE canonical copy, at $CONVENTIONS. Each core's global
# instructions file carries a pointer to it, never a second copy of it.
CONVENTION_POINTER="Workspace conventions for this claw: read ${CONVENTIONS} before working under ${WORKSPACE_ROOT}."

# THE CLAW BRIEFING POINTER, and it goes in ONE core's file only.
#
# Measured 2026-08-11: the persistent-session core walks up from the workspace
# and reads ${CLAW_BRIEFING} on its own. The per-task core does not -- it reads
# the workspace's own briefing and its reader's global file and nothing between
# them -- so it meets the claw briefing only when a session happens to start at
# the workspace root itself.
#
# WHY IT IS NOT WRITTEN TO BOTH. A global instructions file is loaded on every
# turn of every session, so a line in it is a cost paid forever by everybody. The
# core that already finds the file by walking up gains nothing from being told
# where it is, so a line there would be permanent weight in one core's file
# bought entirely to serve the other. Cheapness is the whole reason this change
# is worth making, and writing it to both would spend it. Phase 8 asserts the
# absence for that reason, not for tidiness.
#
# It names ${CLAW_BRIEFING} rather than the AGENTS.md symlinked at it. Both
# resolve to the same bytes, and the real file is the name every record, ledger
# and changelog on the fleet already uses; a pointer naming the link would put a
# second name for one file into the durable record.
CLAW_BRIEFING_POINTER="This claw's own briefing: read ${CLAW_BRIEFING} before working under ${WORKSPACE_ROOT}."

# USERS holds one entry per KEY LINE; PEOPLE holds each username once.
# A real person carries a laptop and a phone, so these two counts differ and
# conflating them costs twice: it reports the wrong number of staff, and it
# makes per-person work run once per device.
USERS=(); PEOPLE=()

# The claw-admin roster, and the skill set the manifest declares. Both are
# per-claw declared state: the claw is made to match them, and a check compares
# the world against the declaration rather than inferring the declaration from
# the world.
CLAW_ADMINS=()
SKILL_NAMES=(); SKILL_SOURCES=(); SKILL_PINS=(); SKILL_DIGESTS=()

CHK_PHASE=(); CHK_DESC=(); CHK_OK=()
HUMAN_STEPS=(); NOTES=()
FAILED=0
CUR_PHASE="preflight"
OPERATOR_IP=""

# ONE list, two uses: what phase 3 installs, and what it then verifies actually
# arrived. These drifted apart once, and the gap was invisible: the manager's CLI
# was named in SKILL.md's dependency table, absent from the install list, and
# absent from the check list too, so a claw reported every check green with a
# backup rail that could not take a single backup. Package on the left, the
# command it must provide on the right, empty where a package installs nothing
# this skill calls by name.
BASE_PACKAGES=(
  "git:git"                  "curl:curl"        "wget:"          "unzip:"
  "jq:jq"                    "sqlite3:sqlite3"  "acl:setfacl"    "tmux:tmux"
  "python3-venv:python3"     "restic:restic"    "bubblewrap:bwrap"
  "fail2ban:fail2ban-client" "ufw:ufw"          "unattended-upgrades:"
  "gnupg:gpg"                "ca-certificates:" "1password-cli:op"
  "sudo:visudo"
)

# ---------------------------------------------------------------- output
# Everything human goes to stderr. stdout carries only the JSON result.

say()   { printf '%s\n' "$*" >&2; }
head1() { CUR_PHASE="$2"; printf '\n=== PHASE %s: %s ===\n' "$1" "$2" >&2; }
record(){ CHK_PHASE+=("$CUR_PHASE"); CHK_DESC+=("$1"); CHK_OK+=("$2"); }
ok()    { printf '  OK    %s\n' "$*" >&2; record "$*" true; return 0; }
bad()   { printf '  FAIL  %s\n' "$*" >&2; record "$*" false; FAILED=1; return 0; }
warn()  { printf '  note  %s\n' "$*" >&2; NOTES+=("$*"); return 0; }
human() { printf '  HUMAN %s\n' "$*" >&2; HUMAN_STEPS+=("$*"); return 0; }

# Every command run here is run for its effect, never for its output, so its
# stdout joins the progress stream. stdout belongs to the JSON alone: the
# documented operator is an agent that parses it, and one chatty command makes
# the whole result unparseable. Fixing it here rather than per-command means a
# future addition cannot reintroduce the problem.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '  would run: %s\n' "$*" >&2; return 0; fi
  "$@" >&2
}

# check <description> <command...> — both branches reachable by construction
check() {
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then printf '  would verify: %s\n' "$desc" >&2; return 0; fi
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

want_phase() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# ------------------------------------------------------- version comparison
#
# THE COMPARISON LIVES IN ONE FILE, beside this one. provision-claw.sh holds the
# cores to their floors with it and commonclaw-update.sh decides with it whether
# a release is newer than what this claw carries. A second copy would drift, and
# the verdict it would drift on is whether a machine moves backwards.
#
# Guarded here rather than at preflight because the sourcing happens first.
[ -r "${SCRIPT_DIR}/version-compare.sh" ] || {
  printf 'missing sibling: %s/version-compare.sh -- copy the whole skill directory\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=version-compare.sh
. "${SCRIPT_DIR}/version-compare.sh"

# ------------------------------------------------------- core version read
#
# ONE COPY, beside this file. The updater asks the same question this script
# asks -- what version does this person carry -- and it asks it of every member
# per offered release. A second copy would drift on how much of somebody's home
# a routine check opens.
#
# Guarded here rather than at preflight because the sourcing happens first.
[ -r "${SCRIPT_DIR}/core-version.sh" ] || {
  printf 'missing sibling: %s/core-version.sh -- copy the whole skill directory\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=core-version.sh
. "${SCRIPT_DIR}/core-version.sh"

# Name shapes, and the SECOND pattern in each is what decides.
#
# A shell case pattern is ANCHORED AT BOTH ENDS, so `[a-z][a-z0-9-]*` reads as a
# character class followed by ANY remaining characters -- its trailing star is
# not "more of the same class", it is "anything at all". Measured 2026-08-11:
# that form validates the FIRST TWO CHARACTERS and nothing after them, so it
# accepted `ab; touch /tmp/pwned` and `ab$(id)` as names.
#
# Nothing was reachable through it at any site here: every use is quoted, and
# each downstream tool -- groupadd, useradd -- refused the name before it could
# matter. That is the defect rather than the mitigation. A guard whose refusal
# actually comes from somewhere else reads as complete while deciding nothing,
# and the tool that does the refusing is a property somebody can change without
# knowing it was load-bearing. The negative match fires when any single
# character falls outside the class.
is_unix_name() { case "$1" in [a-z_]*) : ;; *) return 1 ;; esac; case "$1" in *[!a-z0-9_-]*) return 1 ;; esac; }
is_slug()      { case "$1" in [a-z]*)  : ;; *) return 1 ;; esac; case "$1" in *[!a-z0-9-]*)  return 1 ;; esac; }

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_json() {
  local i first
  printf '{\n'
  printf '  "script": "provision-claw",\n'
  printf '  "ok": %s,\n' "$([ "$FAILED" -eq 0 ] && echo true || echo false)"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
  printf '  "project": "%s",\n' "$(json_esc "$PROJECT")"
  printf '  "hostname": "%s",\n' "$(json_esc "$TARGET_HOSTNAME")"
  printf '  "bucket": "%s",\n' "$(json_esc "$B2_BUCKET")"
  printf '  "vault": "%s",\n' "$(json_esc "$VAULT")"
  # people, each once -- not one entry per key, which would count devices
  printf '  "users": ['
  first=1
  for i in "${PEOPLE[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "$i")"; first=0
  done
  printf '],\n'

  # what this claw was made to carry, beside who reaches it
  printf '  "claw_admins": ['
  first=1
  for i in "${CLAW_ADMINS[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "$i")"; first=0
  done
  printf '],\n'

  printf '  "skills": ['
  first=1
  for i in "${!SKILL_NAMES[@]}"; do
    [ "$first" -eq 0 ] && printf ', '
    printf '{"name": "%s", "digest": "sha256:%s"}' \
      "$(json_esc "${SKILL_NAMES[$i]}")" "$(json_esc "${SKILL_DIGESTS[$i]}")"; first=0
  done
  printf '],\n'

  printf '  "checks": [\n'
  for i in "${!CHK_DESC[@]}"; do
    printf '    {"phase": "%s", "check": "%s", "ok": %s}' \
      "$(json_esc "${CHK_PHASE[$i]}")" "$(json_esc "${CHK_DESC[$i]}")" "${CHK_OK[$i]}"
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
  printf '],\n'

  printf '  "human_steps": ['
  first=1
  for i in "${HUMAN_STEPS[@]:-}"; do
    [ -z "$i" ] && continue
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$(json_esc "$i")"; first=0
  done
  printf ']\n'
  printf '}\n'
  JSON_EMITTED=1
}

finish() { emit_json; [ "$FAILED" -eq 0 ] || exit 1; exit 0; }

# THE RESULT IS EMITTED ON EVERY EXIT PATH, including a death under `set -e`.
#
# Before this, a run that stopped part-way wrote ZERO BYTES of JSON: `emit_json`
# was reachable only through `finish` at the very end, and the script carried no
# trap. An operator watching the terminal still saw the progress stream, so the
# gap was invisible to a person and total to a program. An unattended caller --
# which is the whole point of a release rail -- got no result at all, and could
# not tell a broken step from a machine that never ran.
#
# `CUR_PHASE` is maintained by `head1`, so the aborted result names the phase it
# stopped in. Written as if/fi rather than an AND-list for the reason stated at
# `version_at_least`: under `set -e` a bare `[ x ] && return 0` exits when the
# test is false, and doing that inside an EXIT trap is a trap that re-enters.
JSON_EMITTED=0
on_exit() {
  local rc=$?
  if [ "$JSON_EMITTED" -eq 1 ]; then return 0; fi
  bad "run ABORTED during ${CUR_PHASE} with exit ${rc} -- what follows is what had been measured when it stopped, not a completed run"
  emit_json
}

# ---------------------------------------------------------------- read-back

# Re-read a value out of a written config and compare it to what was meant.
#
# `test -s` proves a file has bytes, which is equally true of a config carrying
# the wrong bucket. A claw pointed at a bucket nobody meant reports every check
# green and looks healthy until the first backup lands somewhere else, which is
# the worst moment to learn it.
conf_says() {
  local key="$1" want="$2" got
  got="$(sed -n "s/^${key}=//p" "$CONF" 2>/dev/null || true)"
  [ "$got" = "$want" ]
}

# The same read, answering with the value instead of a verdict.
conf_value() { sed -n "s/^${1}=//p" "$CONF" 2>/dev/null | head -1 || true; }

# ---------------------------------------------------------------- identity

# IDENTITY BELONGS TO A BUILD, NEVER TO AN UPDATE.
#
# Six values make up a claw's identity: the name the machine answers to, the
# clock, and the four fields the backup repository is composed from. A run that
# passes a different one does not correct this box, it MOVES it. The clock takes
# the seat-check hour, the backup timer and the prune gate with it, and none of
# those three name the timezone anywhere. A changed bucket, endpoint or vault
# repoints the destination, and `commonclaw-backup.sh` composes the repository
# from exactly those values, so the next backup either stops or lands somewhere
# nobody is looking.
#
# Nothing compared a passed value to the box before writing it. The read-back
# control proves the file RECORDS what was passed, which is equally true when
# the value was never meant, so it could not have caught this.
#
# THE BOX'S OWN CONFIG DECIDES, and it needs no flag and no mode to say so. Its
# ABSENCE is a first build: the arguments become this claw's identity. Its
# PRESENCE is every later run: they have to match what is already recorded. The
# unattended case cannot be got wrong, because the updater reads these values off
# the box and hands them straight back, so agreement is the ordinary path and a
# mismatch means something composed a value nobody chose.
#
# A FIELD THE CONFIG DOES NOT RECORD IS NOT A MISMATCH. Claws built before the
# timezone was written down fall back to what the machine itself holds, which is
# what the record would have said.
#
# REFUSED, NOT QUIETLY REPAIRED. Converging to the box's own values instead would
# leave the caller believing a change landed. Re-identifying a claw is a decision
# taken with the consequences in view, so this stops the run and names the file.
IDENTITY_DIVERGED=0
identity_one() {                     # identity_one <label> <recorded> <passed>
  local label="$1" have="$2" want="$3"
  [ -n "$have" ] || return 0
  [ -n "$want" ] || return 0
  if [ "$have" = "$want" ]; then
    ok "identity: ${label} matches what this claw already records (${have})"
  else
    bad "identity: ${label} passed as '${want}' but this claw records '${have}' -- REFUSING to change it. Identity belongs to a build. If this claw really is being re-identified, change ${CONF} deliberately and ride it by hand"
    IDENTITY_DIVERGED=1
  fi
}

identity_guard() {
  head1 "0" "the identity this claw already carries"

  if [ ! -r "$CONF" ]; then
    ok "no ${CONF}: this is a first build, and this run's arguments become this claw's identity"
    return 0
  fi

  local tz_recorded vault_recorded
  # Written down since this guard existed; before that, the machine's own clock
  # is the record, and it is the value the updater reads and passes back.
  tz_recorded="$(conf_value TIMEZONE)"
  [ -n "$tz_recorded" ] || tz_recorded="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  # The vault is not a config field. It reaches the claw inside the manager
  # references in backup.env, so that file is where the claw records it.
  vault_recorded="$(sed -n 's|^RESTIC_PASSWORD=op://\([^/]*\)/.*|\1|p' "$ENV_FILE" 2>/dev/null | head -1 || true)"

  identity_one "project"     "$(conf_value PROJECT)"      "$PROJECT"
  identity_one "hostname"    "$(conf_value BOX_HOSTNAME)" "$TARGET_HOSTNAME"
  identity_one "timezone"    "$tz_recorded"               "$TIMEZONE"
  identity_one "bucket"      "$(conf_value B2_BUCKET)"    "$B2_BUCKET"
  identity_one "s3 endpoint" "$(conf_value S3_ENDPOINT)"  "$S3_ENDPOINT"
  identity_one "vault"       "$vault_recorded"            "$VAULT"

  if [ "$IDENTITY_DIVERGED" -eq 1 ]; then
    say ""
    say "  REFUSED before anything was changed. No phase has run."
    finish
  fi
}

# ---------------------------------------------------------------- digests
#
# ONE COPY, beside this file. The updater digests a fetched release with the
# same function that answers whether a skill is already installed here.
[ -r "${SCRIPT_DIR}/tree-digest.sh" ] || {
  printf 'missing sibling: %s/tree-digest.sh -- copy the whole skill directory\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=tree-digest.sh
. "${SCRIPT_DIR}/tree-digest.sh"

# ---------------------------------------------------------------- manifest

# Parse the fleet skills manifest. A STRICT subset of YAML, and strict on
# purpose: a parser that skips what it does not understand would ship a claw
# missing a skill and report the run green. Anything unrecognized fails here.
#
#   skills:
#     claw-ops:
#       source: .claude/skills/claw-ops
#       pin: sha256:...            # optional; ENFORCED when present
#
# `source` is a directory holding a SKILL.md. A relative one resolves against
# --skills-root, which defaults to the manifest's own directory.
parse_skills_manifest() {
  local file="$1"
  local lineno=0 line stripped in_skills=0 cur="" key val name i

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    line="${line%$'\r'}"
    stripped="${line#"${line%%[![:space:]]*}"}"   # leading whitespace off
    stripped="${stripped%"${stripped##*[![:space:]]}"}"  # trailing whitespace off
    [ -z "$stripped" ] && continue
    case "$stripped" in \#*) continue ;; esac

    if [ "$stripped" = "skills:" ] && [ "$line" = "skills:" ]; then in_skills=1; cur=""; continue; fi

    if [ "$in_skills" -eq 0 ]; then
      say "skills manifest line ${lineno}: content before the 'skills:' key"; return 1
    fi

    case "$line" in
      "    "[!\ ]*)                                  # an attribute of the entry above
        [ -n "$cur" ] || { say "skills manifest line ${lineno}: attribute with no skill above it"; return 1; }
        case "$stripped" in *:*) : ;; *) say "skills manifest line ${lineno}: not a key: value pair"; return 1 ;; esac
        key="${stripped%%:*}"
        val="${stripped#*:}"; val="${val#"${val%%[![:space:]]*}"}"
        [ -n "$val" ] || { say "skills manifest line ${lineno}: '${key}' has no value"; return 1; }
        case "$key" in
          source) SKILL_SOURCES[${#SKILL_NAMES[@]}-1]="$val" ;;
          pin)    SKILL_PINS[${#SKILL_NAMES[@]}-1]="$val" ;;
          *) say "skills manifest line ${lineno}: unknown key '${key}' (source, pin)"; return 1 ;;
        esac
        ;;
      "  "[!\ ]*)                                    # a skill name
        case "$stripped" in *:) : ;; *) say "skills manifest line ${lineno}: a skill name ends with a colon"; return 1 ;; esac
        name="${stripped%:}"
        is_slug "$name" \
          || { say "skills manifest line ${lineno}: skill name must be lowercase letters, digits and hyphen, starting with a letter: '${name}'"; return 1; }
        for i in "${SKILL_NAMES[@]:-}"; do
          [ "$i" = "$name" ] && { say "skills manifest line ${lineno}: '${name}' declared twice"; return 1; }
        done
        SKILL_NAMES+=("$name"); SKILL_SOURCES+=(""); SKILL_PINS+=(""); SKILL_DIGESTS+=("")
        cur="$name"
        ;;
      *) say "skills manifest line ${lineno}: unexpected indentation"; return 1 ;;
    esac
  done < "$file"

  [ "${#SKILL_NAMES[@]}" -gt 0 ] || { say "skills manifest declares no skills"; return 1; }

  # Resolve and validate every source before anything is touched.
  local src
  for i in "${!SKILL_NAMES[@]}"; do
    src="${SKILL_SOURCES[$i]}"
    [ -n "$src" ] || { say "skills manifest: '${SKILL_NAMES[$i]}' has no source"; return 1; }
    case "$src" in /*) : ;; *) src="${SKILLS_ROOT}/${src}" ;; esac
    [ -d "$src" ] || { say "skills manifest: '${SKILL_NAMES[$i]}' source is not a directory: ${src}"; return 1; }
    [ -r "${src}/SKILL.md" ] || { say "skills manifest: '${SKILL_NAMES[$i]}' source holds no readable SKILL.md: ${src}"; return 1; }
    SKILL_SOURCES[i]="$src"
  done
  return 0
}

# ---------------------------------------------------------------- phase 1

phase_1_preflight() {
  head1 1 "preflight"

  [ "$(id -u)" -eq 0 ] || { say "run this as root"; exit 1; }

  local v
  for v in PROJECT TARGET_HOSTNAME TIMEZONE B2_BUCKET VAULT; do  # the defaulted ones are still validated non-empty
    [ -n "${!v}" ] || { say "missing required argument for $v"; exit 1; }
  done

  # THE CHANGELOG ENTRY'S MATERIAL IS REQUIRED, and this refusal is the whole
  # structural fix. The convention has always said every run leaves an entry.
  # Nothing enforced it, so three operators missed it in one week and two rides
  # landed on a working claw invisibly. A run that cannot finish without the
  # material cannot finish quietly.
  for v in RELEASE_NOTES RELEASE_CLASS REVISION; do
    [ -n "${!v}" ] || {
      say "missing required argument for $v"
      say "every run writes a changelog entry, so it needs the prose, the class and the revision"
      exit 1; }
  done
  [ -r "$RELEASE_NOTES" ] || { say "cannot read release notes: $RELEASE_NOTES"; exit 1; }
  [ -s "$RELEASE_NOTES" ] || { say "release notes are empty: $RELEASE_NOTES -- an entry with no prose tells a member nothing"; exit 1; }

  is_slug "$PROJECT" \
    || { say "project slug must be lowercase letters, digits and hyphen, starting with a letter: '$PROJECT'"; exit 1; }

  # The tier this claw takes releases from. A closed set, because a typo here
  # would point a claw at a channel that does not exist and it would read as a
  # claw with nothing on offer, which is the reassuring answer and the wrong one.
  case "$RELEASE_CHANNEL" in
    staging|wagmi|tenants) : ;;
    *) say "--release-channel must be staging, wagmi or tenants (got '$RELEASE_CHANNEL')"; exit 1 ;;
  esac

  [ -z "$KEYS_FILE" ] || [ -r "$KEYS_FILE" ] || { say "cannot read keys file: $KEYS_FILE"; exit 1; }

  if ! grep -q 'VERSION_ID="24.04"' /etc/os-release; then
    say "this skill targets Ubuntu 24.04 LTS. Found: $(grep PRETTY_NAME /etc/os-release)"
    exit 1
  fi

  # A claw is plain Linux. Cloud-init user data stored on the instance is the
  # one thing that can rebuild a machine into something else without anybody
  # asking, because the platform re-runs it on every rebuild -- so a claw with
  # a payload here cannot be wiped back to bare, and hand-cleaning it would
  # certify whatever the operator happened to remove. Refuse instead.
  #
  # Judge the declared PAYLOAD, never the file size: cloud-init writes this
  # envelope whether or not user data exists, and an absent payload declares
  # itself as the not-multipart type. Sizing it would fail on every clean claw.
  local ud_file=/var/lib/cloud/instance/user-data.txt.i
  if [ -r "$ud_file" ]; then
    local payload
    payload="$(grep -m1 -oE 'text/(x-not-multipart|cloud-config|x-shellscript|x-include-url|cloud-boothook|part-handler)' "$ud_file" || true)"
    case "$payload" in
      ""|"text/x-not-multipart") : ;;
      *)
        say "this machine carries stored cloud-init user data (${payload})."
        say "the platform re-runs it on every rebuild, so this claw cannot come up bare."
        say "recreate the instance with empty user data. do not strip it by hand."
        exit 1 ;;
    esac
  fi

  # payload siblings must be present, not silently skipped later.
  #
  # The granted set is read from GRANTED_SCRIPTS rather than listed again here:
  # a grant naming a path that was never copied is a door onto nothing, and sudo
  # reports it the same way it reports a caller with no entry at all. A second
  # list would be a second place to forget, and the one script that was already
  # granted without being required here proves the drift is real.
  local s g missing_payload=""
  for s in commonclaw-backup.sh commonclaw-seat-check.sh render-template.sh \
           commonclaw-changelog.sh version-compare.sh tree-digest.sh \
           core-version.sh commonclaw-update.sh; do
    [ -r "${SCRIPT_DIR}/${s}" ] || missing_payload="$missing_payload $s"
  done
  for g in "${GRANTED_SCRIPTS[@]}"; do
    s="$(basename "$g")"
    [ -r "${SCRIPT_DIR}/${s}" ] || missing_payload="$missing_payload $s"
  done
  # Both templates phase 7 needs: the conventions file it installs, and the
  # briefing it reconciles every workspace against. A missing briefing template
  # would make the reconcile find nothing to compare and report every workspace
  # as member-authored, which reads as a clean run.
  [ -r "${TEMPLATE_DIR}/workspace-conventions.md" ] \
    || missing_payload="$missing_payload ../templates/workspace-conventions.md"
  [ -r "${TEMPLATE_DIR}/workspace-instructions.md" ] \
    || missing_payload="$missing_payload ../templates/workspace-instructions.md"
  # The claw-wide briefing's seed. It is written only into an absence, so a
  # missing template here would go unnoticed on every claw that already carries
  # the file and would silently skip the seeding on the one that does not.
  [ -r "${TEMPLATE_DIR}/claw-instructions.md" ] \
    || missing_payload="$missing_payload ../templates/claw-instructions.md"
  # The session bus's three pieces. Named here rather than only in phase 16
  # because the phase installs the machine-wide session-start hook: a run that
  # reached it with the hook program missing would register a hook pointing at
  # nothing, on every member's session, and only the members would find out.
  [ -r "${PAYLOAD_DIR}/bus" ] \
    || missing_payload="$missing_payload ../payload/bus"
  [ -r "${PAYLOAD_DIR}/claw-bus-join" ] \
    || missing_payload="$missing_payload ../payload/claw-bus-join"
  [ -r "${TEMPLATE_DIR}/session-bus.md" ] \
    || missing_payload="$missing_payload ../templates/session-bus.md"
  # At least one RETIRED generation, and this one is not tidiness.
  #
  # The reconcile recognises an unedited briefing by reproducing a retired
  # generation. With none present the glob matches nothing, every briefing in the
  # field fails to match, and the pass reports them all as member-authored and
  # leaves them alone. The run stays green while repairing nothing, which is the
  # sweep that reports clean because it measured nothing. So the absence is
  # refused here rather than discovered as a quiet no-op on somebody's claw.
  local sup_found=0 sup
  for sup in "${TEMPLATE_DIR}"/workspace-instructions.superseded-*.md; do
    [ -f "$sup" ] && sup_found=1 && break
  done
  [ "$sup_found" -eq 1 ] \
    || missing_payload="$missing_payload ../templates/workspace-instructions.superseded-*.md"
  if [ -n "$missing_payload" ]; then
    say "sibling file(s) missing from ${SCRIPT_DIR}:$missing_payload"
    say "copy the whole skill directory to the claw"
    exit 1
  fi

  local lineno=0 bad_lines=0 line user
  local entry seen u

  if [ -n "$KEYS_FILE" ]; then
    # A BUILD. The keys file names the people this claw is being made for.
    #
    # parse the keys file ONCE into an array; later phases iterate the array, so
    # no loop can be broken by a command that reads stdin
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno+1))
      [ -z "${line// }" ] && continue
      case "$line" in \#*) continue ;; esac
      if [ "$(printf '%s' "$line" | awk '{print NF}')" -lt 3 ]; then
        say "keys file line $lineno has no username comment"; bad_lines=1; continue
      fi
      user="$(printf '%s' "$line" | awk '{print $NF}')"
      if ! is_unix_name "$user"; then
        say "keys file line $lineno has an invalid username: '$user'"; bad_lines=1; continue
      fi
      USERS+=("${user}"$'\t'"${line}")
    done < "$KEYS_FILE"

    [ "$bad_lines" -eq 0 ] || exit 1
    [ "${#USERS[@]}" -gt 0 ] || { say "keys file has no usable key lines"; exit 1; }

    # each username once, in first-seen order
    for entry in "${USERS[@]}"; do
      user="${entry%%$'\t'*}"
      seen=0
      for u in "${PEOPLE[@]:-}"; do
        if [ "$u" = "$user" ]; then seen=1; break; fi
      done
      if [ "$seen" -eq 0 ]; then PEOPLE+=("$user"); fi
    done
  else
    # AN UPDATE. The people are read from the claw's own record of them.
    #
    # WHY THIS GROUP AND NOT A FILE. `claw-members` is written by BOTH doors that
    # make a person: this script's people phase, and the granted onboarding door.
    # So it cannot drift from the people who are actually here, which is exactly
    # what a build-time file does the moment somebody is onboarded between
    # releases. The password file was rejected because it carries system accounts
    # and anything made outside provisioning; the seat roster because a person who
    # never seated a core has no row; the member-plane log because it is
    # append-only history that never records a departure.
    #
    # USERS stays EMPTY on this path, and that is the safety property rather than
    # an omission: no account is created and no key is written, so an update
    # cannot re-create somebody who was offboarded.
    while IFS= read -r user; do
      [ -n "$user" ] || continue
      is_unix_name "$user" || { say "member '$user' in ${MEMBERS_GROUP} is not a valid unix name"; bad_lines=1; continue; }
      PEOPLE+=("$user")
    done < <(getent group "$MEMBERS_GROUP" 2>/dev/null | awk -F: '{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]!="") print a[i]}')

    [ "$bad_lines" -eq 0 ] || exit 1

    # REFUSE ON AN EMPTY SET. A people list derived from a missing or empty group
    # converges nobody, every per-person check then passes with nothing to check,
    # and the run reports green having proved nothing. This is the guard requiring
    # exactly what its measurement consumes, and it replaces the three refusals
    # the keys file carried on the other path.
    [ "${#PEOPLE[@]}" -gt 0 ] || {
      say "no --keys given and ${MEMBERS_GROUP} names nobody on this claw."
      say "an update takes its people from that group. With none, every per-person"
      say "check would pass by having nothing to check, so this run refuses instead."
      exit 1; }
  fi

  # The claw-admin roster: FORM only here. Existence is phase 13's, because on a
  # first run these accounts do not exist until phase 8 makes them, and on a
  # later run a claw-admin may be somebody onboarded outside this keys file.
  local a
  if [ -n "$CLAW_ADMINS_ARG" ]; then
    IFS=',' read -r -a CLAW_ADMINS <<< "$CLAW_ADMINS_ARG"
    for a in "${CLAW_ADMINS[@]}"; do
      is_unix_name "$a" || { say "invalid username in --claw-admins: '$a'"; exit 1; }
    done
  fi

  # The skills manifest is parsed HERE so a malformed one stops the run before
  # anything on the claw is touched, rather than at the phase that would have
  # shipped a half-declared skill set.
  if [ -n "$SKILLS_MANIFEST" ]; then
    [ -r "$SKILLS_MANIFEST" ] || { say "cannot read skills manifest: $SKILLS_MANIFEST"; exit 1; }
    [ -n "$SKILLS_ROOT" ] || SKILLS_ROOT="$(cd -- "$(dirname -- "$SKILLS_MANIFEST")" && pwd)"
    [ -d "$SKILLS_ROOT" ] || { say "--skills-root is not a directory: $SKILLS_ROOT"; exit 1; }
    parse_skills_manifest "$SKILLS_MANIFEST" || exit 1
  fi

  ok "root on Ubuntu 24.04"
  ok "arguments present, bucket resolved to ${B2_BUCKET}"
  ok "payload siblings present in ${SCRIPT_DIR}"
  ok "base carries no stored cloud-init payload"
  if [ -n "$KEYS_FILE" ]; then
    ok "keys file parsed: ${#PEOPLE[@]} people across ${#USERS[@]} keys, every line carries a valid username"
  else
    ok "no keys file: ${#PEOPLE[@]} people read from ${MEMBERS_GROUP}, and this run creates no account and writes no key"
  fi

  if [ -n "$SKILLS_MANIFEST" ]; then
    ok "skills manifest parsed: ${#SKILL_NAMES[@]} declared, every source holds a SKILL.md"
  else
    warn "no --skills-manifest given: the machine-wide skill tier is left untouched"
  fi
  if [ "${#CLAW_ADMINS[@]}" -gt 0 ]; then
    ok "claw-admin roster declared: ${#CLAW_ADMINS[@]}"
  else
    warn "no --claw-admins given: the group and the grant are installed, but no member holds the role and the grant control cannot run"
  fi
}

# ---------------------------------------------------------------- phase 2

phase_2_box_identity() {
  head1 2 "hostname, timezone, config"

  run hostnamectl set-hostname "$TARGET_HOSTNAME"
  run timedatectl set-timezone "$TIMEZONE"

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(hostname)" = "$TARGET_HOSTNAME" ]; then ok "hostname is $TARGET_HOSTNAME"
    else bad "hostname is $(hostname), wanted $TARGET_HOSTNAME"; fi
    if [ "$(timedatectl show -p Timezone --value)" = "$TIMEZONE" ]; then ok "timezone is $TIMEZONE"
    else bad "timezone is $(timedatectl show -p Timezone --value), wanted $TIMEZONE"; fi
  fi

  run install -d -m 0755 "$ETC_ROOT"
  run install -d -m 0700 "$CRED_DIR"

  # The timezone is written down because it is identity and the guard above needs
  # a record to hold a later run to. Three schedules read local time -- the
  # seat-check cron hour, the backup timer and the prune gate -- and not one of
  # them names the timezone, so before this the only trace of it was the machine
  # setting a run could silently move.
  if [ "$DRY_RUN" -eq 0 ]; then
    cat > "$CONF" <<CONFEOF
# Firm-VM config. Written by provision-claw.sh. NO SECRETS HERE.
PROJECT=${PROJECT}
SRV_ROOT=${SRV_ROOT}
WORKSPACE_ROOT=${WORKSPACE_ROOT}
CONNECTIONS_ROOT=${CONNECTIONS_ROOT}
BOX_HOSTNAME=${TARGET_HOSTNAME}
TIMEZONE=${TIMEZONE}
B2_BUCKET=${B2_BUCKET}
S3_ENDPOINT=${S3_ENDPOINT}
CRED_DIR=${CRED_DIR}
CONFEOF
    chmod 0644 "$CONF"
  fi

  # Read the value back out of the file and compare it to the parameter. The
  # bucket is the one that earns this: backup.env carries no repository path, so
  # this config is the only place the destination is written down, and nobody
  # checking backup.env for it will ever find it.
  check "config records B2_BUCKET as ${B2_BUCKET}" conf_says B2_BUCKET "$B2_BUCKET"

  # The read-back is only worth having if it can refuse. Ask it for a value the
  # config does not hold and require a NO.
  if [ "$DRY_RUN" -eq 0 ]; then
    if conf_says B2_BUCKET "${B2_BUCKET}-not-the-bucket"; then
      bad "read-back control: the config check accepted a bucket the file does not carry, so it is not comparing anything"
    else
      ok "read-back control: the config check refuses a value the file does not carry"
    fi
  fi

  check "credential directory is 0700 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$CRED_DIR')\" = '700 root:root' ]"
}

# ---------------------------------------------------------------- phase 3

phase_3_packages() {
  head1 3 "base packages"

  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq

  # fail2ban reads the journal that already exists when it starts, so a claw
  # that has been reachable for minutes arrives with scanner noise it will act
  # on retroactively. Spare the operator: whoever is provisioning is mid-build
  # and is also the relay for time-limited human-only artifacts like a login
  # code, so a ban does not merely inconvenience them, it destroys work a person
  # already did. Written BEFORE the package installs, because installing it
  # starts it.
  # THE OPERATOR ADDRESS, read WITH A DEFAULT because an unattended run has none.
  # Without the default this expansion aborts the entire run under `set -u`: a
  # timer, a cron entry and a serial console all set no SSH_CONNECTION, and the
  # run died here having already updated the package index and added an apt
  # source, writing zero bytes of JSON. Measured 2026-08-13.
  #
  # Read OUTSIDE the dry-run branch, because the old placement meant a dry run
  # never reached this line at all: the rehearsal of an unattended run passed
  # while the real one died. A guard the rehearsal cannot reach is not a guard.
  OPERATOR_IP="${SSH_CONNECTION:-}"
  OPERATOR_IP="${OPERATOR_IP%% *}"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would write /etc/fail2ban/jail.local ignoring the provisioning host"
  elif [ -z "$OPERATOR_IP" ]; then
    # NO OPERATOR TO EXEMPT, AND SO NOTHING TO WRITE. This file is authored with
    # `cat >`, which replaces rather than merges, so an unattended run that wrote
    # it would silently strip the exemption a hand ride put there and leave an
    # ignore list naming nobody. There is no operator on this run to protect, so
    # the correct act is to leave whatever is already there untouched. fail2ban's
    # own default ignore list already carries the loopback addresses.
    say "  no SSH_CONNECTION: leaving /etc/fail2ban/jail.local exactly as it is"
  else
    install -d -m 0755 /etc/fail2ban
    cat > /etc/fail2ban/jail.local <<F2BEOF
# Managed by provision-claw.sh.
# The provisioning host is never banned: it is mid-build, and it relays
# short-lived login codes that a ban would destroy.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1${OPERATOR_IP:+ }${OPERATOR_IP}
F2BEOF
    chmod 0644 /etc/fail2ban/jail.local
  fi

  # The manager's CLI is not a distribution package. Take it from the vendor's
  # own repository rather than pinning a downloaded binary: this is the most
  # security-sensitive program on the claw, and the repository puts it inside
  # the unattended-upgrades posture the claw already runs. A pinned binary would
  # sit outside that posture forever. Both cores are held to a version FLOOR for
  # a third reason again -- there what matters is a guaranteed minimum that a run
  # can never move backwards, not an exact version and not the newest one.
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would add the manager's apt repository and install its CLI"
  else
    run apt-get install -y -qq curl gnupg ca-certificates
    local arch; arch="$(dpkg --print-architecture)"
    curl -fsS https://downloads.1password.com/linux/keys/1password.asc \
      | gpg --dearmor --yes --output /usr/share/keyrings/1password-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/1password-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/%s stable main\n' \
      "$arch" "$arch" > /etc/apt/sources.list.d/1password.list
    run apt-get update -qq
  fi

  local pkgs=() pair
  for pair in "${BASE_PACKAGES[@]}"; do pkgs+=("${pair%%:*}"); done
  run apt-get install -y -qq "${pkgs[@]}"

  [ "$DRY_RUN" -eq 1 ] && return 0

  # A claw already running fail2ban does not re-read jail.local on its own.
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true

  # Ask fail2ban what it is actually ignoring. Reading the file back would only
  # prove the file was written, which was never in doubt.
  # Read the producer once, then match against the text. A pipeline into
  # `grep -q` makes the verdict depend on the producer's exit status under
  # `pipefail`, which is how a working thing reads as a broken one.
  if [ -n "$OPERATOR_IP" ]; then
    local ignore_text; ignore_text="$(fail2ban-client get sshd ignoreip 2>/dev/null || true)"
    if grep -qF "$OPERATOR_IP" <<< "$ignore_text"; then
      ok "provisioning host is in the effective ignore list"
    else
      bad "provisioning host is NOT in fail2ban's effective ignore list -- a ban mid-build will cut the operator off and burn any login code in flight"
    fi
  else
    warn "no SSH_CONNECTION, so no provisioning host to exempt and jail.local was left untouched -- expected when the claw updates itself on a timer"
  fi

  local missing="" c
  for pair in "${BASE_PACKAGES[@]}"; do
    c="${pair#*:}"; [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -z "$missing" ]; then ok "every base package provides its command"
  else bad "missing commands:$missing"; fi

  # Without the lock retry, a contended run fails outright rather than waiting.
  # reference/backup-rail.md
  local restic_help; restic_help="$(restic backup --help 2>/dev/null || true)"
  if grep -q -- '--retry-lock' <<< "$restic_help"; then
    ok "restic carries --retry-lock"
  else
    bad "restic has no --retry-lock -- read reference/backup-rail.md before enabling backups"
  fi
}

# ---------------------------------------------------------------- phase 4

phase_4_auto_upgrades() {
  head1 4 "unattended security upgrades"
  export DEBIAN_FRONTEND=noninteractive
  run dpkg-reconfigure -f noninteractive unattended-upgrades
  run systemctl enable --now unattended-upgrades
  check "unattended-upgrades enabled" systemctl is-enabled unattended-upgrades
  check "periodic upgrade flag set" \
    grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
}

# ---------------------------------------------------------------- phase 5

phase_5_ssh() {
  head1 5 "SSH hardening"

  # a drop-in is inert unless sshd_config includes the directory
  if grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config; then
    ok "sshd_config includes the drop-in directory"
  else
    bad "sshd_config has no Include for the drop-in directory -- add it as the FIRST line, then re-run this phase"
    return 0
  fi

  run install -d -m 0755 /etc/ssh/sshd_config.d
  [ "$DRY_RUN" -eq 1 ] && return 0

  cat > /etc/ssh/sshd_config.d/10-commonclaw.conf <<'SSHEOF'
# Firm-VM baseline. Managed by provision-claw.sh.
# Edit this file, never sshd_config.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHEOF
  chmod 0644 /etc/ssh/sshd_config.d/10-commonclaw.conf

  # parse BEFORE reload: a broken config plus a reload can end access
  if sshd -t 2>/dev/null; then
    ok "sshd config parses"
    systemctl reload ssh
  else
    bad "sshd -t failed -- NOT reloading"
    sshd -t 2>&1 | sed 's/^/    /' >&2 || true
    return 0
  fi

  local eff pair want_ok=1
  # OpenSSH treats prohibit-password and the legacy without-password as one setting
  # and `sshd -T` prints the legacy spelling. Normalize so the check tests the
  # posture and not the spelling.
  eff="$(sshd -T 2>/dev/null | sed 's/^permitrootlogin without-password$/permitrootlogin prohibit-password/' || true)"
  for pair in "passwordauthentication no" "kbdinteractiveauthentication no" \
              "pubkeyauthentication yes" "permitrootlogin prohibit-password"; do
    grep -qx "$pair" <<< "$eff" || { bad "effective SSH config missing: $pair"; want_ok=0; }
  done
  [ "$want_ok" -eq 1 ] && ok "effective SSH posture: keys only, root prohibit-password"

  human "open a SECOND ssh session and confirm access before closing the first"
}

# ---------------------------------------------------------------- phase 6

phase_6_firewall() {
  head1 6 "firewall and fail2ban"

  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow 22/tcp comment 'ssh'
  run ufw --force enable
  run systemctl enable --now fail2ban

  [ "$DRY_RUN" -eq 1 ] && return 0

  # Ask the firewall once and match against what it said. Three pipelines into
  # `grep` would each hang their verdict on the producer's exit status.
  local ufw_verbose ufw_plain
  ufw_verbose="$(ufw status verbose 2>/dev/null || true)"
  ufw_plain="$(ufw status 2>/dev/null || true)"

  if grep -q '^Status: active' <<< "$ufw_verbose"; then ok "ufw active"
  else bad "ufw is not active"; fi

  if grep -qE '^22/tcp .*ALLOW' <<< "$ufw_plain"; then ok "port 22 allowed"
  else bad "no allow rule for 22/tcp"; fi

  # this claw runs no web listener; connection services bind to loopback
  local extra
  extra="$(awk '/ALLOW/ && $1 !~ /^22\/tcp$/ {print $1}' <<< "$ufw_plain" | sort -u | tr '\n' ' ')"
  if [ -z "$extra" ]; then ok "no other inbound rules"
  else warn "other inbound rules present:$extra -- nothing this skill installs listens on a public port, so each of these was opened by something else"; fi

  check "fail2ban active" systemctl is-active fail2ban
}

# ---------------------------------------------------------------- phase 7

# Carry every existing workspace briefing forward to the current template.
#
# A briefing is written when its workspace is created and never again, because
# it belongs to the people working there and provisioning must not destroy what
# they wrote. The consequence nobody drew, measured across five claws on
# 2026-08-11: a template correction reaches only workspaces created after it,
# and every workspace made before it keeps a briefing that CONTRADICTS the
# conventions file this same phase installs. Six briefings on two claws named an
# empty directory as the place a credential comes from, while the conventions
# file beside them named the vault correctly.
#
# The template now copies only what cannot go stale, which is a property of the
# workspace directory itself, and points here for every mechanism. This pass
# carries the ones already in the field to that shape.
#
# THE TEST FOR "NOBODY EDITED IT" IS REPRODUCTION. Render each known generation
# of the template with this workspace's own values and compare bytes. A match at
# any generation means the file is still exactly what the scaffold wrote, so
# rewriting it destroys nothing. A match at none means somebody wrote in it: it
# is LEFT ALONE and named for a human. Not a timestamp, which moves for reasons
# that are not edits, and not a marker, which the files already in the field do
# not carry.
#
# COUPLED TO PHASE 13. This renders from the operator's staged templates. Phase
# 13 is what puts those same templates on the claw for the granted scaffold to
# use. A run that does this phase and skips 13 repairs every briefing that
# exists and leaves the next new one being born a generation behind.
reconcile_briefings() {
  local current="${TEMPLATE_DIR}/workspace-instructions.md"
  local d g name tmp gen WORKSPACE WS_GROUP
  local refreshed=0 already=0 authored=0 skipped=0 failed_write=0
  local authored_names="" skipped_names="" stale_names=""

  [ -d "$WORKSPACE_ROOT" ] || return 0

  tmp="$(mktemp)"
  for d in "$WORKSPACE_ROOT"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"

    # A directory under the root with no manifest is unfinished work, per the
    # conventions file's own rule. Named, never written to.
    if [ ! -f "${d}.workspace.yaml" ]; then
      skipped=$((skipped+1)); skipped_names="${skipped_names} ${name}(no manifest)"; continue
    fi
    if [ ! -f "${d}CLAUDE.md" ]; then
      skipped=$((skipped+1)); skipped_names="${skipped_names} ${name}(no briefing)"; continue
    fi

    # The values the SCAFFOLD used. The group is read from the manifest rather
    # than composed from the name, so a workspace whose group was named
    # differently still reproduces instead of reading as member-authored.
    WORKSPACE="$name"
    WS_GROUP="$(awk -F'[:[:space:]]+' '$1=="group"{print $2; exit}' "${d}.workspace.yaml")"
    [ -n "$WS_GROUP" ] || WS_GROUP="ws-${name}"

    render "$current" "$tmp"
    if cmp -s "$tmp" "${d}CLAUDE.md"; then
      already=$((already+1)); continue
    fi

    gen=""
    for g in "${TEMPLATE_DIR}"/workspace-instructions.superseded-*.md; do
      [ -f "$g" ] || continue
      render "$g" "$tmp"
      if cmp -s "$tmp" "${d}CLAUDE.md"; then gen="$(basename "$g")"; break; fi
    done

    if [ -z "$gen" ]; then
      authored=$((authored+1)); authored_names="${authored_names} ${name}"; continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      say "  would refresh ${name}/CLAUDE.md, which reproduces ${gen}"
      refreshed=$((refreshed+1)); continue
    fi

    # Written beside and moved into place, so a briefing is never half-written.
    # Mode and group are set on the new file rather than inherited, because the
    # briefing is group-writable by design and a root-owned 0644 here would take
    # the file away from the members it belongs to.
    if render "$current" "${d}.CLAUDE.md.provisioning" 2>/dev/null \
       && chgrp "$WS_GROUP" "${d}.CLAUDE.md.provisioning" 2>/dev/null \
       && chmod 0660 "${d}.CLAUDE.md.provisioning" 2>/dev/null \
       && mv -f "${d}.CLAUDE.md.provisioning" "${d}CLAUDE.md" 2>/dev/null; then
      say "  refreshed ${name}/CLAUDE.md from ${gen}"
      refreshed=$((refreshed+1))
    else
      rm -f "${d}.CLAUDE.md.provisioning" 2>/dev/null || true
      failed_write=$((failed_write+1)); stale_names="${stale_names} ${name}"
    fi
  done
  rm -f "$tmp"

  # Every workspace lands in exactly one of these five, so the line accounts for
  # the whole root rather than for the cases that went well.
  say "  briefings: ${already} already current, ${refreshed} refreshed, ${authored} member-authored, ${skipped} skipped, ${failed_write} not written"

  [ "$DRY_RUN" -eq 1 ] && return 0

  # THE ASSERTION, taken from a fresh read rather than from the counters above.
  # A counter says what this pass believed; this says what the claw now holds.
  # Its FAIL branch is reachable whenever a write does not land, which is what
  # the immutable-file control plants.
  local still_stale=""
  for d in "$WORKSPACE_ROOT"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ -f "${d}.workspace.yaml" ] && [ -f "${d}CLAUDE.md" ] || continue
    WORKSPACE="$name"
    WS_GROUP="$(awk -F'[:[:space:]]+' '$1=="group"{print $2; exit}' "${d}.workspace.yaml")"
    [ -n "$WS_GROUP" ] || WS_GROUP="ws-${name}"
    tmp="$(mktemp)"
    for g in "${TEMPLATE_DIR}"/workspace-instructions.superseded-*.md; do
      [ -f "$g" ] || continue
      render "$g" "$tmp"
      if cmp -s "$tmp" "${d}CLAUDE.md"; then still_stale="${still_stale} ${name}"; fi
    done
    rm -f "$tmp"
  done

  if [ -z "$still_stale" ]; then
    ok "every workspace briefing is at the current generation or member-authored (none reproduces a superseded one)"
  else
    bad "briefing(s) still reproducing a superseded template after the reconcile:${still_stale} -- sessions there are reading a contradiction of ${CONVENTIONS}"
  fi

  # Named rather than counted. A member-authored briefing is the one thing this
  # pass will not touch, so the list is what a human reconciles by hand.
  if [ -n "$authored_names" ]; then
    warn "member-authored briefing(s), left untouched and NOT carried forward:${authored_names} -- read each one against ${CONVENTIONS}"
  fi
  if [ -n "$skipped_names" ]; then
    warn "directory(ies) under ${WORKSPACE_ROOT} skipped by the briefing reconcile:${skipped_names}"
  fi
  if [ "$failed_write" -gt 0 ]; then
    warn "briefing write(s) that did not land:${stale_names}"
  fi
  return 0
}

# The claw-wide briefing, and the group that owns it.
#
# THE ORDERING, RESOLVED RATHER THAN WORKED AROUND. The group has to exist
# before the file can belong to it, and this phase runs before phase 8 makes any
# person. Creating a group is not creating a person: `groupadd -f` needs nobody,
# which is why phase 13 already creates `claw-admin` before it adds anybody to
# it. So the group is made HERE, beside the one file it exists for, and the
# people join it in phase 8 and in the granted onboarding door. One owner for the
# group, one owner for the membership, and this phase still stands alone under
# `--only 7`.
#
# ADOPT, NEVER OVERWRITE. The CONTENT belongs to whoever works on this claw,
# exactly as a workspace briefing does, and provisioning writes it once into an
# absence and never again. What every run does converge is OWNERSHIP: group and
# mode are the machine facts that decide whether the file belongs to everybody
# here or to one account. A file placed by hand arrives owned by the person who
# placed it, at whatever their umask gave it, which is a claw-wide surface a
# second person can read and cannot write. That is corrected in place, and the
# bytes are not touched.
#
# 0664 root:GROUP, and the world-read bit is deliberate. Every session on the
# claw reads this file, including a person who holds no workspace yet and a
# session that started before its owner's group change took effect. At 0660 that
# session reads nothing and says nothing about it. At 0664 it reads the file and
# only the writing waits for the next login. Nothing in it is secret; the
# conventions file it points at is 0644 for the same reason.
#
# THE SLOT IS PROVISIONING'S, THE CONTENT IS THEIRS. The workspace root stays
# 0755 root:root, so no member can create, delete or rename an entry in it. A
# member writes THROUGH this file. That is what makes "never overwritten" cheap
# to hold, and it is the whole difference between owning a file and owning the
# directory a claw's workspaces live in.
claw_briefing() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would create group ${MEMBERS_GROUP}"
    if [ -e "$CLAW_BRIEFING" ]; then
      say "  would keep ${CLAW_BRIEFING} byte for byte, and set it root:${MEMBERS_GROUP} 0664"
    else
      say "  would seed ${CLAW_BRIEFING} from ../templates/claw-instructions.md"
    fi
    say "  would link ${CLAW_BRIEFING_LINK} -> CLAUDE.md"
    return 0
  fi

  groupadd -f --system "$MEMBERS_GROUP" 2>/dev/null || groupadd -f "$MEMBERS_GROUP"
  check "group ${MEMBERS_GROUP} exists" getent group "$MEMBERS_GROUP"

  if [ -e "$CLAW_BRIEFING" ]; then
    say "  keeping ${CLAW_BRIEFING} -- its content belongs to the people here"
  else
    install -m 0664 "${TEMPLATE_DIR}/claw-instructions.md" "$CLAW_BRIEFING"
    say "  seeded ${CLAW_BRIEFING}"
  fi
  chown root:"$MEMBERS_GROUP" "$CLAW_BRIEFING"
  chmod 0664 "$CLAW_BRIEFING"

  # The other core's convention, pointing AT the authored file. Never a second
  # briefing. A real file here is left for a human, the way the scaffold leaves
  # one in a workspace.
  if [ -e "$CLAW_BRIEFING_LINK" ] && [ ! -L "$CLAW_BRIEFING_LINK" ]; then
    bad "${CLAW_BRIEFING_LINK} exists as a real file -- that is a second claw-wide briefing; merge it into CLAUDE.md and symlink"
  else
    ln -sfn CLAUDE.md "$CLAW_BRIEFING_LINK"
  fi

  check "claw briefing is 0664 root:${MEMBERS_GROUP}" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$CLAW_BRIEFING')\" = '664 root:${MEMBERS_GROUP}' ]"
  check "claw briefing carries content" test -s "$CLAW_BRIEFING"
  check "${CLAW_BRIEFING_LINK} is a symlink to CLAUDE.md" \
    bash -c "[ \"\$(readlink '$CLAW_BRIEFING_LINK')\" = 'CLAUDE.md' ]"
}

phase_7_roots() {
  head1 7 "roots and the workspace convention"

  run install -d -m 0755 "$SRV_ROOT"
  run install -d -m 0755 "$WORKSPACE_ROOT"
  run install -d -m 0755 "$CONNECTIONS_ROOT"

  # One canonical convention file per claw. Every agent here is pointed at it,
  # so a claw with an unreadable one is a claw whose agents invent conventions.
  # The config root is created here too, so this phase stands on its own under
  # --only rather than inheriting a directory from an earlier one.
  run install -d -m 0755 "$ETC_ROOT"
  run install -m 0644 "${TEMPLATE_DIR}/workspace-conventions.md" "$CONVENTIONS"

  check "workspace root is 0755 root" \
    bash -c "[ \"\$(stat -c '%a %U' '$WORKSPACE_ROOT')\" = '755 root' ]"
  # beside the workspace root, never inside it: a workspace sweep reads the tree
  # above, and a connection service is not a workspace
  check "connections root exists at $CONNECTIONS_ROOT" test -d "$CONNECTIONS_ROOT"
  check "workspace conventions readable at $CONVENTIONS" test -s "$CONVENTIONS"

  # The claw-wide briefing sits at the root of the tree the conventions file
  # governs, and it is the surface a session reads without being pointed at it.
  claw_briefing

  # The conventions file above is one canonical copy that this phase reinstalls
  # every run. The briefings under the workspace root are the OTHER surface a
  # session reads, and they are written once. Reconciling them here, in the same
  # phase, is what stops the two from saying different things.
  reconcile_briefings
}

# ---------------------------------------------------------------- phase 8

# Append the pointers to each core's global instructions file, once each. The
# file belongs to the person, so this adds lines and never rewrites one.
#
# TWO POINTERS, AND THEY DO NOT GO TO THE SAME PLACES. The conventions pointer
# goes in both cores' files. The claw-briefing pointer goes in the per-task
# core's file ALONE, because the other core reaches that file by walking up and
# a line telling it what it already knows is always-loaded weight for nothing.
stamp_conventions() {
  local user="$1" home="$2" f dir
  for f in "$PERSISTENT_CORE_FILE" "$PER_TASK_CORE_FILE"; do
    dir="${home}/$(dirname "$f")"
    [ -d "$dir" ] || install -d -m 0700 -o "$user" -g "$user" "$dir"
    [ -e "${home}/${f}" ] || install -m 0644 -o "$user" -g "$user" /dev/null "${home}/${f}"
    grep -qxF "$CONVENTION_POINTER" "${home}/${f}" \
      || printf '%s\n' "$CONVENTION_POINTER" >> "${home}/${f}"
  done

  # the second line, one core only, guarded the same way so a re-run never doubles it
  grep -qxF "$CLAW_BRIEFING_POINTER" "${home}/${PER_TASK_CORE_FILE}" \
    || printf '%s\n' "$CLAW_BRIEFING_POINTER" >> "${home}/${PER_TASK_CORE_FILE}"
}

# A workspace is root-owned by construction and its gitdir belongs to a member,
# so git's ownership guard refuses the repository for every caller. Declare the
# workspace root for each PERSON, never system-wide: a member can write repo
# config, and root is the one caller that must not execute it unexamined. The
# wildcard covers workspaces that do not exist yet.
phase_8_users() {
  head1 8 "people"

  local entry user line home f cnt user_groups created=0 existing=0

  # The account and everything that belongs to the PERSON: once each, however
  # many devices they carry. Driving this from the key list instead would
  # create the account on their first key and then redo the whole body for
  # every later one -- harmless, because each step is guarded, but it reports
  # a person as both created and already present, and it repeats real work.
  for user in "${PEOPLE[@]}"; do
    if getent passwd "$user" >/dev/null 2>&1; then existing=$((existing+1))
    else run useradd -m -s /bin/bash "$user"; created=$((created+1)); fi

    [ "$DRY_RUN" -eq 1 ] && continue

    home="$(getent passwd "$user" | cut -d: -f6)"
    install -d -m 0700 -o "$user" -g "$user" "${home}/.ssh"
    [ -e "${home}/.ssh/authorized_keys" ] || \
      install -m 0600 -o "$user" -g "$user" /dev/null "${home}/.ssh/authorized_keys"
    chown "$user":"$user" "${home}/.ssh/authorized_keys"
    chmod 0600 "${home}/.ssh/authorized_keys"
    chmod 0750 "$home"

    # one hop from home to every workspace, which is where a desktop folder
    # picker opens
    if [ -e "${home}/workspaces" ] && [ ! -L "${home}/workspaces" ]; then
      bad "${home}/workspaces exists as a real directory -- resolve it by hand"
    else
      ln -sfn "$WORKSPACE_ROOT" "${home}/workspaces"
      chown -h "$user":"$user" "${home}/workspaces"
    fi

    stamp_conventions "$user" "$home"

    # Every person on this claw joins the members group at seat creation, the
    # same way they get their workspace groups. Phase 7 makes the group, because
    # the group belongs with the file it owns; this phase makes the people, so
    # membership belongs here. A missing group is NOT created here: two owners
    # of one object is how the second one drifts, and an absence means a phase
    # was skipped rather than that this claw wants no group.
    if getent group "$MEMBERS_GROUP" >/dev/null 2>&1; then
      gpasswd -a "$user" "$MEMBERS_GROUP" >/dev/null 2>&1 || true
    else
      bad "group ${MEMBERS_GROUP} does not exist -- phase 7 creates it, and this run skipped it"
    fi
  done

  # The KEYS: once per key line, so somebody with a laptop and a phone
  # accumulates both rather than the second replacing the first.
  #
  # EMPTY ON AN UPDATE, deliberately. An update passes no keys file, so there is
  # no key material to write and no account to create. That is what stops a run
  # from re-creating a person somebody offboarded.
  if [ "$DRY_RUN" -eq 0 ] && [ "${#USERS[@]}" -gt 0 ]; then
    for entry in "${USERS[@]}"; do
      user="${entry%%$'\t'*}"; line="${entry#*$'\t'}"
      home="$(getent passwd "$user" | cut -d: -f6)"
      grep -qxF "$line" "${home}/.ssh/authorized_keys" || \
        printf '%s\n' "$line" >> "${home}/.ssh/authorized_keys"
    done
  fi

  say "  people: ${#PEOPLE[@]} across ${#USERS[@]} keys   accounts created: $created   already present: $existing"
  [ "$DRY_RUN" -eq 1 ] && return 0

  local all_ok=1
  for user in "${PEOPLE[@]}"; do
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ "$(stat -c '%a' "$home")" = "750" ] \
      || { bad "$home is not 750 -- this is the isolation boundary"; all_ok=0; }
    [ "$(stat -c '%a %U:%G' "${home}/.ssh/authorized_keys")" = "600 ${user}:${user}" ] \
      || { bad "${home}/.ssh/authorized_keys wrong mode or owner"; all_ok=0; }
    # The whole word, matched against text read once. This assertion is the one
    # that must not misreport: a pipeline that lost its verdict here would say a
    # person holds no root at the exact moment they do.
    user_groups=" $(id -nG "$user" 2>/dev/null || true) "
    case "$user_groups" in
      *" sudo "*) bad "$user has sudo -- staff must not have root"; all_ok=0 ;;
    esac
    case "$user_groups" in
      *" ${MEMBERS_GROUP} "*) : ;;
      *) bad "$user is not in ${MEMBERS_GROUP} -- ${CLAW_BRIEFING} would be readable and not writable for them"; all_ok=0 ;;
    esac
    if [ -L "${home}/workspaces" ] && [ "$(readlink "${home}/workspaces")" = "$WORKSPACE_ROOT" ]; then :
    else bad "${home}/workspaces is not a symlink to ${WORKSPACE_ROOT}"; all_ok=0; fi
    for f in "$PERSISTENT_CORE_FILE" "$PER_TASK_CORE_FILE"; do
      cnt="$(grep -cxF "$CONVENTION_POINTER" "${home}/${f}" 2>/dev/null || true)"
      [ "$cnt" = "1" ] || { bad "$user: ${f} does not carry exactly one conventions pointer (found '${cnt}')"; all_ok=0; }
    done

    # THE BRIEFING POINTER, and the absence is half the assertion.
    #
    # Present once in the core that cannot find the file on its own. ABSENT from
    # the core that can. Without the second check a later refactor that writes
    # the line to both files doubles the always-loaded cost on every session on
    # the claw, forever, and every check here still passes -- which is the whole
    # reason the line was cheap enough to add.
    cnt="$(grep -cxF "$CLAW_BRIEFING_POINTER" "${home}/${PER_TASK_CORE_FILE}" 2>/dev/null || true)"
    [ "$cnt" = "1" ] || { bad "$user: ${PER_TASK_CORE_FILE} does not carry exactly one claw-briefing pointer (found '${cnt}')"; all_ok=0; }
    cnt="$(grep -cxF "$CLAW_BRIEFING_POINTER" "${home}/${PERSISTENT_CORE_FILE}" 2>/dev/null || true)"
    [ "$cnt" = "0" ] || { bad "$user: ${PERSISTENT_CORE_FILE} must carry ZERO claw-briefing pointers and carries '${cnt}' -- that core walks up to the file already, so the line is always-loaded weight for nothing"; all_ok=0; }
  done

  # every key line present exactly once: a device added must not displace one
  # already there, and a re-run must not double any of them
  #
  # THIS ASSERTION IS BUILD-ONLY, and it is declared rather than skipped quietly.
  # It is defined against the keys file, so an update has nothing to compare and
  # it does not run. An unrun control is not a passed one, so the run says which
  # world it was in rather than reporting the same sentence either way.
  for entry in "${USERS[@]:-}"; do
    [ -n "$entry" ] || continue
    user="${entry%%$'\t'*}"; line="${entry#*$'\t'}"
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ "$(grep -cxF "$line" "${home}/.ssh/authorized_keys")" = "1" ] \
      || { bad "$user: a key line does not appear exactly once in authorized_keys"; all_ok=0; }
  done
  # The sentence names what was actually measured. On an update there is no keys
  # file, so the key-uniqueness leg did not run, and saying so is the difference
  # between a report and a claim.
  if [ "$all_ok" -eq 1 ]; then
    if [ "${#USERS[@]}" -gt 0 ]; then
      ok "every person: home 750, authorized_keys 600, no sudo, in ${MEMBERS_GROUP}, workspaces symlink, one conventions pointer per core, the claw-briefing pointer once in ${PER_TASK_CORE_FILE} and absent from ${PERSISTENT_CORE_FILE}; every key present exactly once"
    else
      ok "every person: home 750, authorized_keys 600, no sudo, in ${MEMBERS_GROUP}, workspaces symlink, one conventions pointer per core, the claw-briefing pointer once in ${PER_TASK_CORE_FILE} and absent from ${PERSISTENT_CORE_FILE}. The key-uniqueness leg is build-only and did NOT run on this update"
    fi
  fi

  # WHAT THE MEMBERS GROUP DOES NOT CARRY, measured rather than asserted.
  #
  # Everybody on the claw is in this group, so anything it reached would be
  # reached by everybody. Two readings say it reaches one file and nothing else.
  # Both fail branches are reachable: a sudoers file naming the group trips the
  # first, and any second path group-owned by it trips the second.
  # `|| true` on both, and it is not decoration. Under `set -e` with `pipefail` a
  # grep that matches NOTHING exits 1, and that is the PASSING world here, so
  # without this the run dies at the exact moment the group is clean and writes
  # zero bytes of JSON. Measured on staging, not reasoned: this check's pass
  # branch was the unreachable one.
  local grants owned
  grants="$(grep -rlsF "$MEMBERS_GROUP" /etc/sudoers /etc/sudoers.d/ 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' || true)"
  if [ -z "$grants" ]; then
    ok "no sudoers file names ${MEMBERS_GROUP}: the group carries no grant"
  else
    bad "sudoers file(s) name ${MEMBERS_GROUP}: ${grants} -- a group everybody is in must carry no grant"
  fi

  # WHERE OWNERSHIP IS A GRANT, and nowhere else. The pruned trees are pruned
  # for a reason each, not for speed:
  #   /proc /sys /dev /run   pseudo filesystems, and -xdev would not do this job
  #                          -- it stops at the root filesystem and would miss a
  #                          separately mounted /home.
  #   /tmp /var/tmp          already world-writable at 1777, so group ownership
  #                          there confers nothing beyond what the directory
  #                          already confers on everybody.
  #   /home                  every home is 0750, so nobody outside it traverses
  #                          in, and a group on a file inside one reaches nobody.
  #
  # Measured on staging 2026-08-11, and this is why the exclusions exist: the
  # first form of this check scanned everything and went RED because a byte copy
  # of the briefing taken with `cp -p` kept its group. A run that fails for an
  # act with no consequence is the seat-check lesson again -- a warning that
  # fires on a healthy claw teaches its reader to ignore the one that matters.
  #
  # PRUNED RATHER THAN LISTED. An allowlist of system roots would silently stop
  # covering a top-level directory somebody adds later. The exclusions are the
  # trees where the property provably does not hold, so everything else stays in
  # scope by default.
  owned="$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
                     -o -path /tmp -o -path /var/tmp -o -path /home \) -prune \
             -o -group "$MEMBERS_GROUP" -print 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' || true)"
  if [ "$owned" = "${CLAW_BRIEFING} " ]; then
    ok "${MEMBERS_GROUP} owns one path where ownership grants anything: ${CLAW_BRIEFING}"
  else
    bad "${MEMBERS_GROUP} owns path(s) besides ${CLAW_BRIEFING} where the group is a grant: ${owned}"
  fi

  human "each person completes their own core logins in their own home"
}

# ---------------------------------------------------------------- phase 9

phase_9_codex() {
  head1 9 "the per-task core, system-wide, full companion set"

  # This core answers `--version` with "codex-cli 0.147.0", so the version is the
  # SECOND field. Anything else -- an empty string from an absent binary, an error
  # sentence -- reaches the comparison as itself and is refused there.
  local installed=""
  if command -v codex >/dev/null 2>&1; then
    installed="$(codex --version 2>/dev/null | awk '{print $2}' || true)"
  fi

  # THE FLOOR DECIDES, with three answers rather than two.
  local rc=0
  version_at_least "$installed" "$CODEX_FLOOR" || rc=$?

  # The full set matters independently of the version: a claw carrying the CLI
  # without its command runner has a core that breaks on every shell execution.
  local set_ok=1
  [ -x /opt/codex/codex-code-mode-host ] || set_ok=0

  # WHAT VERSION TO INSTALL, and the middle case is the one that protects the
  # rule. A box already ABOVE the floor with an incomplete set is repaired at the
  # version it already carries, never at the floor: installing the floor there
  # would repair the set by moving the CLI backwards, which is the exact act this
  # phase now forbids. Below the floor, or absent, takes the floor.
  local want=""
  if [ "$rc" -eq 2 ]; then
    want=""                       # unreadable: install nothing, report below
  elif [ "$rc" -eq 0 ] && [ "$set_ok" -eq 1 ]; then
    want=""                       # at or above the floor, set complete: nothing to do
  elif [ "$rc" -eq 0 ]; then
    want="$installed"             # above the floor, set incomplete: repair in place
  else
    want="$CODEX_FLOOR"
  fi

  if [ "$rc" -eq 2 ]; then
    bad "per-task core: no comparable version to read (got '${installed:-nothing}') -- refusing to install, because an install that cannot be proved forward is one that could move this core backwards"
  elif [ -z "$want" ]; then
    ok "per-task core ${installed} is at or above the floor ${CODEX_FLOOR}, companion host present: left alone"
  elif [ "$DRY_RUN" -eq 1 ]; then
    say "  would install the companion set at ${want} into /opt/codex"
  else
    say "  installing the companion set at ${want} (installed: ${installed:-nothing}, floor: ${CODEX_FLOOR})"
    install -d -m 0755 /opt/codex
    local tmp arch_tag base a
    tmp="$(mktemp -d)"
    base="https://github.com/openai/codex/releases/download/rust-v${want}"
    arch_tag="x86_64-unknown-linux-musl"
    case "$(uname -m)" in aarch64|arm64) arch_tag="aarch64-unknown-linux-musl" ;; esac
    local src
    # A DOWNLOAD THAT FAILS MUST FAIL THIS CHECK, NOT THE WHOLE RUN. Both of
    # these were unguarded under `set -e`, so one unreachable release URL or one
    # network blip killed the script mid-phase and wrote ZERO bytes of JSON --
    # the operator gets no result at all rather than a result saying which step
    # broke. Handled in the shape the line below already uses: report, leave the
    # core exactly as it was, and let the run finish and say so.
    for a in codex codex-code-mode-host; do
      if ! curl -fsSL -o "${tmp}/${a}.tar.gz" "${base}/${a}-${arch_tag}.tar.gz"; then
        bad "phase 9: could not download ${a} at ${want}; the core is unchanged"
        rm -rf "$tmp"; return 0
      fi
      mkdir -p "${tmp}/${a}.d"
      if ! tar -xzf "${tmp}/${a}.tar.gz" -C "${tmp}/${a}.d"; then
        bad "phase 9: the ${a} tarball at ${want} did not extract; the core is unchanged"
        rm -rf "$tmp"; return 0
      fi
      # Each tarball holds one binary whose name carries the arch triple. Resolve it
      # rather than assume it, and install it under the plain name, so the system
      # path never depends on the triple and a naming change fails HERE.
      src="$(find "${tmp}/${a}.d" -type f -print -quit)"
      [ -n "$src" ] || { bad "phase 9: ${a} tarball contained no file"; rm -rf "$tmp"; return 0; }
      install -m 0755 -o root -g root "$src" "/opt/codex/${a}"
    done
    rm -rf "$tmp"
    ln -sfn /opt/codex/codex /usr/local/bin/codex
    ln -sfn /opt/codex/codex-code-mode-host /usr/local/bin/codex-code-mode-host
  fi

  [ "$DRY_RUN" -eq 1 ] && return 0

  # the FULL set: a bare CLI binary breaks every shell execution
  local miss="" c
  for c in codex codex-code-mode-host bwrap; do
    command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
  done
  if [ -z "$miss" ]; then ok "full companion set present (cli, command runner, sandbox)"
  else bad "companion set incomplete, missing:$miss"; fi

  # AT OR ABOVE THE FLOOR, which is what the run guarantees.
  local now rc2=0
  now="$(codex --version 2>/dev/null | awk '{print $2}' || true)"
  version_at_least "$now" "$CODEX_FLOOR" || rc2=$?
  case "$rc2" in
    0) ok "per-task core ${now} is at or above the floor ${CODEX_FLOOR}" ;;
    1) bad "per-task core is ${now}, BELOW the floor ${CODEX_FLOOR}" ;;
    *) bad "per-task core version unreadable after this phase (got '${now:-nothing}')" ;;
  esac

  # AND NEVER BACKWARDS. Measured against what this box carried when the phase
  # began rather than against the floor, because those are different claims: a
  # box that started above the floor and was moved down to it would satisfy the
  # assertion above and still be the defect. This is the one the change exists
  # for, and its fail branch is reached by putting a version above the floor in
  # front of a run.
  if [ -n "$installed" ]; then
    local rc3=0
    version_at_least "$now" "$installed" || rc3=$?
    case "$rc3" in
      0) ok "per-task core did not move backwards this run (${installed} -> ${now})" ;;
      1) bad "per-task core MOVED BACKWARDS: ${installed} -> ${now}" ;;
      *) bad "per-task core: cannot prove it did not move backwards (${installed:-nothing} -> ${now:-nothing})" ;;
    esac
  fi

  # the lab claw symlinked the system path into one person's home; that breaks
  # when the person is removed. Refuse to inherit it.
  local resolved
  resolved="$(readlink -f /usr/local/bin/codex 2>/dev/null || true)"
  # readlink -f resolves a path even when nothing is there, so a dangling symlink
  # satisfies a string comparison. Require a real executable at the far end.
  if [ "$resolved" = "/opt/codex/codex" ] && [ -x "$resolved" ]; then
    ok "system path points into /opt, not into a home"
  elif [ "$resolved" = "/opt/codex/codex" ]; then
    bad "system path points at /opt/codex/codex but nothing executable is there"
  else
    bad "system path resolves to ${resolved:-nothing}, not /opt/codex/codex"
  fi

  human "each person authenticates this core with its device-code flow"
}

# ---------------------------------------------------------------- phase 10

phase_10_claude() {
  head1 10 "the persistent-session core, per person"

  # per PERSON, not per key: this downloads and runs an installer, so driving
  # it from the key list makes somebody with two devices pay for it twice and
  # reports their seat twice in the result
  local user home installed now out status rc rc2 rc3 absent any_fail=0 moved=0 fresh=0

  for user in "${PEOPLE[@]}"; do
    if [ "$DRY_RUN" -eq 1 ]; then say "  would hold $user at or above ${CLAUDE_FLOOR}"; continue; fi
    home="$(getent passwd "$user" | cut -d: -f6)"

    installed="$(claude_version_for "$user")"
    rc=0; version_at_least "$installed" "$CLAUDE_FLOOR" || rc=$?

    # AT OR ABOVE THE FLOOR IS A SKIP, and it is the ordinary case on a claw that
    # is already current. This is also what makes a run safe to take while
    # somebody is working: the common path touches nobody's core at all.
    if [ "$rc" -eq 0 ]; then
      ok "$user: ${installed}, at or above the floor ${CLAUDE_FLOOR}: left alone"
      continue
    fi

    # THE REFUSAL COVERS TWO DIFFERENT PEOPLE, and only one of them belongs in
    # it. The comparison refuses on the empty string, and the version read
    # answers the empty string BOTH for a core that cannot say what it is AND
    # for a person who has no core at all. Measured 2026-08-16 on the hub: a
    # roster member who had never logged in was reported as a core too dangerous
    # to touch, and the release's apply failed on her rather than giving her one.
    #
    # So ask, rather than infer from the field that failed. A probe keyed on the
    # version read reports absence as a defect, which is what this was.
    absent=0
    if [ "$rc" -eq 2 ]; then
      claude_present_for "$user" || absent=1

      # PRESENT AND UNREADABLE MEANS DO NOTHING, w40's branch and its reason
      # intact. The vendor installer downgrades on request (measured
      # 2026-08-13), so an install over a core we cannot read is one we cannot
      # prove is forward. A person whose core answers nothing comparable is
      # reported, not guessed at.
      if [ "$absent" -eq 0 ]; then
        bad "$user: no comparable version to read (got '${installed:-nothing}') -- refusing to install rather than risk moving this core backwards"
        any_fail=1
        continue
      fi
    fi

    # NOTHING INSTALLED IS A FRESH INSTALL, not a refusal. There is no core here,
    # so there is no backwards to move and the whole reason for the refusal is
    # gone with it. The floor is the right version to land on for the same reason
    # it is everywhere else in this phase.
    #
    # It falls into the install below rather than carrying its own copy of it: a
    # later change to how this claw installs a core must not be able to reach one
    # of these two states and miss the other.
    #
    # BELOW THE FLOOR: install the floor BY NAME. Never a bare install, which
    # resolves to whatever shipped this morning -- measured 2026-08-13, a bare
    # run over an installed 2.1.227 moved it to 2.1.229 with nothing saying so.
    # </dev/null so the installer cannot consume this script's stdin.
    if [ "$absent" -eq 1 ]; then
      say "  $user: no core is installed, installing the floor ${CLAUDE_FLOOR}"
    else
      say "  $user: ${installed} is below the floor, installing ${CLAUDE_FLOOR}"
    fi
    status=0
    out="$(sudo -u "$user" -H bash -lc \
             "curl -fsSL https://claude.ai/install.sh | bash -s -- ${CLAUDE_FLOOR}" \
           </dev/null 2>&1)" || status=$?

    # THE INSTALLER'S OWN VERDICT, kept rather than swallowed. Whether a broken
    # step fails loudly or quietly should not depend on which stream it wrote to.
    if [ "$status" -ne 0 ]; then
      bad "$user: the vendor installer exited ${status}"
      say "  its last lines:"
      printf '%s\n' "$out" | tail -5 | while IFS= read -r line; do say "    ${line}"; done
      any_fail=1
      continue
    fi

    now="$(claude_version_for "$user")"
    rc2=0; version_at_least "$now" "$CLAUDE_FLOOR" || rc2=$?
    # ONE LINE PER STATE, because the two installs are not the same event. A
    # fresh install gave somebody a core they did not have; an upgrade moved one
    # that was already there. Reporting both as a move hides the first inside a
    # count of the second, and the first is the one a claw's operator is waiting
    # on when a new person is onboarded.
    case "$rc2" in
      0) if [ "$absent" -eq 1 ]; then
           ok "$user: had no core, ${now} installed at the floor ${CLAUDE_FLOOR}"; fresh=$((fresh+1))
         else
           ok "$user: ${installed} -> ${now}, now at or above the floor ${CLAUDE_FLOOR}"; moved=$((moved+1))
         fi ;;
      1) bad "$user: still ${now} after installing, BELOW the floor ${CLAUDE_FLOOR}"; any_fail=1 ;;
      *) bad "$user: version unreadable after installing (got '${now:-nothing}')"; any_fail=1 ;;
    esac

    # NEVER BACKWARDS, measured against what this person carried when the phase
    # began. Only reachable when we installed, which is the only place we could
    # have moved anything.
    if [ -n "$installed" ]; then
      rc3=0; version_at_least "$now" "$installed" || rc3=$?
      case "$rc3" in
        0) : ;;
        1) bad "$user: core MOVED BACKWARDS: ${installed} -> ${now}"; any_fail=1 ;;
        *) bad "$user: cannot prove the core did not move backwards (${installed} -> ${now:-nothing})"; any_fail=1 ;;
      esac
    fi

    [ -L "${home}/.local/bin/claude" ] || \
      warn "$user: launcher is not the installer-managed symlink"
  done

  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$any_fail" -eq 0 ] && ok "every person is at or above the floor ${CLAUDE_FLOOR}; ${moved} core(s) moved and ${fresh} installed fresh this run"
  human "each person completes the browser login for this core"
}

# ---------------------------------------------------------------- phase 11

phase_11_backup() {
  head1 11 "backup rail (installed DISABLED)"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would install commonclaw-backup.sh, backup.env, the unit and the timer"
    return 0
  fi

  install -m 0755 "${SCRIPT_DIR}/commonclaw-backup.sh" /usr/local/sbin/commonclaw-backup.sh

  # References only. No values. This file is safe to read, diff, and commit --
  # and it is rewritten on every run, because rewriting references destroys
  # nothing and a changed vault or item name must actually reach the claw.
  cat > "$ENV_FILE" <<ENVEOF
# Manager references, never values. Resolved at invocation by the manager.
# Item names follow the naming table in reference/claw-conventions.md.
# The field names are the manager's own for an API-credential item.
RESTIC_PASSWORD=op://${VAULT}/commonclaw-restic-${TARGET_HOSTNAME}/password
AWS_ACCESS_KEY_ID=op://${VAULT}/commonclaw-backup-${TARGET_HOSTNAME}/username
AWS_SECRET_ACCESS_KEY=op://${VAULT}/commonclaw-backup-${TARGET_HOSTNAME}/credential
ENVEOF
  chmod 0644 "$ENV_FILE"

  cat > /etc/systemd/system/commonclaw-backup.service <<'SVCEOF'
[Unit]
Description=Firm-VM off-claw backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
LoadCredentialEncrypted=op-service-account:/etc/commonclaw/credentials/op-service-account.cred
# A unit has no HOME, so the archiver finds nowhere to cache and re-reads
# repository metadata from the object store on every run. That is slower as the
# repository grows and it bills reads against the very caps this rail is told to
# watch. systemd creates and owns the directory.
CacheDirectory=commonclaw-backup
Environment=RESTIC_CACHE_DIR=/var/cache/commonclaw-backup
ExecStart=/usr/local/sbin/commonclaw-backup.sh backup
Nice=10
IOSchedulingClass=idle
SVCEOF

  cat > /etc/systemd/system/commonclaw-backup.timer <<'TIMEOF'
[Unit]
Description=Firm-VM backup every six hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:30:00
Persistent=true

[Install]
WantedBy=timers.target
TIMEOF

  systemctl daemon-reload

  check "backup script installed and executable" test -x /usr/local/sbin/commonclaw-backup.sh
  check "backup script parses" bash -n /usr/local/sbin/commonclaw-backup.sh
  check "service unit registered" systemctl cat commonclaw-backup.service
  check "timer unit registered"   systemctl cat commonclaw-backup.timer
  check "env file holds references, not values" \
    bash -c "! grep -qE '^[A-Z_]+=[^o]' '$ENV_FILE' || grep -qc 'op://' '$ENV_FILE'"

  if systemctl is-enabled commonclaw-backup.timer >/dev/null 2>&1; then
    warn "timer already enabled -- confirm the repository is initialized and spot-checked"
  else
    ok "timer installed DISABLED (credentials, then init, then spot-check, then enable)"
  fi

  human "provision the service-account credential, then init the repository, then run one backup, then the restore spot-check, then enable the timer"
}

# ---------------------------------------------------------------- phase 12

phase_12_seat_check() {
  head1 12 "seat-expiry check"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would install the seat check and its cron entry, and seed ${SEATS_ROSTER} if it is absent"
    return 0
  fi

  install -m 0755 "${SCRIPT_DIR}/commonclaw-seat-check.sh" /usr/local/sbin/commonclaw-seat-check.sh

  cat > /etc/cron.d/commonclaw-seat-check <<CRONEOF
# Seat-expiry check. Managed by provision-claw.sh.
# DELIVERY: set MAILTO to a real address with a working MTA, or add a webhook
# post inside the script. Without one of those this check reaches nobody.
MAILTO=""
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 8 * * * root WARN_DAYS=${WARN_DAYS_DEFAULT} /usr/local/sbin/commonclaw-seat-check.sh
CRONEOF
  chmod 0644 /etc/cron.d/commonclaw-seat-check

  check "seat check installed and executable" test -x /usr/local/sbin/commonclaw-seat-check.sh
  check "seat check parses" bash -n /usr/local/sbin/commonclaw-seat-check.sh
  check "cron entry present" test -s /etc/cron.d/commonclaw-seat-check

  # ---- the roster ----
  # The config root is created here too, so this phase stands on its own under
  # --only.
  install -d -m 0755 -o root -g root "$ETC_ROOT"

  # Seeded EMPTY. Provisioning does not guess who is seated; the ratchet
  # observes it, and the person logging in is the update.
  #
  # NEVER OVERWRITTEN. This is state, like a workspace manifest: it carries
  # decisions somebody took about this claw, and a re-run that rewrote it would
  # erase every retirement and its reason.
  if [ -e "$SEATS_ROSTER" ]; then
    say "  keeping the existing seat roster at ${SEATS_ROSTER}"
  else
    cat > "$SEATS_ROSTER" <<'ROSTEREOF'
# Seat roster. Which core seats this claw EXPECTS.
#
# Inferring expectation from a core's directory conflates "the software is
# installed" with "a seat is expected", so a claw that deliberately seats one
# core warns forever about the other. This file replaces that inference with a
# declaration.
#
# AN APPEND-ONLY EVENT LOG. The LAST event for a person and core is its current
# state, and the events above it are the history of how it got there.
#
#   - {person: NAME, core: CORE, event: seated,  date: YYYY-MM-DD, by: WHO}
#   - {person: NAME, core: CORE, event: retired, date: YYYY-MM-DD, by: WHO, reason: TEXT}
#
# UP BY ITSELF, DOWN BY DECISION. The claw's own seat check appends a `seated`
# event the first time it observes a live login, so infrastructure that comes to
# depend on a seat is covered without anyone remembering to declare it. It never
# removes: a retired seat and a destroyed seat look identical from here.
# Retiring is a claw-admin act through the claw's own retire operation, and it
# records who decided and why.
#
# DO NOT EDIT BY HAND. The grammar has one reader on this claw. A line written
# past it makes the check refuse to check anything, which is loud and is meant
# to be.
seats:
ROSTEREOF
    say "  seeded an empty seat roster at ${SEATS_ROSTER}"
  fi
  chmod 0644 "$SEATS_ROSTER"; chown root:root "$SEATS_ROSTER"

  check "seat roster present" test -s "$SEATS_ROSTER"
  check "seat roster is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$SEATS_ROSTER')\" = '644 root:root' ]"

  # The seed is not evidence until the grammar's own reader accepts it. A roster
  # the check cannot parse is worse than none: the check refuses everything.
  local state_out
  if state_out="$(/usr/local/sbin/commonclaw-seat-check.sh --state 2>&1)"; then
    case "$state_out" in
      "roster: present"*) ok "the seat check reads the roster: it reports the roster present" ;;
      *) bad "the seat check does not see the roster at ${SEATS_ROSTER}" ;;
    esac
  else
    bad "the seat check refuses the roster: ${state_out}"
  fi

  # ---- settle the ratchet BEFORE measuring anything ----
  # A control must not be the thing that changes the state it measures. The
  # first run of the check on a claw that already carries live seats appends
  # their rows, so running it once here means the two control inputs below
  # differ because of the THRESHOLD and not because the first of them happened
  # to do the roster's bookkeeping.
  /usr/local/sbin/commonclaw-seat-check.sh >/dev/null 2>&1 || true

  # Prove the fail path is reachable. A check that cannot fail is decoration.
  #
  # The two inputs must DIVERGE. Matching on "a warning appeared" proves
  # nothing about the branch under test: this phase runs before anybody has
  # logged in, and in that window the only warning available comes from the
  # not-active branch, so a forced run reports the threshold branch reachable
  # when that branch cannot execute at all. The threshold needs an expiry to
  # compare against, and an expiry needs a login.
  local clean forced
  clean="$(/usr/local/sbin/commonclaw-seat-check.sh 2>/dev/null || true)"
  forced="$(WARN_DAYS=999999 /usr/local/sbin/commonclaw-seat-check.sh 2>/dev/null || true)"
  if [ "$clean" != "$forced" ]; then
    ok "threshold control: clean and forced inputs give different verdicts"
  elif [ -z "$(find /home -maxdepth 3 -path '*/.claude/.credentials.json' -print -quit 2>/dev/null)" ]; then
    warn "threshold control NOT RUN: no seat is authenticated yet, so the threshold branch cannot execute. An unrun control is not a passed one -- re-run it after the first login, and require the two verdicts to differ."
  else
    bad "threshold control: clean and forced inputs give the same verdict, so the threshold branch is not being exercised"
  fi

  human "re-run the threshold control after the first login and require the clean and forced verdicts to DIFFER, then wire ONE delivery path and confirm a warning arrives"
}

# ---------------------------------------------------------------- phase 13

# Is this member allowed to run exactly this path, asked as the member?
# Root passes everything and proves nothing here.
# These three are invoked by name through `check`, which shellcheck cannot see.
# shellcheck disable=SC2329
member_may_run() { sudo -u "$1" -H sudo -n -l "$2" >/dev/null 2>&1; }
# shellcheck disable=SC2329
member_refused()  { ! sudo -u "$1" -H sudo -n -l "$2" >/dev/null 2>&1; }
# shellcheck disable=SC2329
member_cannot_execute() { ! sudo -u "$1" -H sudo -n "$2" --help >/dev/null 2>&1; }

phase_13_admin_door() {
  head1 13 "the claw-admin door"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would create group ${CLAW_ADMIN_GROUP}, install ${INSTALL_PREFIX}, write ${SUDOERS_DROPIN}"
    return 0
  fi

  # ---- the group ----
  groupadd -f --system "$CLAW_ADMIN_GROUP" 2>/dev/null || groupadd -f "$CLAW_ADMIN_GROUP"
  check "group ${CLAW_ADMIN_GROUP} exists" getent group "$CLAW_ADMIN_GROUP"

  local a gtext uid missing="" roster_ok=1
  for a in "${CLAW_ADMINS[@]:-}"; do
    [ -z "$a" ] && continue
    if ! getent passwd "$a" >/dev/null 2>&1; then missing="$missing $a"; roster_ok=0; continue; fi
    uid="$(id -u "$a" 2>/dev/null || echo 0)"
    if [ "$uid" -lt 1000 ]; then
      bad "claw-admin '${a}' is a system account (uid ${uid}) -- the role is for the firm's own people"
      roster_ok=0; continue
    fi
    gpasswd -a "$a" "$CLAW_ADMIN_GROUP" >/dev/null 2>&1 || true
  done
  [ -z "$missing" ] || bad "claw-admin(s) named but no such unix user:$missing"

  # Membership, and the constraint that keeps the existing no-sudo check
  # meaningful: a claw-admin holds a grant on named scripts, never the sudo group.
  for a in "${CLAW_ADMINS[@]:-}"; do
    [ -z "$a" ] && continue
    getent passwd "$a" >/dev/null 2>&1 || continue
    gtext=" $(id -nG "$a" 2>/dev/null || true) "
    case "$gtext" in
      *" ${CLAW_ADMIN_GROUP} "*) : ;;
      *) bad "${a} is not in ${CLAW_ADMIN_GROUP}"; roster_ok=0 ;;
    esac
    case "$gtext" in
      *" sudo "*) bad "${a} is in the sudo group -- the role grants named scripts, never general root"; roster_ok=0 ;;
    esac
  done
  if [ "${#CLAW_ADMINS[@]}" -gt 0 ] && [ "$roster_ok" -eq 1 ]; then
    ok "every claw-admin is in ${CLAW_ADMIN_GROUP} and none is in the sudo group"
    warn "a group added while somebody is logged in does not reach that session; they log in again"
  fi

  # ---- the installed provisioning plane ----
  # /opt/commonclaw is traversable by everyone because the skill tree beneath it
  # is read by every member's session. The provisioning prefix inside it is not.
  install -d -m 0755 -o root -g root "$OPT_ROOT"
  install -d -m 0750 -o root -g root "$INSTALL_PREFIX"
  install -d -m 0750 -o root -g root "${INSTALL_PREFIX}/scripts"
  install -d -m 0750 -o root -g root "${INSTALL_PREFIX}/templates"

  local f base
  if [ "$SCRIPT_DIR" = "${INSTALL_PREFIX}/scripts" ]; then
    warn "running from the installed prefix, so the scripts were not copied over themselves"
  else
    for f in "$SCRIPT_DIR"/*.sh; do
      [ -r "$f" ] || continue
      install -m 0750 -o root -g root "$f" "${INSTALL_PREFIX}/scripts/$(basename "$f")"
    done
  fi

  # The WHOLE template directory, never a named subset. A subset drifts the
  # first time the scaffold needs another template, and the drift surfaces as a
  # failed run on somebody's claw rather than here.
  for f in "$TEMPLATE_DIR"/*; do
    [ -f "$f" ] || continue
    install -m 0640 -o root -g root "$f" "${INSTALL_PREFIX}/templates/$(basename "$f")"
  done

  local g
  for g in "${GRANTED_SCRIPTS[@]}"; do
    check "granted script installed at ${g}" test -x "$g"
    check "$(basename "$g") is 0750 root:root -- a script its caller can edit is a grant of everything" \
      bash -c "[ \"\$(stat -c '%a %U:%G' '$g')\" = '750 root:root' ]"
  done
  check "the adjacent decoy script exists, so a refusal of it means something" test -f "$DECOY_SCRIPT"
  check "install prefix is 0750 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$INSTALL_PREFIX')\" = '750 root:root' ]"

  # Verified rather than assumed: every template beside this script reached the
  # prefix. This is the check that catches a subset.
  local tmpl_missing=""
  for f in "$TEMPLATE_DIR"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    [ -f "${INSTALL_PREFIX}/templates/${base}" ] || tmpl_missing="$tmpl_missing $base"
  done
  if [ -z "$tmpl_missing" ]; then ok "every template reached the prefix (the scaffold resolves them one directory up from its own)"
  else bad "template(s) missing from the prefix:$tmpl_missing -- the scaffold exits at preflight without them"; fi

  # ---- the member plane's record ----
  # Seeded once, NEVER overwritten. It is an append-only event log like the seat
  # roster, and a re-run that rewrote it would erase what the firm did to its own
  # claw. World-readable for the same reason the changelog is: its first reader
  # is a member's own session asking what changed under them.
  install -d -m 0755 -o root -g root "$ETC_ROOT"
  if [ -e "$ADMIN_LOG" ]; then
    say "  keeping the existing member-plane log at ${ADMIN_LOG}"
  else
    cat > "$ADMIN_LOG" <<'ADMINEOF'
# Member-plane log

What this claw's own admins did to it through the granted doors. Append-only.
Each row is one act that changed the machine.

This is not the changelog. `changelog.md` records what provisioning gave this
claw. This file records what the firm did to it. Two authors, so two files.

Refusals are not here. A refused call changed nothing, and `sudo` already
records every invocation with who made it.

No credential value, length or digest is ever written here. This file is
world-readable, and the doors report those to their caller instead.

| When (UTC) | Who | Action | Subject |
|---|---|---|---|
ADMINEOF
    say "  seeded the member-plane log at ${ADMIN_LOG}"
  fi
  chmod 0644 "$ADMIN_LOG"; chown root:root "$ADMIN_LOG"
  check "member-plane log present" test -s "$ADMIN_LOG"
  check "member-plane log is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$ADMIN_LOG')\" = '644 root:root' ]"
  check "member-plane log carries its table header, so a granted script can append a row" \
    grep -qxF '|---|---|---|---|' "$ADMIN_LOG"

  # ---- the sudoers drop-in ----
  # No dot in the filename and no trailing tilde: sudo silently ignores both,
  # and an ignored grant looks exactly like a grant that was never written.
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<SUDOEOF
# Managed by provision-claw.sh. Do not edit on the claw.
#
# The firm's own admins run the claw's own provisioning scripts as root, and
# nothing else. Adding an operation to the member plane means adding its script
# to this alias and re-running the exactly-scoped control.
#
# NOPASSWD is required, not a convenience: accounts here are created without a
# password, so a grant that prompts is a grant that never opens.
#
# No argument pattern appears below. A Cmnd with no arguments permits any
# arguments, and that is the intent: each script validates its own arguments
# (workspace name pattern, members resolved through getent; seat person and core
# shape, and a reason that cannot carry a line break or a brace; a new person's
# name constrained rather than escaped, and their key refused unless it is a
# public key of a named type; a destroy target that must carry a manifest and
# must still resolve to a directory directly under the workspace root, so a
# symlink cannot walk the grant out of it; a key door that acts only on a person
# already in the members group, refuses to write through a symlink or a second
# hard link into a home its owner controls, and refuses a revoke that would leave
# somebody no key at all unless the caller says the lockout is the intent) and a
# second copy of those rules here would drift from the copy the script enforces.
#
# One of these takes no path argument at all. The token door composes its drop
# path from the caller's own uid, because a caller-supplied path would let a
# member name any file root can read and have it installed and then destroyed.
Cmnd_Alias COMMONCLAW_ADMIN_OPS = $(IFS=,; printf '%s' "${GRANTED_SCRIPTS[*]}")

%${CLAW_ADMIN_GROUP} ALL=(root) NOPASSWD: COMMONCLAW_ADMIN_OPS
SUDOEOF

  # Validate BEFORE install. A malformed file in /etc/sudoers.d can break sudo
  # for every caller on the claw, including the one holding the only door.
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    ok "sudoers drop-in parses under visudo before being installed"
    install -m 0440 -o root -g root "$tmp" "$SUDOERS_DROPIN"
  else
    bad "sudoers drop-in FAILED visudo -- NOT installed"
    visudo -cf "$tmp" 2>&1 | sed 's/^/    /' >&2 || true
  fi
  rm -f "$tmp"

  check "drop-in installed 0440 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$SUDOERS_DROPIN')\" = '440 root:root' ]"

  # A drop-in is inert unless sudoers includes the directory. Debian ships the
  # line; a claw is not a claim.
  local sudoers_text; sudoers_text="$(cat /etc/sudoers 2>/dev/null || true)"
  case "$sudoers_text" in
    *"includedir /etc/sudoers.d"*) ok "sudoers includes the drop-in directory" ;;
    *) bad "sudoers carries no includedir for /etc/sudoers.d -- the grant is written and inert" ;;
  esac

  # ---- the exactly-scoped control ----
  #
  # A refusal on its own is not evidence. A caller with no sudoers entry at all,
  # or a claw whose sudo is broken, refuses everything and reads as a perfectly
  # scoped grant. So the control is a PAIR: the grant opens for exactly what it
  # names, and an adjacent script -- same directory, same owner, not granted --
  # is refused. That pair is the difference between a per-script grant and a
  # per-directory grant, and the two are indistinguishable until something
  # beside the first file is asked for and refused.
  local prover=""
  for a in "${CLAW_ADMINS[@]:-}"; do
    [ -z "$a" ] && continue
    getent passwd "$a" >/dev/null 2>&1 || continue
    gtext=" $(id -nG "$a" 2>/dev/null || true) "
    case "$gtext" in *" ${CLAW_ADMIN_GROUP} "*) prover="$a"; break ;; esac
  done

  if [ -z "$prover" ]; then
    warn "grant control NOT RUN: this claw carries no ${CLAW_ADMIN_GROUP} member. An unrun control is not a passed one, and this one cannot be faked from root -- re-run it once the firm names its admins."
    human "name the firm's own admins with --claw-admins and re-run this phase, then confirm the grant control passes both legs"
    return 0
  fi

  for g in "${GRANTED_SCRIPTS[@]}"; do
    check "grant opens for $(basename "$g"), which it names (as ${prover}, not as root)" \
      member_may_run "$prover" "$g"
  done
  check "decoy refused: the adjacent script in the same directory is NOT granted" \
    member_refused "$prover" "$DECOY_SCRIPT"
  check "decoy cannot be executed either, so nothing beside the grant runs" \
    member_cannot_execute "$prover" "$DECOY_SCRIPT"
  check "a shell is refused" member_refused "$prover" /bin/sh

  # The listing is compared as a SET, not counted. Counting entries answered the
  # question only while the alias named one script, and a count that has to be
  # edited every time an operation joins the member plane is a check that will
  # one day be edited to match whatever the listing happens to say.
  local listing seen want
  listing="$(sudo -u "$prover" -H sudo -n -l 2>/dev/null || true)"
  seen="$(grep -oE '/[^ ,]+\.sh' <<< "$listing" | LC_ALL=C sort -u || true)"
  want="$(printf '%s\n' "${GRANTED_SCRIPTS[@]}" | LC_ALL=C sort -u)"
  if [ "$seen" = "$want" ]; then
    ok "the full listing for ${prover} carries exactly the ${#GRANTED_SCRIPTS[@]} granted script(s) and nothing else"
  else
    bad "the listing for ${prover} does not match the granted set -- it carries: $(printf '%s' "$seen" | tr '\n' ' ')"
  fi
  # A path set can match while the grant is still wide: one entry naming ALL
  # grants everything and carries no path at all for the comparison above to see.
  #
  # Match the SHAPE, not a list of spellings. sudo writes the runas
  # specification several ways -- (ALL), (root), (ALL : ALL) -- and enumerating
  # them means the check silently stops covering whichever form nobody thought
  # of. Every one of them ends the specification with a parenthesis before the
  # command, so a command of ALL is what is being looked for.
  case "$listing" in
    *") ALL"*|*"NOPASSWD: ALL"*)
      bad "the listing for ${prover} carries a blanket ALL entry -- the grant is not scoped to scripts" ;;
    *) ok "the listing carries no blanket ALL entry" ;;
  esac
}

# ---------------------------------------------------------------- phase 14

# Pull the managed-tier count out of a core's own debug log. This is the
# readout that makes a wrong path visible: a wrong path loads zero and says
# nothing else about it.
managed_count() {
  local log="$1" hit
  hit="$(grep -o 'managed: [0-9]*' "$log" 2>/dev/null | tail -1 || true)"
  printf '%s' "${hit##* }"
}

phase_14_skill_plane() {
  head1 14 "the fleet skill plane"

  if [ -z "$SKILLS_MANIFEST" ]; then
    warn "phase 14 NOT RUN: no --skills-manifest given, so nothing declares what this claw should carry"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would materialize ${#SKILL_NAMES[@]} skill(s) into ${SKILLS_CANON} and link both machine directories"
    return 0
  fi

  install -d -m 0755 -o root -g root "$OPT_ROOT" "$SKILLS_CANON"
  install -d -m 0755 -o root -g root /etc/claude-code /etc/claude-code/.claude "$CLAUDE_MACHINE_SKILLS"
  install -d -m 0755 -o root -g root /etc/codex "$CODEX_MACHINE_SKILLS"

  # ---- converge away the wrong path ----
  # The machine-path control below plants a probe at the path with the inner
  # .claude segment DROPPED, to prove that placement is invisible. Creating that
  # probe creates its parent, and removing the probe left the parent behind, so
  # every claw the control has ever run on now carries an empty directory that
  # looks like a skills tier and is not one.
  #
  # Cleaned here rather than only at the end of the control, so a claw that
  # already carries the leak heals on its next ordinary run instead of waiting
  # for a control that may not execute.
  #
  # ONLY WHEN EMPTY. A directory somebody put something in is somebody's, and it
  # is reported rather than removed -- whatever is in there is not loading, which
  # is worth a person's attention and is not worth a silent delete.
  if [ -d "$WRONG_MACHINE_SKILLS" ]; then
    if rmdir "$WRONG_MACHINE_SKILLS" 2>/dev/null; then
      warn "removed the empty ${WRONG_MACHINE_SKILLS}: it is the dropped-segment path, it loads nothing, and a control left it behind"
    else
      bad "${WRONG_MACHINE_SKILLS} exists and is not empty -- nothing there loads, because the managed path carries an inner .claude segment. Move its contents to ${CLAUDE_MACHINE_SKILLS} or delete them by hand."
    fi
  fi

  # ---- materialize one canonical copy per skill ----
  local i name src dest sdig ddig d changed=0 unchanged=0 want
  for i in "${!SKILL_NAMES[@]}"; do
    name="${SKILL_NAMES[$i]}"; src="${SKILL_SOURCES[$i]}"; dest="${SKILLS_CANON}/${name}"
    sdig="$(tree_digest "$src")"
    ddig=""; [ -d "$dest" ] && ddig="$(tree_digest "$dest")"
    if [ "$sdig" = "$ddig" ]; then
      unchanged=$((unchanged+1))
    else
      rm -rf -- "$dest"; mkdir -p -- "$dest"
      cp -a -- "${src}/." "${dest}/"
      chown -R root:root -- "$dest"
      # world-readable, nobody-but-root-writable: members read these, and a
      # skill a member can edit is a skill a member can rewrite for everybody.
      chmod -R go-w,a+rX -- "$dest"
      changed=$((changed+1))
    fi
    SKILL_DIGESTS[i]="$(tree_digest "$dest")"

    # A declared pin is ENFORCED. An unenforced pin is a decorative field, and a
    # decorative version is worse than none: it reads as a guarantee.
    want="${SKILL_PINS[$i]}"
    if [ -n "$want" ]; then
      want="${want#sha256:}"
      if [ "$want" = "${SKILL_DIGESTS[$i]}" ]; then ok "${name}: pinned digest matches what was installed"
      else bad "${name}: PIN MISMATCH -- manifest pins ${want}, the source materialized to ${SKILL_DIGESTS[$i]}"; fi
    fi

    for d in "$CLAUDE_MACHINE_SKILLS" "$CODEX_MACHINE_SKILLS"; do
      if [ -e "${d}/${name}" ] && [ ! -L "${d}/${name}" ]; then
        bad "${d}/${name} exists as a real directory -- that is a second copy of a skill; resolve it by hand"
      else
        ln -sfn "$dest" "${d}/${name}"
      fi
    done
  done
  say "  skills: ${#SKILL_NAMES[@]} declared   rewritten: ${changed}   already current: ${unchanged}"

  # ---- converge: what the manifest no longer declares does not stay ----
  # Bounded on purpose. Under the canonical root everything is this mechanism's
  # own; in the machine directories only symlinks pointing INTO that root are
  # touched, so anything another hand put there is left exactly alone.
  local entry base declared target pruned=0
  for entry in "$SKILLS_CANON"/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"; declared=0
    for name in "${SKILL_NAMES[@]}"; do [ "$name" = "$base" ] && { declared=1; break; }; done
    [ "$declared" -eq 1 ] && continue
    rm -rf -- "$entry"; pruned=$((pruned+1))
  done
  for d in "$CLAUDE_MACHINE_SKILLS" "$CODEX_MACHINE_SKILLS"; do
    for entry in "$d"/*; do
      [ -L "$entry" ] || continue
      target="$(readlink -- "$entry")"
      case "$target" in "${SKILLS_CANON}/"*) : ;; *) continue ;; esac
      base="$(basename "$entry")"; declared=0
      for name in "${SKILL_NAMES[@]}"; do [ "$name" = "$base" ] && { declared=1; break; }; done
      [ "$declared" -eq 1 ] && continue
      rm -f -- "$entry"; pruned=$((pruned+1))
    done
  done
  [ "$pruned" -eq 0 ] || warn "removed ${pruned} entr(ies) the manifest no longer declares"

  # ---- the materialized declaration ----
  # Every digest below was MEASURED after install. The file carries no
  # generation timestamp on purpose: a timestamp would make two identical runs
  # produce two different files, and convergence would stop being observable.
  {
    printf '# Materialized skill declaration. Written by provision-claw.sh.\n'
    printf '# Digests are MEASURED after install, never copied from the manifest.\n'
    printf '# Do not hand-edit. The next provisioning run rewrites this file.\n'
    printf 'source_manifest: %s\n' "$SKILLS_MANIFEST"
    printf 'canonical_root: %s\n' "$SKILLS_CANON"
    printf 'machine_dirs:\n'
    printf '  - %s\n' "$CLAUDE_MACHINE_SKILLS"
    printf '  - %s\n' "$CODEX_MACHINE_SKILLS"
    printf 'skills:\n'
    for i in "${!SKILL_NAMES[@]}"; do
      printf '  %s:\n' "${SKILL_NAMES[$i]}"
      printf '    source: %s\n' "${SKILL_SOURCES[$i]}"
      printf '    digest: sha256:%s\n' "${SKILL_DIGESTS[$i]}"
      [ -z "${SKILL_PINS[$i]}" ] || printf '    pin: %s\n' "${SKILL_PINS[$i]}"
    done
  } > "$SKILLS_DECLARATION"
  chmod 0644 "$SKILLS_DECLARATION"

  local struct_ok=1
  for i in "${!SKILL_NAMES[@]}"; do
    name="${SKILL_NAMES[$i]}"; dest="${SKILLS_CANON}/${name}"
    [ -r "${dest}/SKILL.md" ] || { bad "${name}: no readable SKILL.md at ${dest}"; struct_ok=0; }
    for d in "$CLAUDE_MACHINE_SKILLS" "$CODEX_MACHINE_SKILLS"; do
      [ -L "${d}/${name}" ] && [ "$(readlink -f "${d}/${name}")" = "$(readlink -f "$dest")" ] \
        || { bad "${d}/${name} does not resolve to ${dest}"; struct_ok=0; }
    done
    grep -qE "^  ${name}:$" "$SKILLS_DECLARATION" || { bad "${name} is installed but absent from ${SKILLS_DECLARATION}"; struct_ok=0; }
  done
  [ "$struct_ok" -eq 1 ] && ok "every declared skill is materialized once and linked into both machine directories"

  # ---- can an unprivileged member actually read it? ----
  local member="${PEOPLE[0]:-}"
  if [ -n "$member" ] && [ "${#SKILL_NAMES[@]}" -gt 0 ]; then
    name="${SKILL_NAMES[0]}"
    if sudo -u "$member" -H test -r "${CLAUDE_MACHINE_SKILLS}/${name}/SKILL.md" \
       && sudo -u "$member" -H test -r "${CODEX_MACHINE_SKILLS}/${name}/SKILL.md"; then
      ok "an unprivileged member reads a shipped skill through both machine paths"
    else
      bad "a member cannot read a shipped skill through the machine paths -- check traversal on ${OPT_ROOT}"
    fi
  fi

  phase_14_core_observables "$member"

  # The end state, asserted rather than assumed. The convergence step and the
  # control's own cleanup are two different ways to arrive here, and neither is
  # evidence on its own: one runs before the control and the other only when the
  # control runs at all.
  if [ -d "$WRONG_MACHINE_SKILLS" ]; then
    bad "${WRONG_MACHINE_SKILLS} is still on this claw after phase 14 -- it loads nothing and it looks like a tier"
  else
    ok "the dropped-segment path ${WRONG_MACHINE_SKILLS} is absent: nothing on this claw looks like a skills tier and is not one"
  fi
}

# The cores' own readouts, run as an unprivileged member out of a throwaway
# home. These are the only checks that answer the question the phase exists for:
# not "is the file there", but "does a member's session load it".
#
# THE HOME IS THROWAWAY ON PURPOSE, AND IT IS THE POINT OF THIS WHOLE BLOCK.
# These readouts used to run under the member's own home. That made a vendor
# provisioning run start two sessions on the firm's own subscription, attach
# whatever cloud connectors they have configured, and leave transcripts and
# cache entries in their home -- on the one class of machine where the
# management contract promises the vendor stays out of the member's plane.
# Nothing in this script changed to cause it. The price arrived the day the box
# gained its first seat, because a readout that costs nothing on an empty home
# costs somebody's money on a seated one.
#
# What these readouts actually read is the MACHINE tier, which is a fixed
# machine-wide path. The home moves the USER tier and leaves the machine count
# untouched, measured on two claws from opposite sides, one seated and one not.
# The persistent-session core writes its skill-loading line while it starts,
# before it authenticates anything, so an unauthenticated core answers this
# question exactly as well as a paid one does.
#
# So each core is handed a directory the member owns for the length of the
# check. It finds no credentials there, refuses to start a session, and reports
# what it loaded anyway. Nothing is spent, no connector is opened, and every
# byte either core writes lands in a directory that is removed below.
phase_14_core_observables() {
  local member="$1"
  [ -n "$member" ] || { warn "core resolution NOT RUN: this claw carries nobody to run it as"; return 0; }

  local home probe_wrong probe_right probe_name="zz-commonclaw-pathcontrol"
  home="$(getent passwd "$member" | cut -d: -f6)"

  # Made once for both cores, owned by the member because the core writes into
  # it as the member, and 0700 because it is nobody else's business.
  local run_home
  run_home="$(mktemp -d /tmp/commonclaw-skillprobe-XXXXXX)"
  chown "$member" "$run_home"; chmod 0700 "$run_home"

  # env -i on every core invocation below, rather than sudo -H. Two reasons, and
  # the second is the one that bites: -H would hand the core the member's own
  # home, which is the cost this block exists to remove; and an ANTHROPIC_API_KEY
  # or a CLAUDE_CONFIG_DIR sitting in the environment of whoever ran this script
  # would authenticate the core and start spending on a check that needs no
  # account at all. PATH is stated because the cores shell out to ordinary tools.
  local core_env=(env -i "HOME=${run_home}" PATH=/usr/local/bin:/usr/bin:/bin)

  # ---- the per-task core: costs nothing and needs no seat ----
  local codex_bin=/usr/local/bin/codex out missing="" name
  if [ -x "$codex_bin" ]; then
    # From /tmp on purpose: this core walks upward from the working directory
    # looking for skills, so running anywhere inside a workspace would make a
    # hit ambiguous between the machine tier and the directory tier. The
    # throwaway home is a sibling of that walk rather than a parent of it, so it
    # cannot answer for the machine tier either.
    out="$(sudo -u "$member" "${core_env[@]}" bash -c "cd /tmp && '$codex_bin' debug prompt-input x" </dev/null 2>/dev/null || true)"
    for name in "${SKILL_NAMES[@]}"; do
      grep -qF "$name" <<< "$out" || missing="$missing $name"
    done
    if [ -z "$missing" ]; then ok "per-task core: every shipped skill is in the model-visible prompt, from a member session that opened nothing in ${home}"
    else bad "per-task core does not surface:$missing"; fi
  else
    warn "per-task core resolution NOT RUN: no binary at ${codex_bin}"
  fi

  # ---- the persistent-session core: needs the binary, and no longer a seat ----
  #
  # Keyed on what the measurement reads. The guard used to refuse when the
  # member held no credential file, and the thing it guarded never opened that
  # file: it greps a count out of the core's own debug log, and that count comes
  # from a machine-wide path. So it refused on the absence of a thing its own
  # measurement never read, which parked the control on every claw until
  # somebody logged in, and then charged them for it once they had.
  local cbin="${home}/.local/bin/claude"
  if [ ! -x "$cbin" ]; then
    rm -rf -- "$run_home"
    warn "machine-path control NOT RUN: ${member} has no executable core at ${cbin}, and the readout is taken from that binary. An unrun control is not a passed one -- re-run this phase once phase 10 has installed it."
    human "re-run phase 14 once the persistent-session core is installed, and require the two probe placements to give DIFFERENT managed counts"
    return 0
  fi

  # THE CONTROL. The managed path carries an inner .claude segment that is easy
  # to drop, and a wrong path fails SILENTLY: zero skills load and nothing says
  # why. So the same probe is read twice, from two placements, and the two
  # counts must DIFFER. One placement alone proves nothing -- a count that never
  # moves is not measuring the directory.
  #
  # A COST THIS CONTROL CANNOT GIVE UP, NAMED HERE SO IT CLASSIFIES ON SIGHT.
  # The second placement is the LIVE machine-wide tier, the same directory every
  # shipped skill is linked into, and a member session starting while the probe
  # sits there loads it. That window is the measurement: reading a directory that
  # is not the live tier would prove something about a directory nobody uses, and
  # the whole defect this control exists to catch is the live tier going unread.
  # So the window is accepted rather than removed, and it is bounded three ways
  # -- the probe is planted immediately before the read and removed immediately
  # after, the read is capped by the `timeout` below, and the probe's own
  # description tells a core that loads it to ignore it.
  #
  # ANY APPEARANCE OF `zz-commonclaw-pathcontrol` IN A MEMBER'S SESSION LOG IS
  # THIS PHASE. It is a provisioning artifact, not a finding, and not a skill
  # anybody shipped.
  probe_wrong="${WRONG_MACHINE_SKILLS}/${probe_name}"          # the segment dropped
  probe_right="${CLAUDE_MACHINE_SKILLS}/${probe_name}"         # the real path
  rm -rf -- "$probe_wrong" "$probe_right"

  # Planting the wrong-path probe CREATES its parent, and that parent is not a
  # real tier. Whether this run made it decides whether this run removes it: a
  # directory that was already there when the phase started is somebody else's
  # to explain, and the convergence step above has already reported it.
  local made_wrong_parent=0
  [ -d "$WRONG_MACHINE_SKILLS" ] || made_wrong_parent=1

  # The log is written by the CORE, which runs as the member. Creating the file
  # here would create it as root at 0600, and the member could not write it --
  # the readout would come back empty and the control would report that both
  # placements measured nothing. The throwaway home is already the member's, so
  # the core creates its own file inside a directory it owns.
  local declared="${#SKILL_NAMES[@]}" log_a log_b count_a count_b
  log_a="${run_home}/wrong-path.log"; log_b="${run_home}/real-path.log"

  write_probe() {
    install -d -m 0755 -o root -g root "$1"
    cat > "${1}/SKILL.md" <<PROBEEOF
---
name: ${probe_name}
description: "Throwaway path control written by provision-claw.sh. Does nothing. Ignore it for real work."
---
Path control. If this is loaded, the directory it sits in is being read.
PROBEEOF
    chmod 0644 "${1}/SKILL.md"
  }
  read_managed() {
    # 60 seconds where this once allowed 240. The old number was sized for a
    # round trip to somebody's account. This core finds no credentials in the
    # home it is handed, refuses to open a session, and is done in about a
    # second, so a minute is already generous and a core that hangs past it is a
    # failure worth seeing rather than something to wait out.
    sudo -u "$member" "${core_env[@]}" timeout 60 "$cbin" --debug-file "$1" \
      -p "machine-path control. This session is never authenticated and sends nothing." \
      </dev/null >/dev/null 2>&1 || true
    managed_count "$1"
  }

  write_probe "$probe_wrong"
  count_a="$(read_managed "$log_a")"
  rm -rf -- "$probe_wrong"

  write_probe "$probe_right"
  count_b="$(read_managed "$log_b")"
  rm -rf -- "$probe_right"

  # An ABSENT readout is its own failure and says something different from two
  # matching ones: nothing was measured at all, so neither placement was tested.
  # Reporting it as "the same verdict twice" would send the next reader looking
  # at the directories when the core never produced a count.
  if [ -z "$count_a" ] || [ -z "$count_b" ]; then
    bad "machine-path control: the core produced no managed count, so neither placement was measured -- check that the member can run the core and write its debug log"
  elif [ "$count_a" = "$declared" ] && [ "$count_b" = "$((declared + 1))" ]; then
    ok "machine-path control: the probe is invisible without the inner .claude segment (managed ${count_a}) and visible with it (managed ${count_b}); every shipped skill loads at the real path"
  elif [ "$count_a" = "$count_b" ]; then
    bad "machine-path control: both probe placements gave managed ${count_a}, so the count is not measuring the directory and this readout proves nothing"
  else
    bad "machine-path control: expected managed ${declared} then $((declared + 1)), got ${count_a} then ${count_b}"
  fi

  # The stayed-out-of-their-home claim, taken from the core's OWN report rather
  # than from the comment at the top of this function. The core names the tiers
  # it loaded, and the user tier it names has to be the throwaway one. If a
  # later core ignores the home it is handed, or somebody re-points this at the
  # member's own home, this is what notices, and it notices by reading what the
  # core says it did instead of what this script believes it asked for.
  local user_tier
  user_tier="$(grep 'Loading skills from:' "$log_b" 2>/dev/null | tail -1 | grep -o 'user=[^,]*' || true)"
  case "$user_tier" in
    "user=${run_home}"*)
      ok "the readout ran out of a throwaway home: nothing under ${home} was opened, no account was reached, and nobody's subscription paid for this check" ;;
    "")
      bad "the readout does not say which tiers it loaded, so it cannot be shown to have stayed out of ${home}" ;;
    *)
      bad "the readout loaded a user tier outside the throwaway home (${user_tier}) -- it is reading somebody's home, which is the cost this control exists to not have" ;;
  esac

  rm -rf -- "$run_home"
  rm -rf -- "$probe_wrong" "$probe_right"

  # Leave the claw as the phase found it. rmdir, never rm -rf: if anything else
  # arrived in there while the control ran, it is not this control's to delete.
  if [ "$made_wrong_parent" -eq 1 ] && [ -d "$WRONG_MACHINE_SKILLS" ]; then
    if rmdir "$WRONG_MACHINE_SKILLS" 2>/dev/null; then
      ok "the machine-path control removed the wrong-path directory it created"
    else
      bad "the machine-path control created ${WRONG_MACHINE_SKILLS} and could not remove it -- something else is in there"
    fi
  fi
}


# ---------------------------------------------------------------- phase 15

phase_15_release_rail() {
  head1 15 "the release rail"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would seed ${UPDATER_CONF}, install the updater unit and its timer (DISABLED)"
    return 0
  fi

  install -d -m 0755 -o root -g root "$ETC_ROOT"
  install -d -m 0755 -o root -g root /var/lib/commonclaw/updater
  install -d -m 0755 -o root -g root /var/log/commonclaw/updater

  # ---- the firm's own decision, seeded once ----
  # NEVER REWRITTEN. It carries the mode, and a run that rewrote it would flip a
  # firm that chose manual back to auto with nothing saying so. Same law as the
  # seat roster and the member-plane log.
  if [ -e "$UPDATER_CONF" ]; then
    say "  keeping the existing updater config at ${UPDATER_CONF}"
  else
    cat > "$UPDATER_CONF" <<UPDEOF
# How this claw takes releases. Written once by provisioning and never again,
# because it carries a decision this firm made rather than a measurement.
#
# MODE      auto   this claw takes validated releases on its own.
#           manual nothing lands unless somebody here asks. The claw still
#                  checks and still records what it is declining.
# CHANNEL   which tier's releases this claw takes.
#
# Change MODE through the granted door, not by editing this file:
#   sudo ${GRANTED_MODE} --mode manual
#
# The quiet window and the limit on deferral are NOT here. They are constants in
# the updater, so a claw cannot stretch them, for the same reason a core floor
# has no per-claw override.
MODE="auto"
CHANNEL="${RELEASE_CHANNEL}"
RELEASE_REPO="${RELEASE_REPO}"
# How this claw proves it may read the release repository. Empty means an
# unauthenticated fetch. It is resolved at invocation and never written to disk.
FETCH_TOKEN_CMD=""
UPDEOF
    say "  seeded ${UPDATER_CONF}"
  fi
  chmod 0644 "$UPDATER_CONF"; chown root:root "$UPDATER_CONF"

  cat > /etc/systemd/system/commonclaw-update.service <<'SVCEOF'
[Unit]
Description=Firm-VM release update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/commonclaw/provision-claw/scripts/commonclaw-update.sh
Nice=10
IOSchedulingClass=idle
SVCEOF

  # HOURLY, and the updater does not depend on that. The deferral gate is a range
  # with a bound rather than an equality on one hour, so a missed tick delays a
  # release and cannot strand it. That independence is the point: the backup
  # rail's reclaim was gated on an hour this timer never fired in, and it never
  # ran on any claw.
  cat > /etc/systemd/system/commonclaw-update.timer <<'TIMEOF'
[Unit]
Description=Firm-VM release check, hourly

[Timer]
OnCalendar=hourly
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
TIMEOF

  systemctl daemon-reload

  check "updater installed and executable" test -x "${INSTALL_PREFIX}/scripts/commonclaw-update.sh"
  check "updater parses" bash -n "${INSTALL_PREFIX}/scripts/commonclaw-update.sh"
  check "updater config present" test -s "$UPDATER_CONF"
  check "updater config is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$UPDATER_CONF')\" = '644 root:root' ]"
  check "update service registered" systemctl cat commonclaw-update.service
  check "update timer registered"   systemctl cat commonclaw-update.timer
  check "the mode door is installed where the grant names it" test -x "$GRANTED_MODE"

  # The conf carries no repository until somebody sets one, so a fresh claw
  # cannot pull from a default that was never chosen for it.
  if grep -q '^RELEASE_REPO=""' "$UPDATER_CONF"; then
    warn "no RELEASE_REPO in ${UPDATER_CONF}: this claw checks nothing until one is set"
  fi

  # INSTALLED DISABLED, like the backup timer, and for a stronger reason. Enabling
  # it is what puts a claw on auto-updates, and the fleet's cost-and-timing
  # register carries a must-fix list that gates exactly that. A run that enabled
  # the timer would cross that gate silently.
  if systemctl is-enabled commonclaw-update.timer >/dev/null 2>&1; then
    warn "update timer already enabled on this claw"
  else
    ok "update timer installed DISABLED (set the repository, ride the rail on staging, then enable)"
  fi

  human "enable commonclaw-update.timer only after the release rail has been ridden on the staging tier and the cost-and-timing must-fix list is closed"
}

# ---------------------------------------------------------------- phase 16

phase_16_session_bus() {
  head1 16 "the claw's shared session bus"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would create ${BUS_HOME} 2770 root:${MEMBERS_GROUP}, install ${BUS_CLI} + ${BUS_JOIN_HOOK},"
    say "  register the session-start join in ${MANAGED_SETTINGS}, and install ${BUS_DOC}"
    return 0
  fi

  # THE GROUP IS THE WHOLE ACCESS MODEL, so its absence is a refusal and not a
  # warning. Creating the group here would hand the bus to a set of people
  # nobody has decided on; `claw-members` is written where people are made.
  if ! getent group "$MEMBERS_GROUP" >/dev/null 2>&1; then
    bad "no ${MEMBERS_GROUP} group on this claw, so there is nobody to share a bus between -- phase 8 makes it"
    return 0
  fi

  # ---- the state root, and the one mode that decides whether any of this works ----
  #
  # 0755 BECAUSE MEMBERS MUST TRAVERSE IT. Everything under this root belongs to
  # a different reader: the updater's defer directory is already 0755 for the
  # same reason, and the backup rail's prune stamp is a timestamp. Nothing
  # secret has ever lived here; the claw's credentials are in /etc/commonclaw.
  #
  # ⚠ commonclaw-backup.sh USED TO RESET THIS DIRECTORY TO 0700 on every run
  # (`install -d -m 0700`, which applies the mode to a directory that already
  # exists -- measured 2026-08-14). That silently cut every member off from the
  # bus one backup after provisioning installed it, and the sessions would have
  # kept reporting a healthy join into a directory they could no longer reach.
  # The backup rail now creates this root at the same mode as every other writer
  # of it. If a third writer appears, it agrees with these two or the bus dies
  # on a schedule.
  install -d -m 0755 -o root -g root "$STATE_ROOT"
  check "${STATE_ROOT} is 0755 root:root so a member can traverse it to the bus" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$STATE_ROOT')\" = '755 root:root' ]"

  # ---- the bus home ----
  #
  # SETGID IS NOT DECORATION HERE. Without it a file abigail creates lands in
  # her own primary group and jeremiah cannot append to it, so the first
  # cross-member message fails and every one after it. The setgid bit is what
  # makes every file on this bus reachable by every member regardless of who
  # wrote it.
  install -d -m 2770 -o root -g "$MEMBERS_GROUP" "$BUS_HOME"
  chmod 2770 "$BUS_HOME"        # install -d honors the umask on some coreutils; this does not
  check "${BUS_HOME} is 2770 root:${MEMBERS_GROUP} -- setgid, group-writable, closed to the world" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$BUS_HOME')\" = '2770 root:${MEMBERS_GROUP}' ]"

  # Default ACLs, the same instrument a workspace uses. The setgid bit carries
  # the group down; it does not carry the group's WRITE bit down, and a member
  # running with a 022 umask would create files their peers cannot append to.
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -d -m "g:${MEMBERS_GROUP}:rwx" -m "g:${MEMBERS_GROUP}:rwx" "$BUS_HOME" 2>/dev/null \
      && ok "default ACL on ${BUS_HOME}: a member's umask cannot lock their peers out of a file they create" \
      || warn "could not set the default ACL on ${BUS_HOME} -- the bus still works, but a member with a 022 umask can write a file their peers cannot append to"
  else
    warn "setfacl absent, so ${BUS_HOME} has no default ACL"
  fi

  # ---- the two programs every member's session runs ----
  install -d -m 0755 -o root -g root "$CLAW_BIN"
  local p missing=""
  for p in bus claw-bus-join; do
    [ -r "${PAYLOAD_DIR}/${p}" ] || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    bad "payload missing from ${PAYLOAD_DIR}:${missing} -- copy the whole skill directory"
    return 0
  fi
  # `payload/bus` IS the bus program. A fleet program every claw runs belongs to
  # the release rather than to one person's skill tree, which would drift the
  # first time that tree is reorganized for its own reasons. The orchestrate
  # skill reaches this same file through a symlink, so the tree carries one copy
  # and this phase installs the original.
  install -m 0755 -o root -g root "${PAYLOAD_DIR}/bus" "$BUS_CLI"
  install -m 0755 -o root -g root "${PAYLOAD_DIR}/claw-bus-join" "$BUS_JOIN_HOOK"
  check "${BUS_CLI} is 0755 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$BUS_CLI')\" = '755 root:root' ]"
  check "${BUS_JOIN_HOOK} is 0755 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$BUS_JOIN_HOOK')\" = '755 root:root' ]"

  # ---- the join, registered where the harness reads it ----
  #
  # MERGED, NEVER OVERWRITTEN. This file is the machine's policy tier and the
  # firm may have put other things in it. Two keys are ours; the rest is
  # somebody else's decision and survives this run untouched.
  install -d -m 0755 -o root -g root "$(dirname "$MANAGED_SETTINGS")"
  local existing='{}' merged
  [ -s "$MANAGED_SETTINGS" ] && existing="$(cat "$MANAGED_SETTINGS")"
  if ! merged="$(printf '%s' "$existing" | jq \
        --arg dir "$BUS_HOME" --arg hook "$BUS_JOIN_HOOK" '
        .env = ((.env // {}) + {SESSION_BUS_DIR: $dir})
        | .hooks = ((.hooks // {}) + {SessionStart:
            (((.hooks.SessionStart // []) | map(select(
                 [.hooks[]?.command] | index($hook) | not)))
             + [{hooks: [{type: "command", command: $hook}]}])})' 2>/dev/null)"; then
    bad "${MANAGED_SETTINGS} is not readable as JSON, so the session-start join was NOT registered. Sessions will not auto-join. Fix the file by hand."
  else
    printf '%s\n' "$merged" > "$MANAGED_SETTINGS"
    chmod 0644 "$MANAGED_SETTINGS"; chown root:root "$MANAGED_SETTINGS"
    check "${MANAGED_SETTINGS} sets SESSION_BUS_DIR to ${BUS_HOME}" \
      bash -c "[ \"\$(jq -r '.env.SESSION_BUS_DIR // empty' '$MANAGED_SETTINGS')\" = '$BUS_HOME' ]"
    check "${MANAGED_SETTINGS} runs ${BUS_JOIN_HOOK} on SessionStart, once" \
      bash -c "[ \"\$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command == \"$BUS_JOIN_HOOK\")] | length' '$MANAGED_SETTINGS')\" = '1' ]"
    check "${MANAGED_SETTINGS} is 0644 root:root -- a member who could edit it could redirect every session's bus" \
      bash -c "[ \"\$(stat -c '%a %U:%G' '$MANAGED_SETTINGS')\" = '644 root:root' ]"
  fi

  # ---- the member's own copy of what this is ----
  if [ -r "${TEMPLATE_DIR}/session-bus.md" ]; then
    install -m 0644 -o root -g root "${TEMPLATE_DIR}/session-bus.md" "$BUS_DOC"
    ok "member-facing bus reference installed at ${BUS_DOC}"
  else
    bad "no ../templates/session-bus.md, so members have nothing that says what the bus is or what is public on it"
  fi

  # ---- does a member actually join? ----
  #
  # THE ONLY CHECK THAT ANSWERS THE QUESTION THE PHASE EXISTS FOR. Every check
  # above measures a file. This one runs the join as an unprivileged member,
  # against the real bus, exactly as the harness will.
  local member="${PEOPLE[0]:-}"
  if [ -z "$member" ]; then
    warn "join NOT PROVEN: this claw carries nobody to run it as"
    return 0
  fi
  # The session id the probe claims, and the handle the hook will derive from
  # it: the first eight characters, qualified with the member's unix name.
  local probe_sid="provisionprobe$$" probe_handle
  probe_handle="${member}-${probe_sid:0:8}"
  local out=""
  out="$(printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "$probe_sid" \
        | sudo -u "$member" -H env SESSION_BUS_DIR="$BUS_HOME" "$BUS_JOIN_HOOK" 2>&1)" || true
  case "$out" in
    *"joined the claw bus as '${probe_handle}'"*)
      ok "${member} joined the bus through the installed hook, as ${probe_handle}" ;;
    *)
      bad "${member} did NOT join through the installed hook. It said: ${out:-nothing}" ;;
  esac

  # The probe handle is this run's and comes off the board by name.
  #
  # NOT `bus gc --days 0`, WHICH WOULD TAKE EVERY MEMBER'S LIVE HANDLE WITH IT:
  # idle is always at least zero, so a zero threshold matches every fully-read
  # handle on the claw, including the sessions of people who are working right
  # now. Named removal, or none.
  local board="${BUS_HOME}/handles.json"
  if [ -s "$board" ] && jq -e --arg h "$probe_handle" 'has($h)' "$board" >/dev/null 2>&1; then
    local pruned
    if pruned="$(jq --arg h "$probe_handle" 'del(.[$h])' "$board")"; then
      printf '%s\n' "$pruned" > "$board"
      chgrp "$MEMBERS_GROUP" "$board" 2>/dev/null || true
      chmod 0660 "$board" 2>/dev/null || true
    fi
  fi
  rm -f "${BUS_HOME}/inbox/${probe_handle}.jsonl" \
        "${BUS_HOME}/cursors/${probe_handle}.cursor" 2>/dev/null || true
  check "the provisioning probe left no handle on the board" \
    bash -c "! jq -e --arg h '$probe_handle' 'has(\$h)' '$board' >/dev/null 2>&1"
}

# ---------------------------------------------------------------- main

# Installed HERE rather than beside `on_exit`, and the placement is deliberate.
# Argument parsing and `--help` run above the array declarations, so a trap armed
# any earlier would read `CHK_DESC` before it exists and turn a usage message into
# an unbound-variable abort. From this line down every exit path has a result.
#
# Preflight is inside the trap on purpose: an unattended caller needs a machine
# readable reason for a refusal just as much as for a mid-run death. This does
# change what a rejected run writes to stdout, from nothing to a JSON result with
# ok false, and that is a deliberate interface change rather than a side effect.
trap on_exit EXIT

phase_1_preflight

# ABOVE THE PHASE GATE ON PURPOSE. Phase 2 asserts this claw's identity and phase
# 11 composes the backup repository out of it, so a guard living inside phase 2
# would leave `--only 11` free to repoint the destination with nothing checking.
# A guard a single argument can step around is not a guard.
identity_guard

if want_phase 2;  then phase_2_box_identity; fi
if want_phase 3;  then phase_3_packages;     fi
if want_phase 4;  then phase_4_auto_upgrades;fi
if want_phase 5;  then phase_5_ssh;          fi
if want_phase 6;  then phase_6_firewall;     fi
if want_phase 7;  then phase_7_roots;        fi
if want_phase 8;  then phase_8_users;        fi
if want_phase 9;  then phase_9_codex;        fi
if want_phase 10; then phase_10_claude;      fi
if want_phase 11; then phase_11_backup;      fi
if want_phase 12; then phase_12_seat_check;  fi
if want_phase 13; then phase_13_admin_door;  fi
if want_phase 14; then phase_14_skill_plane; fi
if want_phase 15; then phase_15_release_rail; fi
if want_phase 16; then phase_16_session_bus;  fi

# ---------------------------------------------------------------- the record
#
# THE ENTRY IS PART OF THE RUN, not a courtesy after it. claw-conventions.md has
# always said a ride with no entry is invisible to everybody except the person
# who did it, and until now nothing enforced that.
#
# WRITTEN ONLY WHEN THE RUN PASSED, which is a deliberate boundary. The changelog
# is the claw's account of what it was GIVEN. A failed run gave it something
# partial, and an entry claiming a release landed would be the one lie in the
# file. The honest record of a failure is the JSON result, which now exists on
# every exit path because of the trap above, so keeping the changelog to runs
# that finished loses nothing.
head1 "-" "the changelog entry"
if [ "$DRY_RUN" -eq 1 ]; then
  say "  would append a changelog entry for ${REVISION} (${RELEASE_CLASS})"
elif [ "$FAILED" -ne 0 ]; then
  warn "run did not pass, so no changelog entry was written -- the result JSON is the record of what happened"
elif [ ! -x "${SCRIPT_DIR}/commonclaw-changelog.sh" ]; then
  bad "cannot write the changelog entry: ${SCRIPT_DIR}/commonclaw-changelog.sh is missing or not executable"
elif "${SCRIPT_DIR}/commonclaw-changelog.sh" \
       --revision "$REVISION" --class "$RELEASE_CLASS" --notes "$RELEASE_NOTES" >&2; then
  ok "changelog entry written for ${REVISION}, class ${RELEASE_CLASS}"
else
  bad "the changelog entry FAILED to write -- this run changed the claw and left no record a member can read"
fi

finish
