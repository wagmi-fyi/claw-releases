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
#                          IGNORED on a claw that carries an authority registry:
#                          there the roster is the registry's, and it moves only
#                          by somebody signing for the change.
#   --owner <user>         the one person who holds authority over this claw.
#                          BUILD INPUT, SEEDED ONCE. It lays the authority
#                          registry from that person's own login keys and is
#                          never re-asserted: after the first run the owner moves
#                          only by the current owner signing a transfer, so a
#                          later run naming a different person is refused rather
#                          than obeyed. Without it the claw carries no registry
#                          and no tenant door can be approved.
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
#   --wide-mode <on|off>   whether every member of this claw holds passwordless
#                          root. THE BOX'S OWN CONFIG CARRIES IT: passing this
#                          sets it, and a run that does not pass it keeps what
#                          the claw already records. Absent from both is off,
#                          which is the shipped default. A release ride passes
#                          nothing, so it can never flip this switch either way.
#   --delegate-model <m>   which model a spawned orchestration delegate runs on
#                          this claw. Seeded into /etc/orchestrate.conf on the
#                          run that creates it and adopted afterwards, so a firm
#                          that changed it keeps its choice.
#   --delegate-skip-permissions <true|false>
#                          whether a spawned delegate runs with permission
#                          prompts bypassed. Same seeding rule. It is a security
#                          bypass, so it is stated in the conf rather than
#                          inherited from whatever a session last saved.
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
# granted prefix, and grants the four it names; phase 21 installs
# commonclaw-memory-check.sh from beside this file and its unit and timer from
# ../templates; phase 22 installs commonclaw-notify.sh; phase 23 installs
# commonclaw-stall-check.sh with its conf and two units from ../templates; and
# phase 24 runs install-bus-nudge.sh, which reads ../payload and ../templates
# for itself. Copy the whole skill directory to the claw. A missing sibling
# fails the run rather than being skipped.
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
#                    groupadd -f for the members group and for the credential
#                    group. The CLAW-WIDE briefing is
#                    seeded only into an absence; where it exists its bytes are
#                    never touched and only its group and mode converge.
#   8  users         useradd guarded; each key line, each home symlink, and each
#                    pointer line guarded, never doubled. gpasswd -a is a
#                    no-op on a person already in a group. The credential loader
#                    is rewritten only when its bytes differ. NO CREDENTIAL
#                    VALUE: the claw's agents token is a file a door writes, and
#                    this phase reads its mode and never its contents. The git
#                    identity is written into an absence, so a chosen address
#                    survives every re-run.
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
#   16 session bus  the state root is converged to 0755 and the run SAYS which
#                    it did: adopted a matching mode, or moved a divergent one
#                    and named the old value. That directory is the traverse a
#                    member needs for both the bus and the claw's agents token,
#                    so the phase reads it back as the member rather than
#                    inferring it. The bus home and the programs are overwritten;
#                    handles on the board are not.
#   17 runtimes      the roots, the PATH drop-in and the member doc are written
#                    to an end state. The convergence installs only what a
#                    manifest declares, only what the member-plane log already
#                    records a URL and a hash for, and only what is not already
#                    on disk, so the ordinary run fetches nothing. It never
#                    removes a runtime a declaration has dropped: that is a
#                    decision and it has its own door.
#   19 wide mode     the drop-in is DERIVED from the recorded setting and
#                    converges in both directions: on lays one fixed path, off
#                    removes it. A hand-placed file carrying the same grant is
#                    adopted and its bytes are not touched; one carrying a
#                    different grant is converged and the old grant is named.
#   20 memory floor  the swapfile is made ONCE and adopted forever after: active
#                    swap is taken as it stands whatever its size, because
#                    resizing means swapoff and that is the one act that could
#                    finish off a box already under pressure. The fstab line is
#                    guarded on the path, never doubled. The swappiness drop-in
#                    and the OOM guard's enablement are end states.
#   21 memory rail   the script, the conf, the env file, the unit and the timer
#                    are written to an end state. The conf and the env file carry
#                    a threshold and a reference, which are the release's
#                    decision rather than the claw's accumulated state, so a
#                    re-run rewrites them. NO CREDENTIAL VALUE: the heartbeat URL
#                    is a reference resolved at invocation.
#   22 notify rail   the notifier, the conf and the env file are written to an
#                    end state, and a copy already on the claw is ADOPTED when
#                    its bytes match and REPLACED with the old digest named when
#                    they differ. NO CREDENTIAL VALUE: the webhook is a
#                    reference resolved at invocation.
#   23 stall check    the script, its conf and its two units take the same
#                    adoption rule. The timer is installed ENABLED, because the
#                    beat reads files already on the box.
#   24 wake rail      install-bus-nudge.sh owns the act and is called, not
#                    reimplemented; it adopts a conf and an instance somebody
#                    disabled. The orchestration config is written line by line:
#                    the bus path and the substrate are facts and are asserted,
#                    the model and the permissions flag are decisions and are
#                    kept as the claw records them.
#   18 authority     the registry is STATE and is seeded once, never rewritten:
#                    it is the firm's own record of who may approve an act here,
#                    and it moves only by somebody signing for the change. The
#                    tenant door plane under /opt is DERIVED and is rebuilt from
#                    that registry every ride, because /etc is inside the backed
#                    up roots and /opt is not. A `--owner` naming somebody other
#                    than the recorded owner fails the run rather than being
#                    ignored.
# No phase deletes user data. No phase depends on being the first run.
#
set -euo pipefail

# ---------------------------------------------------------------- parameters

PROJECT=""; TARGET_HOSTNAME=""; TIMEZONE=""; KEYS_FILE=""
VAULT=""                         # defaults to {hostname}-machine once arguments are parsed
B2_BUCKET="wagmi-fleet-backups"  # default; confirm it exists before the first run
S3_ENDPOINT="s3.us-east-005.backblazeb2.com"
CLAW_ADMINS_ARG=""
OWNER_ARG=""
SKILLS_MANIFEST=""; SKILLS_ROOT=""
ONLY=""; DRY_RUN=0

# Wide mode as the CALLER asked for it, which is not the same thing as the
# setting. Empty means the caller said nothing, and `wide_mode_resolve` below
# turns that into whatever the claw already records.
WIDE_MODE_ARG=""
WIDE_MODE=""

# The changelog entry's three fields. Required, because a run that can finish
# without an entry is a run whose record depends on somebody remembering, and
# that dependency has failed three times in one week.
RELEASE_NOTES=""; RELEASE_CLASS=""; REVISION=""
RELEASE_REPO=""; RELEASE_CHANNEL="tenants"

# The orchestration settings, seeded into /etc/orchestrate.conf. Defaults are
# what the hub runs today, so a claw that says nothing gets the arrangement that
# has been ridden rather than whatever a session last saved for itself.
#
# THESE TWO ARE DECISIONS, and the phase treats them as such: it seeds them once
# and adopts whatever the claw carries afterwards. The other two values in that
# file are facts about the machine and the phase asserts them on every run.
DELEGATE_MODEL="opus"
DELEGATE_SKIP_PERMISSIONS="true"

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

# Where a person's agents-vault token rests, what loads it into their session,
# and where that loader is hooked. Phase 8 makes that plane for every person a
# build creates; onboard-person.sh makes it for everybody who arrives later, and
# install-agents-token.sh fills it. One copy, because the verdict the three
# would drift on is whether a person's session resolves anything at all.
[ -r "${SCRIPT_DIR}/agents-plane.sh" ] || {
  printf 'missing sibling: %s/agents-plane.sh -- copy the whole skill directory\n' "$SCRIPT_DIR" >&2
  exit 1
}
# shellcheck source=agents-plane.sh
. "${SCRIPT_DIR}/agents-plane.sh"

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
    --owner)       OWNER_ARG="${2:-}"; shift 2 ;;
    --skills-manifest) SKILLS_MANIFEST="${2:-}"; shift 2 ;;
    --skills-root)     SKILLS_ROOT="${2:-}"; shift 2 ;;
    --release-repo)    RELEASE_REPO="${2:-}"; shift 2 ;;
    --release-channel) RELEASE_CHANNEL="${2:-}"; shift 2 ;;
    --release-notes)   RELEASE_NOTES="${2:-}"; shift 2 ;;
    --release-class)   RELEASE_CLASS="${2:-}"; shift 2 ;;
    --revision)        REVISION="${2:-}"; shift 2 ;;
    --delegate-model)  DELEGATE_MODEL="${2:-}"; shift 2 ;;
    --delegate-skip-permissions)
                       DELEGATE_SKIP_PERMISSIONS="${2:-}"; shift 2 ;;
    # THE COUNT IS GUARDED BEFORE THE SHIFT, and this one flag is written that
    # way deliberately. `VAR="${2:-}"; shift 2` with the flag typed last makes
    # `shift 2` return non-zero, and `set -e` ends the run with nothing printed.
    # Everywhere else that costs a usage message. Here it would end a run that
    # was about to decide whether every member of this claw holds root, with no
    # output saying why, so the newer doors' guard-then-exit-2 shape is used.
    --wide-mode)   [ $# -ge 2 ] || { printf -- '--wide-mode needs a value: on or off\n' >&2; exit 2; }
                   WIDE_MODE_ARG="$2"; shift 2 ;;
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

# The memory rail. Two files with the split the notification rail already uses:
# the conf carries the decision and the thresholds, the env file carries the one
# manager reference and never a value.
MEMORY_CONF="${ETC_ROOT}/memory.conf"
MEMORY_ENV="${ETC_ROOT}/memory.env"

# The notification rail: the delivery path every other producer on this claw
# calls. Same split. The conf declares the rail exists and carries no URL; the
# env file carries the manager reference the notifier resolves at invocation.
NOTIFY_BIN="/usr/local/sbin/commonclaw-notify.sh"
NOTIFY_CONF="${ETC_ROOT}/notify.conf"
NOTIFY_ENV="${ETC_ROOT}/notify.env"

# The stall check. One conf, and no env file: the check reads buses and posts
# through the notifier, so it resolves no credential of its own.
STALL_CHECK="/usr/local/sbin/commonclaw-stall-check.sh"
STALL_CONF="${ETC_ROOT}/stall-check.conf"

# The orchestration settings this machine rules on.
#
# THE PATH IS THE ORCHESTRATE SKILL'S, NOT THIS ONE'S. That skill reads
# $ORCHESTRATE_CONF and falls back to /etc/orchestrate.conf, and its shipped
# config.yaml is root-owned under a managed install, so the conf file is the one
# layer a machine's ruling can be written into. A path of our own choosing would
# be a file nothing reads.
ORCHESTRATE_CONF_FILE="/etc/orchestrate.conf"

# The memory floor. Swap and the swappiness drop-in, and the two paths are
# OVERRIDABLE for exactly one reason: the swap phase cannot be rehearsed against
# the real fstab or the real swapfile without changing the box, so its controls
# point these at fixtures. Nothing else sets them, and a run on a claw takes the
# defaults. Same seam, same reason, as the notifier's NOTIFY_CONF.
SWAPFILE="${SWAPFILE:-/swapfile}"
FSTAB="${FSTAB:-/etc/fstab}"
SYSCTL_SWAP="${SYSCTL_SWAP:-/etc/sysctl.d/60-commonclaw-swap.conf}"
# How the phase asks the kernel what swap is on. Overridable for the same reason
# the paths above are: the adoption branch turns on this reading, and a control
# that could not plant an answer would leave that branch untested.
SWAPON_CMD="${SWAPON_CMD:-swapon}"

# A modest value, not zero. Zero tells the kernel never to swap a page it could
# keep, which turns the cushion back into the thing it was added to replace. Ten
# keeps cold pages of a long-idle session out of the way and leaves the working
# set in memory.
SWAPPINESS=10

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
GRANTED_AGENTS_TOKEN="${INSTALL_PREFIX}/scripts/install-agents-token.sh"
GRANTED_MODE="${INSTALL_PREFIX}/scripts/set-update-mode.sh"
GRANTED_DESTROY="${INSTALL_PREFIX}/scripts/destroy-workspace.sh"
GRANTED_ACCESS="${INSTALL_PREFIX}/scripts/manage-workspace-access.sh"
GRANTED_PERSON_KEYS="${INSTALL_PREFIX}/scripts/manage-person-keys.sh"
GRANTED_RUNTIMES="${INSTALL_PREFIX}/scripts/manage-runtimes.sh"
GRANTED_AUTHORITY="${INSTALL_PREFIX}/scripts/manage-claw-authority.sh"

# ONE list, four uses: what preflight requires beside this script, what the
# sudoers alias names, what the scope control requires the member's listing to
# hold, and nothing else. Adding an operation to the member plane is adding its
# script here; the control then fails until the alias and this list agree.
GRANTED_SCRIPTS=("$GRANTED_SCAFFOLD" "$GRANTED_RETIRE" "$GRANTED_ONBOARD" "$GRANTED_TOKEN" \
                 "$GRANTED_AGENTS_TOKEN" "$GRANTED_MODE" "$GRANTED_DESTROY" \
                 "$GRANTED_ACCESS" "$GRANTED_PERSON_KEYS" "$GRANTED_RUNTIMES" \
                 "$GRANTED_AUTHORITY")

# The adjacent script the grant does NOT name. It is installed deliberately: a
# refusal only proves scope when the refused path exists, is root-owned, and
# sits in the same directory as the granted one. Refusing a path that is not
# there refuses for the wrong reason and would pass a per-directory grant.
DECOY_SCRIPT="${INSTALL_PREFIX}/scripts/provision-claw.sh"

CLAW_ADMIN_GROUP="claw-admin"

# WHERE EVERY GRANT ON THIS CLAW IS WRITTEN. Three files live here and each has
# its own writer: the admin door's, the tenant doors', and wide mode's. Naming
# the directory once is what lets an instrument drive any of them against a
# scratch root without a shim in the code being measured.
SUDOERS_DIR="/etc/sudoers.d"
# The file that decides whether anything in that directory is read at all. A
# drop-in in a directory sudoers does not include is a grant that is written and
# inert, and the two are indistinguishable from the file itself, so every phase
# that lays a drop-in reads this rather than assuming it.
SUDOERS_MAIN="/etc/sudoers"
SUDOERS_DROPIN="${SUDOERS_DIR}/commonclaw-claw-admin"

# The authority registry: who may approve an act on this claw, and what they
# have approved. Root-owned, world-readable, and edited only by the signed
# operations `manage-claw-authority.sh` carries.
#
# IT LIVES UNDER /etc/commonclaw BECAUSE THE BACKUP RAIL KEEPS THAT ROOT. A
# restored claw comes back knowing who its owner is. The running copy of an
# approved door lives under /opt, which the rail does not keep, so phase 18
# rebuilds that side from this one.
#
# SEEDED ONCE INTO AN ABSENCE, the law the updater's mode file and the seat
# roster follow, and here it is load-bearing rather than tidy: a run that
# re-asserted the roster would be the vendor overruling a firm's own signed
# decision on the firm's own machine.
AUTHORITY_ROOT="${ETC_ROOT}/authority"
AUTHORITY_OWNER="${AUTHORITY_ROOT}/owner"
AUTHORITY_ADMINS="${AUTHORITY_ROOT}/admins"
AUTHORITY_DOORS="${AUTHORITY_ROOT}/doors"

# Where an approved door runs from, and the drop-in that grants it.
#
# A SECOND DROP-IN, NEVER A SHARED ONE. This script rewrites
# `commonclaw-claw-admin` on every ride, so a tenant's grant written into that
# file would be erased by the next release with nothing telling the firm. Two
# files, two writers, and the tenant's is derived from the registry.
TENANT_DOOR_ROOT="${OPT_ROOT}/tenant-doors"
TENANT_SUDOERS="${SUDOERS_DIR}/commonclaw-tenant-doors"

# WHICH WRAPPER, PINNED, and it is the same number `manage-claw-authority.sh`
# carries. Both programs lay this one file into the door root, and each has to be
# able to refuse alone: a ride that took the tenant-door wrapper from a tampered
# templates directory would replace every granted door on the claw with bytes
# nobody shipped, and the control that was supposed to catch it compared the
# installed copy against the very file it had been copied from.
#
# A wrapper edited without this number edited too goes red in the rig that holds
# the two together, which is the only place that failure is cheap.
WRAPPER_SHA256="95a492ed7f583208f3f8c048865a8ce5cfe30db504a91711a37649759d3a6aa4"

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
# WHAT IT CARRIES DEPENDS ON WIDE MODE, and on nothing else. With wide mode off
# it carries no privilege at all: no sudoers file names it and it owns exactly
# one path, which phase 8 proves rather than states. With wide mode on, phase 19
# writes the ONE file that names it, and phase 8 still refuses every other one.
# A group that owns one file carries what that file carries.
MEMBERS_GROUP="claw-members"

# WIDE MODE'S DROP-IN. One fixed name, so turning the switch on and off is
# idempotent in both directions: the phase either lays this path or removes it,
# and it can never leave two grants behind under two spellings.
#
# A SEPARATE FILE FROM THE OTHER TWO. The admin drop-in grants named scripts to
# a role most members never hold, and the tenant one is derived from signed
# approvals. This grants everything to everybody. Three different authorities,
# three files, so removing one can never disturb another.
WIDE_SUDOERS="${SUDOERS_DIR}/commonclaw-wide-mode"

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

# The shared language runtimes, and the farm of links that puts them on a
# member's PATH.
#
# ONE COPY PER CLAW, at machine level, because every no-root answer duplicates
# on some axis: a copy per workspace, or a copy per person. Two workspaces on
# this claw already need the same Node major and they do not conflict, so the
# duplication buys no isolation and costs the disk twice.
#
# A WORKSPACE DECLARES THE NEED AND THE PLATFORM OWNS THE COPY. The manifest's
# `runtimes` field is the declaration; phase 17 converges the machine to the
# union of them. What it may install is bounded by the member-plane log, which
# holds the URL and the hash of every runtime this claw was ever given, so a
# declaration can never pull something down from nowhere.
#
# NOT INSIDE THE BACKED-UP ROOTS, deliberately. The rail captures /srv, /home
# and /etc/commonclaw; these trees are vendor bytes that reproduce from the pins
# in the log, and the log IS in /etc/commonclaw. A restored claw carries the
# pins and not the binaries, and the convergence phase rebuilds the second from
# the first.
RUNTIMES_ROOT="${OPT_ROOT}/runtimes"
RUNTIMES_FARM="${RUNTIMES_ROOT}/bin"
RUNTIMES_PROFILE="/etc/profile.d/commonclaw-runtimes.sh"
RUNTIMES_DOC="${ETC_ROOT}/runtimes.md"

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

# THE GIT IDENTITY, and it is the other half of a contract with
# scripts/onboard-person.sh. Every workspace here is a git repository the group
# shares, so a person with no identity either cannot commit or commits as a
# guess. Git history is the one record on this claw the conventions forbid
# rewriting, which is why the identity is made with the person rather than left
# for them to notice.
#
# THE DEFAULT IS DERIVED AND IT IS TRUE: person@hostname says which person, on
# which claw. It reaches no mailbox and nothing here pretends it does. A keys
# file carries no address and neither does a group, so the derived value is all
# this side can write; the granted door takes --email and writes what somebody
# chose. BOTH SIDES WRITE ONLY INTO AN ABSENCE, which is what stops a re-run
# from replacing a chosen address with the derived one.
#
# useConfigOnly goes with them: without it git invents an identity from the
# hostname when none is configured, so an emptied config produces commits under a
# name nobody chose. With it, git refuses. A refusal can be fixed and a commit
# cannot.
GIT_IDENTITY_KEYS=("user.name" "user.email" "user.useConfigOnly")
GIT_PROBE_KEY="commonclaw.identityprobe"

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
  "sudo:visudo"              "earlyoom:earlyoom"
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

# install_adopting <source> <target> <what> — the Q62 doctrine in one place.
#
# A payload file already on a claw was put there by somebody, usually the unit
# that first needed it before provisioning owned it. Three outcomes, and the run
# SAYS WHICH:
#
#   absent            installed. An ordinary first placement.
#   digest matches    adopted. Nothing is written, because there is nothing to
#                     change, and a silent rewrite would report work that was
#                     not done.
#   digest differs    replaced, and the old digest is named. The release owns
#                     this file, so a divergent copy is the older hand-placed
#                     one and carrying it forward would pin a claw to whatever
#                     somebody once dropped there.
#
# A DIVERGENT COPY IS NAMED RATHER THAN OVERWRITTEN QUIETLY, because the copy on
# the box may be newer than the release on a claw somebody debugged by hand, and
# the only way anybody learns that is a line in the run's own output.
install_adopting() {
  local src="$1" dst="$2" what="$3" mode="${4:-0755}" prev=""
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would install ${what} to ${dst}, adopting a matching copy"
    return 0
  fi
  if [ -f "$dst" ]; then
    prev="$(sha256sum "$dst" | cut -d' ' -f1)"
    if cmp -s "$src" "$dst"; then
      ok "${what} at ${dst} already matches this release and was adopted, not rewritten (sha256 ${prev:0:16})"
      chmod "$mode" "$dst"; chown root:root "$dst"
      return 0
    fi
  fi
  install -m "$mode" -o root -g root "$src" "$dst"
  if [ -n "$prev" ]; then
    warn "${what} at ${dst} differed from this release and was REPLACED. The copy this run found was sha256 ${prev:0:16}; if it was newer than the release, it is gone."
  else
    ok "${what} installed at ${dst}"
  fi
}

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

# Membership, by value, against the rest of the arguments. Written as a
# predicate because the alternative is the same four-line loop written out at
# every place that asks the question, and one of those copies eventually forgets
# to break.
in_list() { local want="$1" x; shift; for x in "$@"; do [ "$x" = "$want" ] && return 0; done; return 1; }

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

# ---------------------------------------------------------------- wide mode

# WHETHER EVERY MEMBER OF THIS CLAW HOLDS PASSWORDLESS ROOT.
#
# Wide mode is a decision about the machine, so it is recorded on the machine.
# The resolution has three inputs and one order:
#
#   the flag        a caller who passes --wide-mode sets it, and that is the
#                   only way it moves.
#   the config      a caller who passes nothing keeps what the claw records.
#   absent          off. A claw that has never been told is a claw with the
#                   shipped default, and the shipped default is off.
#
# THE CARRY-FORWARD IS THE LOAD-BEARING HALF. A release ride re-runs this script
# with the arguments the updater composes out of provision.conf, and that set
# does not include this flag. Without the carry-forward the first release to
# reach a wide-open claw would silently take root away from every member on it,
# and the run would report itself green while doing so. With it, a ride cannot
# move this switch in either direction: only an operator naming it can.
#
# A VALUE NEITHER on NOR off ENDS THE RUN. Guessing is not available here. Read
# as off it takes root away from a box that meant to have it; read as on it
# hands root to everybody on a box that did not. Both are silent, and both are
# the reassuring answer. So a typo in the file or on the command line stops the
# run before any phase, and names where the bad value came from.
wide_mode_resolve() {
  head1 "0" "wide mode"

  local recorded; recorded="$(conf_value WIDE_MODE)"

  if [ -n "$WIDE_MODE_ARG" ]; then
    case "$WIDE_MODE_ARG" in
      on|off) WIDE_MODE="$WIDE_MODE_ARG" ;;
      *) say "--wide-mode must be on or off (got '${WIDE_MODE_ARG}')"; exit 2 ;;
    esac
    if [ -z "$recorded" ]; then
      say "  wide mode set to ${WIDE_MODE} by this run; this claw recorded nothing before it"
    elif [ "$recorded" = "$WIDE_MODE" ]; then
      say "  wide mode set to ${WIDE_MODE} by this run, which is what this claw already recorded"
    else
      warn "wide mode MOVED from ${recorded} to ${WIDE_MODE} by this run's --wide-mode. Turning it on gives every member of ${MEMBERS_GROUP} passwordless root here; turning it off takes it from all of them."
    fi
    return 0
  fi

  case "$recorded" in
    on|off) WIDE_MODE="$recorded"
            say "  wide mode is ${WIDE_MODE}, carried forward from ${CONF}; this run passed no --wide-mode" ;;
    "")     WIDE_MODE="off"
            say "  wide mode is off: ${CONF} records none, and absent is off" ;;
    *)      say "${CONF} records WIDE_MODE='${recorded}', which is neither on nor off."
            say "REFUSED before anything was changed. No phase has run."
            say "Fix that line by hand, or pass --wide-mode explicitly."
            exit 2 ;;
  esac
}

# The effective grant a sudoers file carries: whole-line comments and blank
# lines dropped, runs of whitespace collapsed to one space.
#
# WHY NOT A BYTE COMPARISON. Adoption has to answer "does this file already
# grant what wide mode grants", and a hand-placed drop-in is one line somebody
# typed, never this script's comment block. Compared byte for byte every
# hand-placed file diverges, so every claw that was opened by hand would be
# rewritten and reported as converged, and the adoption branch would be
# unreachable. The grant is what the file DOES, so the grant is what is compared.
#
# A trailing `#` is not treated as a comment start. sudoers reads `#1000` as a
# uid, so stripping from the first `#` on a line would mangle a grant rather
# than normalize it.
# Every line of a sudoers file that says something, one statement per line.
#
# CONTINUATIONS ARE JOINED FIRST. sudoers wraps a long statement with a trailing
# backslash, and a line-at-a-time reading takes the first fragment for the whole
# statement and reads each remaining fragment as a statement of its own. That
# turns one correct alias into a handful of grants nobody wrote. Joining here
# rather than in each caller is what keeps the three readings that use this
# agreeing about what a line is.
sudoers_grant_lines() {
  sed -e :a -e '/\\$/{N;s/\\\n//;ba' -e '}' "$1" 2>/dev/null \
    | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' \
    | grep -v '^#' | grep -v '^$' || true
}

# The command list the claw-admin door grants, read out of the file that grants
# it.
#
# WHY THE FILE AND NOT `sudo -l`. A listing answers what a caller may run
# through every sudoers file on the claw at once. On a wide-mode claw the
# honest answer is "everything", and it says nothing about whether THIS door is
# scoped. So a claim about the door's scope is measured where the scope is
# written. Driven on wagmi on 2026-09-02, where three controls that read the
# listing went red and each was reporting the truth about the box.
#
# It reads through sudoers_grant_lines, so a wrapped alias arrives whole and a
# door file missing most of its commands cannot pass as a correct one.
door_file_commands() {
  local f="$1"
  [ -r "$f" ] || return 1
  sudoers_grant_lines "$f" \
    | sed -n 's/^Cmnd_Alias COMMONCLAW_ADMIN_OPS = //p' \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' \
    | LC_ALL=C sort -u
}

# Every line in a sudoers file that grants somebody something, with the alias
# definitions taken out. The door declares exactly one, so a second one is a
# grant nobody wrote down. Without this an alias naming eleven scripts could sit
# in a file that also opened everything on the next line.
door_file_rules() {
  sudoers_grant_lines "$1" | grep -v '^Cmnd_Alias ' | grep -v '^Defaults'
}

# Which sudoers files grant this caller a blanket command of ALL.
#
# SUDO CANNOT BE ASKED THIS. `sudo -l` says the caller holds a blanket entry and
# never which file wrote it, so a wide-mode claw cannot tell its own declared
# grant from one somebody left behind. Reading the files answers it, and that
# answer is what wide mode has to be held to: one file, the one phase 19 owns.
#
# A grant reaches this caller when its principal is the account, one of its
# groups, or ALL. The command is matched by SHAPE rather than by a list of
# spellings, for the reason the listing check already gives: sudo writes the
# runas specification several ways, and enumerating them means the reading
# silently stops covering whichever form nobody thought of.
blanket_grant_files() {
  local who="$1" gtext f line princ cmds
  gtext=" $(id -nG "$who" 2>/dev/null || true) "
  for f in "$SUDOERS_MAIN" "$SUDOERS_DIR"/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    while IFS= read -r line; do
      case "$line" in
        Cmnd_Alias\ *|User_Alias\ *|Runas_Alias\ *|Host_Alias\ *|Defaults*|'#include'*|'@include'*) continue ;;
      esac
      case "$line" in *=*) : ;; *) continue ;; esac
      princ="${line%% *}"
      cmds="${line#*=}"          # (root) NOPASSWD: COMMONCLAW_ADMIN_OPS
      cmds="${cmds#*)}"          # past the runas specification, where there is one
      cmds="${cmds##*:}"         # past the tag, where there is one
      cmds="${cmds# }"
      [ "$cmds" = "ALL" ] || continue
      case "$princ" in
        ALL) : ;;
        %*)  case "$gtext" in *" ${princ#%} "*) : ;; *) continue ;; esac ;;
        *)   [ "$princ" = "$who" ] || continue ;;
      esac
      printf '%s\n' "$f"
      break
    done < <(sudoers_grant_lines "$f")
  done | LC_ALL=C sort -u
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
           core-version.sh commonclaw-update.sh agents-plane.sh \
           commonclaw-memory-check.sh commonclaw-notify.sh \
           commonclaw-stall-check.sh install-bus-nudge.sh \
           check-git-conventions.sh install-heartbeat-url.sh unit-health.sh; do
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
  # The runtimes phase's two files. Named here rather than only in phase 17
  # because one of them is what puts the shared runtimes on every member's PATH:
  # a run that reached the phase without it would install the trees, converge
  # them, report a clean phase, and leave nobody able to type `node`.
  [ -r "${TEMPLATE_DIR}/runtimes-profile.sh" ] \
    || missing_payload="$missing_payload ../templates/runtimes-profile.sh"
  [ -r "${TEMPLATE_DIR}/runtimes.md" ] \
    || missing_payload="$missing_payload ../templates/runtimes.md"
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
  # The authority plane's three pieces, and the first of them is the one that
  # fails quietly. The wrapper is what a tenant door's sudo grant names, so a
  # claw missing it would take an approval, write the registry row, install the
  # grant, and grant a path with nothing behind it. Named here rather than only
  # in the door, because the door is granted on a claw this run built.
  [ -r "${TEMPLATE_DIR}/tenant-door-wrapper.sh" ] \
    || missing_payload="$missing_payload ../templates/tenant-door-wrapper.sh"
  [ -r "${PAYLOAD_DIR}/claw-authority" ] \
    || missing_payload="$missing_payload ../payload/claw-authority"
  [ -r "${TEMPLATE_DIR}/claw-authority.md" ] \
    || missing_payload="$missing_payload ../templates/claw-authority.md"
  # The memory rail's unit and timer. Named here rather than only in phase 21
  # because the phase installs the script either way: a run that reached it with
  # the timer template missing would leave a check on the claw that nothing ever
  # starts, and every check in that phase would still pass.
  [ -r "${TEMPLATE_DIR}/commonclaw-memory-check.service" ] \
    || missing_payload="$missing_payload ../templates/commonclaw-memory-check.service"
  [ -r "${TEMPLATE_DIR}/commonclaw-memory-check.timer" ] \
    || missing_payload="$missing_payload ../templates/commonclaw-memory-check.timer"
  # The stall check's three files, named here for the memory rail's own reason:
  # the phase installs the script either way, and a claw that reached it with the
  # timer template missing would carry a check nothing ever starts while every
  # check in that phase still passed.
  [ -r "${TEMPLATE_DIR}/commonclaw-stall-check.service" ] \
    || missing_payload="$missing_payload ../templates/commonclaw-stall-check.service"
  [ -r "${TEMPLATE_DIR}/commonclaw-stall-check.timer" ] \
    || missing_payload="$missing_payload ../templates/commonclaw-stall-check.timer"
  [ -r "${TEMPLATE_DIR}/commonclaw-stall-check.conf" ] \
    || missing_payload="$missing_payload ../templates/commonclaw-stall-check.conf"
  # The wake rail's own siblings. `install-bus-nudge.sh` is named in the script
  # list above; these are what it reads, and it is called from a phase here, so a
  # missing one turns a phase into a refusal rather than a silent skip.
  [ -r "${PAYLOAD_DIR}/bus-nudge" ] \
    || missing_payload="$missing_payload ../payload/bus-nudge"
  [ -d "${PAYLOAD_DIR}/bus-nudge-adapters" ] \
    || missing_payload="$missing_payload ../payload/bus-nudge-adapters"
  # EACH ADAPTER BY NAME, and not just the directory. A present-but-short
  # directory passes the reading above while the rail's detection ladder walks
  # past the substrate this machine actually runs and reports a wall. The names
  # are the ladder's, in the ladder's order, and a cut that lost one refuses
  # here rather than on somebody's claw.
  for s in claude tmux codex; do
    [ -r "${PAYLOAD_DIR}/bus-nudge-adapters/${s}" ] \
      || missing_payload="$missing_payload ../payload/bus-nudge-adapters/${s}"
  done
  [ -r "${TEMPLATE_DIR}/bus-nudge.conf" ] \
    || missing_payload="$missing_payload ../templates/bus-nudge.conf"
  [ -r "${TEMPLATE_DIR}/bus-nudge@.service" ] \
    || missing_payload="$missing_payload ../templates/bus-nudge@.service"
  [ -r "${TEMPLATE_DIR}/bus-nudge@.timer" ] \
    || missing_payload="$missing_payload ../templates/bus-nudge@.timer"
  [ -r "${TEMPLATE_DIR}/wake-rail.md" ] \
    || missing_payload="$missing_payload ../templates/wake-rail.md"
  # The operator's runbook, which the same installer lays beside the member's
  # doc. It rides in the payload rather than in templates because nothing
  # renders it, and it is named here for the reason every other doc is: the
  # installer would otherwise refuse mid-phase on a stage that lost it.
  [ -r "${PAYLOAD_DIR}/doc/operator-runbook.md" ] \
    || missing_payload="$missing_payload ../payload/doc/operator-runbook.md"
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
# WIDE_MODE  on|off. On gives every member of ${MEMBERS_GROUP} passwordless root
#            here; it is for the current early set of claws only, it must be off
#            before this plane reaches any box beyond them, and the shipped
#            default is off. A run that passes no --wide-mode keeps this value,
#            so a release ride cannot move it.
WIDE_MODE=${WIDE_MODE}
CONFEOF
    chmod 0644 "$CONF"
  fi

  # Read the value back out of the file and compare it to the parameter. The
  # bucket is the one that earns this: backup.env carries no repository path, so
  # this config is the only place the destination is written down, and nobody
  # checking backup.env for it will ever find it.
  check "config records B2_BUCKET as ${B2_BUCKET}" conf_says B2_BUCKET "$B2_BUCKET"

  # THE SAME READ-BACK ON THE SWITCH, and it earns it for the same reason the
  # bucket does. This file is the only place wide mode is written down, and it is
  # what the NEXT run reads to decide whether every member keeps root. A value
  # that failed to land here reads as a claw that was never told, which is the
  # quiet answer and the wrong one.
  check "config records WIDE_MODE as ${WIDE_MODE}" conf_says WIDE_MODE "$WIDE_MODE"

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
    say "  would create group ${CC_AGENTS_GROUP}, the read boundary on ${CC_AGENTS_TOKEN}"
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

  # THE CREDENTIAL GROUP, made here and never merged into the one above.
  #
  # Two groups because they mean two things. The members group owns the claw's
  # briefing: everybody here is in it, and it grants nothing. This one is the
  # read boundary on the claw's agents token, and being in it is the whole
  # difference between a session that resolves op:// references and one that
  # does not.
  #
  # Merging them would be the one change that quietly undoes this: credential
  # read would land on everybody who can read the briefing, and no reading
  # anywhere would show a difference, because everybody would still be green.
  #
  # It is created HERE, empty, for the same reason the members group is: a group
  # needs nobody, the file it guards has to belong to it before that file can
  # exist, and the people join in phase 8 and in the onboarding door.
  groupadd -f --system "$CC_AGENTS_GROUP" 2>/dev/null || groupadd -f "$CC_AGENTS_GROUP"
  check "group ${CC_AGENTS_GROUP} exists" getent group "$CC_AGENTS_GROUP"

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

# The git identity, written BY THE PERSON, through git, into an absence. Each of
# those three rules out something simpler that is wrong here:
#
#   By the person, because a file root creates in somebody's home is a file they
#   cannot write. git run under their own uid makes it with their ownership and
#   git's own mode, and this run never has to know which mode that is.
#
#   Through git rather than by appending text, because the config format has
#   sections and an append landing under the wrong one sets nothing while looking
#   exactly like success.
#
#   Into an absence, because every later run reaches the same people. Overwriting
#   would replace an address the granted door was given with the derived one,
#   every time this claw is provisioned again.
stamp_git_identity() {
  local user="$1" k v
  for k in "${GIT_IDENTITY_KEYS[@]}"; do
    sudo -u "$user" -H git config --global --get "$k" >/dev/null 2>&1 && continue
    case "$k" in
      user.name)          v="$user" ;;
      user.email)         v="${user}@${TARGET_HOSTNAME}" ;;
      user.useConfigOnly) v="true" ;;
    esac
    # An attempt, with phase 8's own verify as the verdict. Fatal under errexit,
    # a refused write would end the run before any phase reported.
    sudo -u "$user" -H git config --global "$k" "$v" || bad "could not write git ${k} for ${user}"
  done
}

# A workspace is root-owned by construction and its gitdir belongs to a member,
# so git's ownership guard refuses the repository for every caller. Declare the
# workspace root for each PERSON, never system-wide: a member can write repo
# config, and root is the one caller that must not execute it unexamined. The
# wildcard covers workspaces that do not exist yet.
phase_8_users() {
  head1 8 "people"

  local entry user line home f cnt user_groups stat_line no_cred="" cap cap_rc k v created=0 existing=0

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
    stamp_git_identity "$user"

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

    # THE CREDENTIAL PLANE: the group grant, then the loader. Neither is a
    # secret, which is why a run makes both and why an UPDATE makes them too. A
    # plane is not identity, so the rule that an update asserts the box's own
    # identity and passes no key material is untouched here.
    #
    # THE GRANT IS ITS OWN STEP, as it is in the onboarding door. Membership of
    # this group is what makes the claw's token readable, so a person who lacks
    # it has an account and resolves nothing, and that has to be a thing a run
    # DOES rather than a thing that follows from something else.
    if getent group "$CC_AGENTS_GROUP" >/dev/null 2>&1; then
      gpasswd -a "$user" "$CC_AGENTS_GROUP" >/dev/null 2>&1 \
        || bad "could not add ${user} to ${CC_AGENTS_GROUP} -- they will resolve no credentials"
    else
      bad "group ${CC_AGENTS_GROUP} does not exist -- phase 7 creates it, and this run skipped it"
    fi

    # THE VALUE IS NOT PROVISIONING'S TO PUT ANYWHERE. It comes from the firm's
    # own manager through install-agents-token.sh, which proves the token opens
    # the agents vault and refuses one that opens the machine vault. A run that
    # carried a token would be a run that had one, and no release payload or
    # provisioning argument may ever hold a credential value.
    if cc_agents_plane_unsafe "$user" "$home" >/dev/null; then
      cc_agents_plane_install "$user" "$home" \
        || bad "could not make the loader in ${home} -- ${user} will resolve no credentials"
    else
      bad "credential loader refused for ${user}: $(cc_agents_plane_unsafe "$user" "$home")"
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

    # THE CREDENTIAL PLANE, read back. The grant is read from the claw's own
    # group record rather than from the fact that a gpasswd call ran, and the
    # loader is read for a value it must never carry.
    cc_agents_reads "$user" || { bad "$user: not in ${CC_AGENTS_GROUP}, so they can read no credential on this claw"; all_ok=0; }
    cc_agents_paths "$home"
    stat_line="$(stat -c '%a %U:%G' "$CC_AP_DIR" 2>/dev/null || echo missing)"
    [ "$stat_line" = "700 ${user}:${user}" ] \
      || { bad "$user: ${CC_AP_DIR} is ${stat_line}, wanted 700 ${user}:${user}"; all_ok=0; }
    stat_line="$(stat -c '%a %U:%G' "$CC_AP_ENV" 2>/dev/null || echo missing)"
    [ "$stat_line" = "600 ${user}:${user}" ] \
      || { bad "$user: ${CC_AP_ENV} is ${stat_line}, wanted 600 ${user}:${user}"; all_ok=0; }
    cnt="$(grep -cxF "$CC_AP_HOOK" "${home}/.bashrc" 2>/dev/null || true)"
    [ "$cnt" = "1" ] \
      || { bad "$user: .bashrc carries ${cnt} loader hooks, wanted exactly one"; all_ok=0; }
    if grep -q 'ops_' "$CC_AP_ENV" 2>/dev/null; then
      bad "$user: ${CC_AP_ENV} carries what looks like a token value -- the loader names a PATH and never a value"; all_ok=0
    fi

    # NO TOKEN IN THIS HOME. The whole point of one file per claw is that no
    # home holds the value. A home that holds one is a claw that has not
    # converged, and this reading is what makes that visible rather than
    # leaving it to sit in every snapshot the rail takes of /home.
    if [ -e "$(cc_agents_legacy_token "$home")" ]; then
      bad "$user: $(cc_agents_legacy_token "$home") is a per-home copy of the claw token. Run ${GRANTED_AGENTS_TOKEN}, which ROTATES the token and removes these in one act -- deleting them alone leaves the value in every snapshot still in retention."; all_ok=0
    fi

    # WHO RESOLVES NOTHING, named rather than counted.
    cc_agents_reads "$user" || no_cred="$no_cred $user"

    # THE GIT IDENTITY, read back THROUGH GIT AS THE PERSON. That is the surface
    # that decides what their commits carry; reading the file with grep would
    # pass on a config git cannot parse and on one sitting where git does not
    # look. The name and address are asserted NON-EMPTY rather than equal to the
    # derived value, because a person the granted door gave a chosen address
    # keeps it and this run must not report that as wrong.
    for k in user.name user.email; do
      v="$(sudo -u "$user" -H git config --global --get "$k" 2>/dev/null || true)"
      [ -n "$v" ] || { bad "$user: git reads no ${k}, so their commits carry a guess or nothing"; all_ok=0; }
    done
    v="$(sudo -u "$user" -H git config --global --get user.useConfigOnly 2>/dev/null || true)"
    [ "$v" = "true" ] || { bad "$user: user.useConfigOnly reads '${v}' -- git would invent an identity from the hostname"; all_ok=0; }

    # The known-answer control for the three reads above. A read-back that
    # returned something whatever it was asked would pass all three; this asks
    # for a key nothing sets and requires nothing back.
    v="$(sudo -u "$user" -H git config --global --get "$GIT_PROBE_KEY" 2>/dev/null || true)"
    [ -z "$v" ] || { bad "$user: known-answer control FAILED -- ${GIT_PROBE_KEY} returned '${v}' and nothing sets it"; all_ok=0; }
  done

  # ONE identity per person means NO identity above them. A name or address at
  # the system level puts every person on this claw behind one identity, and each
  # of their own configs still reads correctly when asked on its own.
  for k in user.name user.email; do
    v="$(git config --system --get "$k" 2>/dev/null || true)"
    [ -z "$v" ] || { bad "a system-wide git ${k} is set ('${v}') -- every person here would commit as it"; all_ok=0; }
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
      ok "every person: home 750, authorized_keys 600, no sudo, in ${MEMBERS_GROUP}, workspaces symlink, one conventions pointer per core, the claw-briefing pointer once in ${PER_TASK_CORE_FILE} and absent from ${PERSISTENT_CORE_FILE}, in ${CC_AGENTS_GROUP}, the credential loader at 0700/0600 with one hook and no token in the home, a git identity git itself reads with useConfigOnly true and none above them; every key present exactly once"
    else
      ok "every person: home 750, authorized_keys 600, no sudo, in ${MEMBERS_GROUP}, workspaces symlink, one conventions pointer per core, the claw-briefing pointer once in ${PER_TASK_CORE_FILE} and absent from ${PERSISTENT_CORE_FILE}, in ${CC_AGENTS_GROUP}, the credential loader at 0700/0600 with one hook and no token in the home, a git identity git itself reads with useConfigOnly true and none above them. The key-uniqueness leg is build-only and did NOT run on this update"
    fi
  fi

  if [ -n "$no_cred" ]; then
    bad "these people are NOT in ${CC_AGENTS_GROUP} and can read no credential:${no_cred}"
  fi

  # THE CLAW'S OWN TOKEN FILE. One file, so this is one reading for everybody
  # rather than one per person.
  #
  # A FILE WITH NOTHING IN IT IS SAID OUT LOUD, and it is a note rather than a
  # failure. Provisioning cannot put the value there: the token comes from the
  # firm's own manager through a door a person opens, and a run that could fill
  # it would be a run that held a credential. What a run CAN do is refuse to
  # report every person finished when every op:// reference on the box will
  # fail, which is what everybody who ever arrived here found for themselves.
  if [ "$(cc_agents_token_state)" = "present" ]; then
    stat_line="$(stat -c '%a %U:%G' "$CC_AGENTS_TOKEN" 2>/dev/null || echo missing)"
    if [ "$stat_line" = "${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER}" ]; then
      ok "this claw's agents token is ${stat_line} at ${CC_AGENTS_TOKEN}, so ${CC_AGENTS_GROUP} reads it and nobody else does"
    else
      bad "${CC_AGENTS_TOKEN} is ${stat_line}, wanted ${CC_AGENTS_TOKEN_MODE} ${CC_AGENTS_TOKEN_OWNER} -- that mode and that group are the whole read boundary on this credential"
    fi
  else
    warn "this claw holds NO agents token at ${CC_AGENTS_TOKEN}, so nobody here resolves an op:// reference however correct their groups are"
    human "install it once, and it covers everybody: drop the token under umask 077 at /run/user/\$(id -u)/commonclaw-agents-token, then run ${GRANTED_AGENTS_TOKEN}"
  fi

  # WHERE IT RESTS, asked of the backup rail rather than asserted here. This is
  # the reading that keeps the choice of path true over time: the day somebody
  # adds a backup target that covers it, this turns red instead of the
  # credential quietly entering every snapshot for the whole retention window.
  cap=""; cap_rc=0
  cap="$(cc_agents_backup_captures "${SCRIPT_DIR}/commonclaw-backup.sh")" || cap_rc=$?
  case "$cap_rc" in
    1) ok "${CC_AGENTS_TOKEN} is captured by NO backup target, asked of commonclaw-backup.sh itself" ;;
    0) bad "${CC_AGENTS_TOKEN} is INSIDE a backup target: $(printf '%s' "$cap" | tr '\n' ' '). Every snapshot would carry this claw's agents token for the whole retention window, and no delete on this box reaches a snapshot." ;;
    *) bad "commonclaw-backup.sh could not say what it captures, so where this credential rests was NOT measured. An unrun control is not a passed one." ;;
  esac

  # WHAT THE MEMBERS GROUP DOES NOT CARRY, measured rather than asserted.
  #
  # Everybody on the claw is in this group, so anything it reached would be
  # reached by everybody. Two readings say it carries no grant and owns only
  # what this release declares. Both fail branches are reachable: a sudoers file
  # naming the group trips the first, and any UNDECLARED group-owned path trips
  # the second.
  #
  # `|| true` on the first reading, and it is not decoration. Under `set -e`
  # with `pipefail` a grep that matches NOTHING exits 1, and that is the PASSING
  # world here, so without it the run dies at the exact moment the group is
  # clean and writes zero bytes of JSON. Measured on staging, not reasoned: that
  # check's pass branch was the unreachable one. The second reading needs no
  # such guard: its `find` sits in a process substitution whose exit status the
  # `while` never consumes, so a permission-denied walk cannot kill the run
  # either.
  #
  # WIDE MODE MOVES WHAT THIS READING EXPECTS AND DOES NOT SUSPEND IT. With the
  # switch on, ONE file may name the group and it is the one phase 19 owns. Every
  # other file naming it is still a failure, so a grant somebody wrote into a
  # second drop-in is still found on a wide-open claw. A control that went quiet
  # whenever wide mode was on would be a control that measures nothing on all
  # five of the claws this ruling is for.
  local grants other
  grants="$(grep -rlsF "$MEMBERS_GROUP" "$SUDOERS_MAIN" "${SUDOERS_DIR}/" 2>/dev/null | LC_ALL=C sort || true)"
  if [ "$WIDE_MODE" = "on" ]; then
    other="$(printf '%s\n' "$grants" | grep -v '^$' | grep -vxF "$WIDE_SUDOERS" | tr '\n' ' ' || true)"
    if [ -z "$other" ]; then
      ok "wide mode is on, and ${WIDE_SUDOERS} is the ONLY sudoers file naming ${MEMBERS_GROUP}"
    else
      bad "wide mode is on, and sudoers file(s) OTHER than ${WIDE_SUDOERS} name ${MEMBERS_GROUP}: ${other} -- wide mode grants through one file and nothing else may"
    fi
  else
    grants="$(printf '%s' "$grants" | tr '\n' ' ')"
    if [ -z "${grants// /}" ]; then
      ok "no sudoers file names ${MEMBERS_GROUP}: the group carries no grant"
    else
      bad "sudoers file(s) name ${MEMBERS_GROUP}: ${grants} -- with wide mode off, a group everybody is in must carry no grant"
    fi
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
  #
  # WHAT THE RELEASE DECLARES THIS GROUP MAY OWN. Two entries, and the check
  # compares against them rather than against one hardcoded path:
  #   ${CLAW_BRIEFING}   one file, laid 0664 root:${MEMBERS_GROUP} by phase 7.
  #   ${BUS_HOME}        the shared bus, laid 2770 setgid root:${MEMBERS_GROUP}
  #                      by phase 16, AND EVERYTHING UNDER IT.
  #
  # WHY THIS CHANGED. The earlier form asserted the group owned EXACTLY ONE path
  # anywhere. Phase 16 of the same release creates the bus group-owned, and
  # phase 8 runs before phase 16, so a first apply passed on a box with no bus
  # yet and every apply after it failed on the bus the previous run left. That
  # is not the group reaching something it should not. It is the release's own
  # artifact, working as designed, measured by a check whose premise stopped
  # being true when the bus shipped.
  #
  # THE BUS IS A TREE AND NOT A PATH, and that is not a convenience. The home is
  # setgid, so every file written there carries the group by design, and the set
  # GROWS WITH TRAFFIC: one cursor and one inbox per handle that ever registers,
  # plus the board, the lock and the log. A declaration naming the directory
  # alone would pass provisioning and go red at the first `bus init`.
  #
  # ACCEPTING THE SUBTREE GRANTS NOTHING THE DIRECTORY DOES NOT ALREADY GRANT.
  # ${BUS_HOME} is 2770 and group-writable, so a member already creates, reads
  # and removes files under it. This is the same reasoning the /tmp exclusion
  # above rests on, applied to a directory this release lays on purpose.
  #
  # DECLARED, NOT PRUNED, and the difference is the whole point. Pruning
  # ${STATE_ROOT} would stop sweeping a tree where the property still matters: a
  # group-owned file sitting BESIDE the bus under ${STATE_ROOT} is exactly the
  # quiet grant this check exists to find, and it is still found. Only the bus
  # subtree is forgiven, and only because the release lays it.
  #
  # ONE-DIRECTIONAL, deliberately. A declared path that is ABSENT is not a
  # failure here. Phase 8 runs before phase 16, so on a first build the bus does
  # not exist and the briefing is all there is. The property this check defends
  # is that nothing UNDECLARED carries the group, and an absence cannot violate
  # it. Each declared path's own existence and mode is checked by the phase that
  # lays it, which is where that check belongs.
  #
  # NO REGEX ON A PATH. The declared entries are matched with `case` against
  # quoted variables, which compares literally. A grep -v of "^${BUS_HOME}/"
  # would treat the path as a pattern, and a declared path is data.
  local undeclared="" swept=""
  while IFS= read -r swept; do
    case "$swept" in
      "$CLAW_BRIEFING"|"$BUS_HOME"|"$BUS_HOME"/*) continue ;;
    esac
    undeclared="${undeclared}${swept} "
  done < <(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
                     -o -path /tmp -o -path /var/tmp -o -path /home \) -prune \
             -o -group "$MEMBERS_GROUP" -print 2>/dev/null | LC_ALL=C sort)
  if [ -z "${undeclared// /}" ]; then
    ok "${MEMBERS_GROUP} owns only what this release declares: ${CLAW_BRIEFING}, and ${BUS_HOME} with its contents"
  else
    bad "${MEMBERS_GROUP} owns path(s) this release does NOT declare, where the group is a grant: ${undeclared}-- declared: ${CLAW_BRIEFING} and the ${BUS_HOME} tree"
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

  # ---- who the roster comes from ----
  #
  # ON A CLAW WITH AN AUTHORITY REGISTRY, `--claw-admins` IS IGNORED. The
  # registry is the firm's own record of who holds authority here, and it moves
  # only by somebody signing for the change. A run that re-added everybody the
  # build once named would resurrect an admin the firm had removed, on a tick
  # nobody watched start, with the argument doing it sitting in a runbook
  # somebody wrote months earlier.
  #
  # The argument is not refused, because a re-run typing it is ordinary and
  # refusing would make an old runbook fail a whole ride. It is ignored, and the
  # ignoring is said out loud, because a silently discarded roster reads exactly
  # like an applied one.
  #
  # THE ARRAY IS REPLACED RATHER THAN EMPTIED, and that is the whole reason this
  # sits above the loops instead of beside the seed in phase 18. Every check
  # below reads `CLAW_ADMINS` -- the uid floor, the membership pair, the no-sudo
  # constraint, and the caller the exactly-scoped grant control runs as. Emptying
  # it would leave all of them with nothing to measure while the run stayed
  # green, which is the shape this project has paid for more than once.
  if [ -s "$AUTHORITY_OWNER" ]; then
    if [ "${#CLAW_ADMINS[@]}" -gt 0 ]; then
      warn "--claw-admins was given and this claw carries an authority registry, so the argument was IGNORED. The roster is ${AUTHORITY_ROOT}, and it moves only by the owner signing for a change."
    fi
    local reg_roster
    reg_roster="$(awk '!/^#/ && NF {print $1}' "$AUTHORITY_OWNER" "$AUTHORITY_ADMINS" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ')"
    # shellcheck disable=SC2206
    CLAW_ADMINS=($reg_roster)
    ok "the claw-admin roster comes from the authority registry: ${#CLAW_ADMINS[@]} person(s)"
  fi

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
# somebody no key at all unless the caller says the lockout is the intent; a
# runtimes door that takes a name, an https URL and a sha256 together or not at
# all, compares the bytes against that hash before anything lands, refuses an
# archive that would write outside its own directory, and never replaces a tree
# a member may hold a session against) and a second copy of those rules here
# would drift from the copy the script enforces.
#
# Two of these take no path argument at all. Each token door composes its drop
# path from the caller's own uid, because a caller-supplied path would let a
# member name any file root can read and have it installed and then destroyed.
# The agents door takes no argument beyond --dry-run: it writes ONE file for the
# whole claw, so there is no name for a caller to aim it with.
#
# THE AUTHORITY DOOR IS GRANTED HERE AND DECIDES NOTHING ON THAT BASIS. Being in
# this alias only means a claw-admin may start it. What it does is decided by a
# signature it verifies against the claw's own registry, so an admin holding this
# grant and no signature can apply nothing at all. The grant is the ignition; the
# signature is the authority. Tenant doors the firm approves through it are
# granted in their own drop-in, never in this file, because this one is rewritten
# on every provisioning ride and a tenant's grant living here would be erased by
# the next release with nothing telling the firm.
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
  local sudoers_text; sudoers_text="$(cat "$SUDOERS_MAIN" 2>/dev/null || true)"
  case "$sudoers_text" in
    *"includedir ${SUDOERS_DIR}"*) ok "sudoers includes the drop-in directory" ;;
    *) bad "sudoers carries no includedir for ${SUDOERS_DIR} -- the grant is written and inert" ;;
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
  # THE CANDIDATES COME FROM THE GROUP, NOT FROM THE ARGUMENT LIST.
  #
  # This loop read `CLAW_ADMINS` alone, which the updater never fills: a release
  # ride composes no `--claw-admins`, so the array was empty on every ride, the
  # control never ran, and the sentence it printed instead -- "this claw carries
  # no claw-admin member" -- was untrue on a claw whose group held one. Measured
  # on a tenant claw on 2026-09-02, where the group read `claw-admin:x:988:...`
  # while the control reported the group empty. A control that cannot run on the
  # unattended path is a control that has never run where it matters.
  #
  # The group is the same source the rest of this script trusts for people,
  # under the law that identity belongs to a build: whoever makes an admin also
  # makes the membership, so the group cannot drift from the people it names.
  # The argument still wins where it was given, because a caller naming a roster
  # is naming who this run is about.
  local prover="" candidates=()
  if [ "${#CLAW_ADMINS[@]}" -gt 0 ]; then
    candidates=("${CLAW_ADMINS[@]}")
  else
    local gline gmembers gid p
    gline="$(getent group "$CLAW_ADMIN_GROUP" 2>/dev/null || true)"
    gmembers="$(printf '%s' "$gline" | cut -d: -f4)"
    gid="$(printf '%s' "$gline" | cut -d: -f3)"
    # Secondary members come from the group line. Somebody whose PRIMARY group is
    # this one appears nowhere on it, so the passwd sweep is the other half: a
    # prover this check could not see is a control that stays unrun for a reason
    # nobody would guess.
    IFS=',' read -r -a candidates <<< "$gmembers"
    if [ -n "$gid" ]; then
      while IFS=: read -r p _ _ pgid _; do
        [ "$pgid" = "$gid" ] || continue
        candidates+=("$p")
      done < <(getent passwd)
    fi
  fi

  for a in "${candidates[@]:-}"; do
    [ -z "$a" ] && continue
    getent passwd "$a" >/dev/null 2>&1 || continue
    gtext=" $(id -nG "$a" 2>/dev/null || true) "
    case "$gtext" in *" ${CLAW_ADMIN_GROUP} "*) prover="$a"; break ;; esac
  done

  if [ -z "$prover" ]; then
    warn "grant control NOT RUN: no account on this claw is in ${CLAW_ADMIN_GROUP}, by argument or by group. An unrun control is not a passed one, and this one cannot be faked from root -- re-run it once the firm names its admins."
    human "name the firm's own admins with --claw-admins and re-run this phase, then confirm the grant control passes both legs"
    return 0
  fi
  case "${CLAW_ADMINS[*]:-}" in
    *"$prover"*) : ;;
    *) say "  the grant control runs as ${prover}, read from ${CLAW_ADMIN_GROUP} rather than from an argument" ;;
  esac

  for g in "${GRANTED_SCRIPTS[@]}"; do
    check "grant opens for $(basename "$g"), which it names (as ${prover}, not as root)" \
      member_may_run "$prover" "$g"
  done
  # THE REFUSAL PAIR MEASURES THE CLAW. THE FILE READING MEASURES THE DOOR.
  # Both run, and which one carries the scope claim depends on wide mode.
  #
  # With wide mode off a live refusal is the strongest evidence there is: the
  # grant opens for what it names and the adjacent script in the same directory
  # is refused, which is the difference between a per-script grant and a
  # per-directory one.
  #
  # With wide mode on, every member holds passwordless root by a ruling this
  # claw made. Nothing is refused to anybody, so asking sudo about this door's
  # scope answers a question about the claw instead. Driven on wagmi on
  # 2026-09-02: these three went red there and each was reporting the truth.
  # A control that cannot pass on a claw it is correct about is a control that
  # will one day be edited to match whatever the listing happens to say.
  if [ "$WIDE_MODE" = "on" ]; then
    say "  wide mode is on, so no member is refused anything here and no live refusal is possible. This door's scope is measured in ${SUDOERS_DROPIN} below, and the blanket grant is held to one file."
  else
    check "decoy refused: the adjacent script in the same directory is NOT granted" \
      member_refused "$prover" "$DECOY_SCRIPT"
    check "decoy cannot be executed either, so nothing beside the grant runs" \
      member_cannot_execute "$prover" "$DECOY_SCRIPT"
    check "a shell is refused" member_refused "$prover" /bin/sh
  fi

  # ---- what THIS door grants, read out of the file that grants it ----
  #
  # The scope claim lives here on every claw, wide or not, because this is the
  # only reading that is about the door rather than about the box.
  local seen want
  seen="$(door_file_commands "$SUDOERS_DROPIN" || true)"
  want="$(printf '%s\n' "${GRANTED_SCRIPTS[@]}" | LC_ALL=C sort -u)"
  if [ "$seen" = "$want" ]; then
    ok "${SUDOERS_DROPIN} names exactly the ${#GRANTED_SCRIPTS[@]} granted script(s) in its command alias"
  else
    bad "${SUDOERS_DROPIN}'s command alias does not match the granted set -- it names: $(printf '%s' "$seen" | tr '\n' ' ')"
  fi

  # The alias is half the claim. A file could name the right eleven and grant
  # something else on the next line, and the reading above would pass.
  local rules rule_n
  rules="$(door_file_rules "$SUDOERS_DROPIN")"
  rule_n="$(printf '%s' "$rules" | grep -c . || true)"
  if [ "${rule_n:-0}" = "1" ] && [ "$rules" = "%${CLAW_ADMIN_GROUP} ALL=(root) NOPASSWD: COMMONCLAW_ADMIN_OPS" ]; then
    ok "${SUDOERS_DROPIN} carries one grant line and it opens nothing but that alias"
  else
    bad "${SUDOERS_DROPIN} carries ${rule_n:-0} grant line(s) where this door declares one: $(printf '%s' "$rules" | tr '\n' '; ')"
  fi

  # ---- what the CLAW grants this caller, and which file said so ----
  #
  # THE OLD SENTENCE HERE CLAIMED MORE THAN IT MEASURED. It compared the whole
  # listing against the granted set and said "and nothing else" when the two
  # matched. On wagmi that match held while a blanket ALL sat two lines below in
  # the same output, because a blanket entry names no path for a path comparison
  # to see. Nothing was hidden, because the check below caught it, and the
  # sentence was still wider than its evidence.
  #
  # It now says what it measures: every script PATH the listing names is one
  # this door grants. That stays true and stays worth having under wide mode,
  # where the caller may run everything and the listing still enumerates no
  # second path. The blanket reading beside it carries the other half.
  #
  # The set is compared, never counted. A count has to be edited every time an
  # operation joins the member plane, and a check that gets edited to match the
  # listing is a check that has stopped asking anything.
  local listing seen_paths
  listing="$(sudo -u "$prover" -H sudo -n -l 2>/dev/null || true)"
  seen_paths="$(grep -oE '/[^ ,]+\.sh' <<< "$listing" | LC_ALL=C sort -u || true)"
  if [ "$seen_paths" = "$want" ]; then
    ok "the listing for ${prover} names no script path outside the ${#GRANTED_SCRIPTS[@]} this door grants"
  else
    bad "the listing for ${prover} names script path(s) this door does not grant: $(printf '%s' "$seen_paths" | tr '\n' ' ')"
  fi

  # A path set can match while the grant is still wide: one entry naming ALL
  # grants everything and carries no path at all. Which FILE wrote that entry is
  # the question, and sudo cannot be asked it, so the files are read.
  local blanket blanket_n
  blanket="$(blanket_grant_files "$prover")"
  blanket_n="$(printf '%s' "$blanket" | grep -c . || true)"
  if [ "$WIDE_MODE" = "on" ]; then
    if [ "$blanket" = "$WIDE_SUDOERS" ]; then
      ok "wide mode is on, and ${WIDE_SUDOERS} is the ONLY file granting ${prover} a blanket ALL"
    else
      bad "wide mode is on and ${prover}'s blanket grant comes from ${blanket_n:-0} file(s) rather than ${WIDE_SUDOERS} alone: $(printf '%s' "$blanket" | tr '\n' ' ')"
    fi
  elif [ "${blanket_n:-0}" -eq 0 ]; then
    ok "no sudoers file grants ${prover} a blanket ALL"
  else
    bad "wide mode is off and sudoers file(s) grant ${prover} a blanket ALL: $(printf '%s' "$blanket" | tr '\n' ' ')"
  fi
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

# The machine-path control's verdict, on its own so it can be read against
# fixture counts with no core to run and no tier to plant in.
#
# THE EXPECTATION IS TAKEN FROM THE READING. It used to be taken from the
# manifest: the control asserted the core would see the declared count with the
# probe misplaced and that count plus one with it in place. The reading comes
# from the machine-wide tier, and that tier also holds every entry this rail
# leaves alone, so the manifest's number and the directory's number stop being
# equal on the first claw that puts a skill of its own there. What the probe
# proves is a DELTA. One entry appears when the placement is right, none appears
# when it is wrong, and a delta is measured against the same tier's count with
# no probe in it at all.
#
# THE FLOOR IS WHAT KEEPS THE PASS LINE TRUE. A delta on its own says the
# directory is being read. It does not say the shipped skills are in it, which
# is the other half of what this control claims. So the count with no probe has
# to be at least what this run installed there, a bound a firm's own entries can
# only relax.
machine_path_verdict() { # <count_0> <count_a> <count_b> <declared> <shadowed>
  local c0="$1" ca="$2" cb="$3" declared="$4" shadow_n="$5" installed foreign line

  if [ -z "$c0" ] || [ -z "$ca" ] || [ -z "$cb" ]; then
    bad "machine-path control: the core produced no managed count, so no placement was measured -- check that the member can run the core and write its debug log"
    return 0
  fi

  # What this run put in that tier: every declared name except the ones this
  # claw's own entries hold, which are installed nowhere.
  installed=$((declared - shadow_n))
  foreign=$((c0 - installed))

  if [ "$c0" -lt "$installed" ]; then
    bad "machine-path control: this release installed ${installed} skill(s) into the machine-wide tier and the core reads managed ${c0} there, so something it installed is not loading"
  elif [ "$ca" = "$c0" ] && [ "$cb" = "$((c0 + 1))" ]; then
    line="machine-path control: with no probe the core reads managed ${c0}; the probe is invisible without the inner .claude segment (managed ${ca}) and visible with it (managed ${cb}); every shipped skill loads at the real path. Of that ${c0}, this release installed ${installed}, so ${foreign} were not installed by this release."
    [ "$foreign" -eq 0 ] || line="${line} Those ${foreign} are this claw's own, and phase 14 named each one above."
    ok "$line"
  elif [ "$ca" = "$cb" ]; then
    bad "machine-path control: both probe placements gave managed ${ca}, so the count is not measuring the directory and this readout proves nothing"
  else
    bad "machine-path control: expected managed ${c0} then $((c0 + 1)) against the ${c0} this tier reads with no probe, got ${ca} then ${cb}"
  fi
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

  # ---- the ledger: what a release put on this claw ----
  # THE RAIL REMOVES ONLY WHAT IT INSTALLED. Pruning used to read the manifest,
  # which answers a different question. The manifest says what should be here.
  # It says nothing about who put the rest here, so anything else in the tier
  # read as a leftover and went, unnamed, on a run nobody was watching. A firm
  # with its own machine-wide skills is the ordinary case, and the tier is open
  # to them.
  #
  # The record of what we installed is the declaration this phase already
  # writes at the end. It names exactly the set the last run materialized, so it
  # is the ledger. A second file carrying the same fact would be a second copy
  # of it, and the two would drift.
  #
  # A claw carrying no declaration has never met this rail. There the declared
  # set is seeded in as ours, so a first build converges normally and every
  # other entry on the box is somebody else's from the first run.
  #
  # THE ABSENCE OF THE FILE IS WHAT SEEDS, never a count of zero inside it. A
  # declaration naming no skill says this rail installed nothing here, which is
  # a true reading and has to stay one. Seeding on the count would hand every
  # declared name back to the rail the moment the file went empty.
  local ledger=() ledger_from led
  if [ -r "$SKILLS_DECLARATION" ]; then
    ledger_from="${SKILLS_DECLARATION}, written by the last run"
    while IFS= read -r led; do
      if [ -n "$led" ]; then ledger+=("$led"); fi
    done < <(sed -n 's/^  \([a-z][a-z0-9-]*\):$/\1/p' "$SKILLS_DECLARATION")
  else
    ledger=("${SKILL_NAMES[@]}")
    ledger_from="the manifest being applied: this claw carries no ${SKILLS_DECLARATION}"
  fi
  say "  ledger: ${#ledger[@]} skill(s) from ${ledger_from}"

  # ---- a name this claw already uses belongs to this claw ----
  # An entry no release installed, carrying a name the manifest now declares.
  # The claw's own entry wins and the shipped skill of that name stands down for
  # as long as the name is taken. Writing over it would delete a skill somebody
  # here put in place and report a green install on top of it. Refusing the
  # whole phase would hold every other skill off the claw over one name.
  #
  # The notice repeats on every apply, because the state persists and a one-time
  # line scrolls past. A shadowed name is recorded as shadowed and never as
  # installed, so no later run reads it back as ours and prunes it.
  local decl_i decl_name shadowed=() spot taken
  for decl_i in "${!SKILL_NAMES[@]}"; do
    decl_name="${SKILL_NAMES[$decl_i]}"
    in_list "$decl_name" "${ledger[@]}" && continue
    taken=""
    for spot in "${SKILLS_CANON}/${decl_name}" "${CLAUDE_MACHINE_SKILLS}/${decl_name}" "${CODEX_MACHINE_SKILLS}/${decl_name}"; do
      if [ -e "$spot" ] || [ -L "$spot" ]; then taken="$spot"; break; fi
    done
    [ -n "$taken" ] || continue
    shadowed+=("$decl_name")
    warn "shadowed: this claw's own '${decl_name}' at ${taken} was not installed by a release, so it takes precedence and the shipped skill of that name is NOT installed anywhere here. To take the shipped one instead, move that entry off the claw and apply again."
  done

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
    name="${SKILL_NAMES[$i]}"
    # A SHADOWED NAME IS NOT WRITTEN, ANYWHERE. Not the canonical copy and not
    # either link: a link into a canonical copy that does not exist is worse
    # than no link, and half the name shipped is a state nobody asked for.
    in_list "$name" "${shadowed[@]}" && continue
    src="${SKILL_SOURCES[$i]}"; dest="${SKILLS_CANON}/${name}"
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
  say "  skills: ${#SKILL_NAMES[@]} declared   rewritten: ${changed}   already current: ${unchanged}   shadowed: ${#shadowed[@]}"

  # ---- converge: what a release installed and the manifest dropped does not stay ----
  # THREE CASES, AND THE LEDGER DECIDES WHICH. Named in the manifest: handled
  # above. In the ledger and not in the manifest: a retired skill, and it goes.
  # In neither: nobody here put it there, so it stays exactly as it is, copy or
  # link, whatever it points at, and it is named in a note so the operator knows
  # this claw is carrying it.
  local entry base target pruned=0 kept=0
  for entry in "$SKILLS_CANON"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="$(basename "$entry")"
    in_list "$base" "${SKILL_NAMES[@]}" && continue
    if in_list "$base" "${ledger[@]}"; then
      rm -rf -- "$entry"; pruned=$((pruned+1))
    else
      warn "left alone: ${entry} was not installed by a release, so '${base}' stays as this claw has it"
      kept=$((kept+1))
    fi
  done
  for d in "$CLAUDE_MACHINE_SKILLS" "$CODEX_MACHINE_SKILLS"; do
    for entry in "$d"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      base="$(basename "$entry")"
      in_list "$base" "${SKILL_NAMES[@]}" && continue
      if in_list "$base" "${ledger[@]}"; then
        # A ledger name is ours to remove only while it still points into our
        # own root. One that does not was replaced by hand after we installed
        # it, and that replacement is the firm's, whatever our record says.
        target="$(readlink -- "$entry" 2>/dev/null)" || target=""
        case "$target" in
          "${SKILLS_CANON}/"*)
            rm -f -- "$entry"; pruned=$((pruned+1)) ;;
          *)
            warn "left alone: ${entry} carries a retired name and does not point into ${SKILLS_CANON}, so it is not this rail's to remove"
            kept=$((kept+1)) ;;
        esac
      else
        warn "left alone: ${entry} was not installed by a release, so '${base}' stays as this claw has it"
        kept=$((kept+1))
      fi
    done
  done
  [ "$pruned" -eq 0 ] || warn "removed ${pruned} entr(ies) a release installed and the manifest no longer declares"
  say "  tier: removed ${pruned}   left alone ${kept}   shadowed ${#shadowed[@]}"

  # ---- the materialized declaration ----
  # Every digest below was MEASURED after install. The file carries no
  # generation timestamp on purpose: a timestamp would make two identical runs
  # produce two different files, and convergence would stop being observable.
  {
    printf '# Materialized skill declaration. Written by provision-claw.sh.\n'
    printf '# Digests are MEASURED after install, never copied from the manifest.\n'
    printf '# Do not hand-edit. The next provisioning run rewrites this file.\n'
    printf '# This file is also the LEDGER of what a release put on this claw. The next\n'
    printf '# run removes what it names and the manifest has dropped, and leaves every\n'
    printf '# other skill on this claw alone.\n'
    printf 'source_manifest: %s\n' "$SKILLS_MANIFEST"
    printf 'canonical_root: %s\n' "$SKILLS_CANON"
    printf 'machine_dirs:\n'
    printf '  - %s\n' "$CLAUDE_MACHINE_SKILLS"
    printf '  - %s\n' "$CODEX_MACHINE_SKILLS"
    printf 'skills:\n'
    for i in "${!SKILL_NAMES[@]}"; do
      in_list "${SKILL_NAMES[$i]}" "${shadowed[@]}" && continue
      printf '  %s:\n' "${SKILL_NAMES[$i]}"
      printf '    source: %s\n' "${SKILL_SOURCES[$i]}"
      printf '    digest: sha256:%s\n' "${SKILL_DIGESTS[$i]}"
      [ -z "${SKILL_PINS[$i]}" ] || printf '    pin: %s\n' "${SKILL_PINS[$i]}"
    done
    # SHADOWED NAMES SIT OUTSIDE `skills:` ON PURPOSE. That block is the ledger
    # of what this rail installed, and the next run prunes from it. A shadowed
    # name recorded there would be pruned as ours on the run after, which is the
    # deletion this whole mechanism exists to prevent.
    if [ "${#shadowed[@]}" -gt 0 ]; then
      printf 'shadowed:\n'
      for name in "${shadowed[@]}"; do printf '  - %s\n' "$name"; done
    fi
  } > "$SKILLS_DECLARATION"
  chmod 0644 "$SKILLS_DECLARATION"

  local struct_ok=1
  for i in "${!SKILL_NAMES[@]}"; do
    name="${SKILL_NAMES[$i]}"; dest="${SKILLS_CANON}/${name}"
    # A SHADOWED NAME IS SATISFIED BY THIS CLAW'S OWN ENTRY. The shipped skill
    # is deliberately absent under that name, so the three readings below would
    # fail on a state the run chose. What is checked instead is that the entry
    # which won the name is still standing, and that the record says so.
    if in_list "$name" "${shadowed[@]}"; then
      taken=""
      for spot in "${dest}" "${CLAUDE_MACHINE_SKILLS}/${name}" "${CODEX_MACHINE_SKILLS}/${name}"; do
        if [ -e "$spot" ] || [ -L "$spot" ]; then taken="$spot"; break; fi
      done
      [ -n "$taken" ] || { bad "${name} was recorded shadowed and no entry of that name is on this claw"; struct_ok=0; }
      grep -qE "^  - ${name}$" "$SKILLS_DECLARATION" || { bad "${name} is shadowed by this claw's own entry and ${SKILLS_DECLARATION} does not record it"; struct_ok=0; }
      continue
    fi
    [ -r "${dest}/SKILL.md" ] || { bad "${name}: no readable SKILL.md at ${dest}"; struct_ok=0; }
    for d in "$CLAUDE_MACHINE_SKILLS" "$CODEX_MACHINE_SKILLS"; do
      [ -L "${d}/${name}" ] && [ "$(readlink -f "${d}/${name}")" = "$(readlink -f "$dest")" ] \
        || { bad "${d}/${name} does not resolve to ${dest}"; struct_ok=0; }
    done
    grep -qE "^  ${name}:$" "$SKILLS_DECLARATION" || { bad "${name} is installed but absent from ${SKILLS_DECLARATION}"; struct_ok=0; }
  done
  if [ "$struct_ok" -eq 1 ]; then
    if [ "${#shadowed[@]}" -gt 0 ]; then
      ok "every declared skill is materialized once and linked into both machine directories, or is a name ${#shadowed[@]} of this claw's own entries hold"
    else
      ok "every declared skill is materialized once and linked into both machine directories"
    fi
  fi

  # ---- can an unprivileged member actually read it? ----
  # THE PROBE READS A SKILL THIS RUN INSTALLED. A shadowed name is this claw's
  # own entry at a path the rail did not write, so reading it would answer a
  # question about the firm's file rather than about the tier this phase built.
  local member="${PEOPLE[0]:-}" probe=""
  for i in "${!SKILL_NAMES[@]}"; do
    in_list "${SKILL_NAMES[$i]}" "${shadowed[@]}" && continue
    probe="${SKILL_NAMES[$i]}"; break
  done
  if [ -n "$member" ] && [ -n "$probe" ]; then
    name="$probe"
    if sudo -u "$member" -H test -r "${CLAUDE_MACHINE_SKILLS}/${name}/SKILL.md" \
       && sudo -u "$member" -H test -r "${CODEX_MACHINE_SKILLS}/${name}/SKILL.md"; then
      ok "an unprivileged member reads a shipped skill through both machine paths"
    else
      bad "a member cannot read a shipped skill through the machine paths -- check traversal on ${OPT_ROOT}"
    fi
  fi

  phase_14_core_observables "$member" "${#shadowed[@]}"

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
  local member="$1" shadow_n="${2:-0}"
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
    human "re-run phase 14 once the persistent-session core is installed, and require the probe to raise the tier's own managed count by exactly one at the real path and by nothing at the dropped-segment path"
    return 0
  fi

  # THE CONTROL. The managed path carries an inner .claude segment that is easy
  # to drop, and a wrong path fails SILENTLY: zero skills load and nothing says
  # why. So the tier is read THREE times: once with no probe anywhere, once with
  # the probe at the dropped-segment path, once with it at the real path. The
  # first reading is the baseline the other two are measured against. One
  # placement alone proves nothing, because a count that never moves is not
  # measuring the directory, and a count compared against a number this script
  # composed from the manifest is measuring the manifest.
  #
  # THE THIRD READING IS THIS UNIT'S COST, NAMED SO IT CLASSIFIES ON SIGHT. It
  # is one more start of the persistent-session core, unauthenticated, out of the
  # same throwaway home, capped by the same `timeout` as the other two. It buys
  # the only number the tier's own count can be compared against.
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
  local declared="${#SKILL_NAMES[@]}" log_0 log_a log_b count_0 count_a count_b
  log_0="${run_home}/no-probe.log"
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

  # The baseline, taken with no probe at either placement. Both were removed
  # above, so this reads the tier as the run leaves it.
  count_0="$(read_managed "$log_0")"

  write_probe "$probe_wrong"
  count_a="$(read_managed "$log_a")"
  rm -rf -- "$probe_wrong"

  write_probe "$probe_right"
  count_b="$(read_managed "$log_b")"
  rm -rf -- "$probe_right"

  machine_path_verdict "$count_0" "$count_a" "$count_b" "$declared" "$shadow_n"

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
    say "  would converge ${STATE_ROOT} to 0755 root:root and say whether it was adopted or moved,"
    say "  create ${BUS_HOME} 2770 root:${MEMBERS_GROUP}, install ${BUS_CLI} + ${BUS_JOIN_HOOK},"
    say "  register the session-start join in ${MANAGED_SETTINGS}, install ${BUS_DOC},"
    say "  and read a member's own traverse and write before running the join as them"
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
  # 0755 BECAUSE MEMBERS MUST TRAVERSE IT. Two readers below this root need to
  # walk through it and neither is root: a member reaching the bus, and a member
  # of the credential group reading the claw's agents token. The token's own
  # 0640 is what refuses everybody else, and the refusal is measured rather than
  # reasoned about. So a secret DOES rest under this root, deliberately, and the
  # directory above it is still world-traversable.
  #
  # ⚠ commonclaw-backup.sh USED TO RESET THIS DIRECTORY TO 0700 on every run
  # (`install -d -m 0700`, which applies the mode to a directory that already
  # exists -- measured 2026-08-14). That silently cut every member off from the
  # bus one backup after provisioning installed it, and the sessions would have
  # kept reporting a healthy join into a directory they could no longer reach.
  # The backup rail now creates this root at the same mode.
  #
  # FOUR THINGS WRITE UNDER THIS ROOT and only two of them can move its mode.
  # `install -d -m MODE a/b` applies MODE to the LAST component alone; a parent
  # it has to create gets the caller's default instead -- measured 2026-08-19,
  # GNU coreutils 9.4. So the notify rail's 0700 dedupe directory and the
  # updater's defer directory cannot tighten this root even when it is absent.
  # This phase and the backup rail are the two that name the root itself, and
  # they agree. A fifth writer that names the root agrees with them or the bus
  # and the token both die on a schedule.
  #
  # THE CONVERGENCE IS REPORTED, NOT SILENT (Q62). A hand-set mode that already
  # matches is adopted and said so; one that differs is converged and the old
  # value is named. Without the reading above the write, a run that repaired a
  # broken claw and a run that found it correct print the same sentence, and the
  # operator who has to know which cannot tell.
  local root_before="missing"
  [ -d "$STATE_ROOT" ] && root_before="$(stat -c '%a %U:%G' "$STATE_ROOT")"
  install -d -m 0755 -o root -g root "$STATE_ROOT"
  case "$root_before" in
    missing)        say "  ${STATE_ROOT} created 0755 root:root" ;;
    "755 root:root") say "  ${STATE_ROOT} was already 0755 root:root and was adopted unchanged" ;;
    *)              warn "${STATE_ROOT} was ${root_before} and has been converged to 0755 root:root. Anything that set it is a writer this phase does not know about; find it, or the next run of it takes the bus and the claw token away again." ;;
  esac
  check "${STATE_ROOT} is 0755 root:root so a member can traverse it to the bus and to the claw token" \
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
  # THE REACH IS MEASURED BEFORE THE JOIN, AND AS THE MEMBER.
  #
  # The join below is one verdict with one message, and it has two failure modes
  # that need different repairs: a member who cannot TRAVERSE the state root, and
  # a member who cannot ENTER the bus home. Both come out of the hook as the same
  # silence. This claw has already had the first one -- the state root sat 0700
  # and every member's bus went with it, with nothing in any run naming the mode
  # as the reason. A run that reports a failure it cannot locate sends the
  # operator to the wrong file.
  #
  # `-x` on a directory IS the traverse permission and `-w` IS the write bit, so
  # these read the exact bits the hook consumes rather than standing in for them.
  # They are asked of a FRESH process running as the member, because a live login
  # holds the group set it started with and would answer for an older claw.
  local reach_root=1 reach_bus=1 reach_write=1
  sudo -u "$member" -H bash -c "[ -x '$STATE_ROOT' ]"  || reach_root=0
  sudo -u "$member" -H bash -c "[ -x '$BUS_HOME' ]"    || reach_bus=0
  sudo -u "$member" -H bash -c "[ -w '$BUS_HOME' ]"    || reach_write=0
  [ "$reach_root" -eq 1 ] \
    && ok "${member} can traverse ${STATE_ROOT}, which is what stands between a member and the bus" \
    || bad "${member} CANNOT traverse ${STATE_ROOT} (it is $(stat -c '%a %U:%G' "$STATE_ROOT" 2>/dev/null || echo missing)). Nothing under it is reachable to them, the bus and the claw's agents token included. This phase sets that mode; something else moved it after."
  [ "$reach_bus" -eq 1 ] \
    && ok "${member} can enter ${BUS_HOME}" \
    || bad "${member} CANNOT enter ${BUS_HOME} (it is $(stat -c '%a %U:%G' "$BUS_HOME" 2>/dev/null || echo missing)). Check they are in ${MEMBERS_GROUP} and that the directory is 2770 root:${MEMBERS_GROUP}."
  [ "$reach_write" -eq 1 ] \
    && ok "${member} can write in ${BUS_HOME}, so their session can register a handle" \
    || bad "${member} CANNOT write in ${BUS_HOME}. A member who can read the bus and not write it joins nothing and reports no error of their own."

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

# ---------------------------------------------------------------- phase 17

phase_17_runtimes() {
  head1 17 "the shared language runtimes"

  local door="${SCRIPT_DIR}/manage-runtimes.sh"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would create ${RUNTIMES_ROOT} and ${RUNTIMES_FARM} 0755 root:root,"
    say "  install ${RUNTIMES_PROFILE} and ${RUNTIMES_DOC},"
    say "  and converge this claw to what the workspace manifests declare"
    return 0
  fi

  # ---- the roots ----
  #
  # 0755 and world-readable, unlike the provisioning prefix beside it. Every
  # member's shell resolves a program through the farm and executes a binary in
  # the tree, so both have to be reachable by everybody. Nothing secret is here:
  # these are vendor bytes whose URL and hash are already in a world-readable
  # log.
  install -d -m 0755 -o root -g root "$RUNTIMES_ROOT"
  install -d -m 0755 -o root -g root "$RUNTIMES_FARM"
  check "${RUNTIMES_ROOT} is 0755 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$RUNTIMES_ROOT')\" = '755 root:root' ]"
  check "${RUNTIMES_FARM} is 0755 root:root -- a member who could write it would rewrite what node means for everybody" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$RUNTIMES_FARM')\" = '755 root:root' ]"

  # ---- the PATH ----
  #
  # A DROP-IN RATHER THAN AN EDIT. /etc/profile is the distro's file and a claw
  # that appended to it would fight the next package upgrade. The drop-in is
  # ours, it is overwritten on every run, and that is how a change to it reaches
  # a claw.
  if [ -r "${TEMPLATE_DIR}/runtimes-profile.sh" ]; then
    install -m 0644 -o root -g root "${TEMPLATE_DIR}/runtimes-profile.sh" "$RUNTIMES_PROFILE"
    check "${RUNTIMES_PROFILE} is 0644 root:root" \
      bash -c "[ \"\$(stat -c '%a %U:%G' '$RUNTIMES_PROFILE')\" = '644 root:root' ]"
    check "the PATH drop-in parses" bash -n "$RUNTIMES_PROFILE"
    # THE CHECK THAT ANSWERS THE QUESTION THE FILE EXISTS FOR, run as a member
    # in a real login shell rather than read out of the file. A drop-in that
    # parses and does not take is indistinguishable from one that works, until
    # somebody types `node`.
    local member="${PEOPLE[0]:-}"
    if [ -n "$member" ]; then
      check "${member}'s login shell carries ${RUNTIMES_FARM} on PATH" \
        bash -c "sudo -u '$member' -H bash -lc 'case \":\$PATH:\" in *:${RUNTIMES_FARM}:*) exit 0 ;; *) exit 1 ;; esac' </dev/null"
    else
      warn "PATH NOT PROVEN: this claw carries nobody to run a login shell as"
    fi
  else
    bad "no ../templates/runtimes-profile.sh, so nothing puts ${RUNTIMES_FARM} on a member's PATH"
  fi

  # ---- the member's own copy of what this is ----
  if [ -r "${TEMPLATE_DIR}/runtimes.md" ]; then
    install -m 0644 -o root -g root "${TEMPLATE_DIR}/runtimes.md" "$RUNTIMES_DOC"
    ok "member-facing runtimes reference installed at ${RUNTIMES_DOC}"
  else
    bad "no ../templates/runtimes.md, so members have nothing that says how to declare a runtime or where the shared copy lives"
  fi

  check "the runtimes door is installed where the grant names it" test -x "$GRANTED_RUNTIMES"

  # ---- convergence ----
  #
  # WHAT A DECLARATION CAN AND CANNOT DO. It can bring back a runtime this claw
  # has already been given, because the member-plane log holds the URL and the
  # hash of every install it ever took. It cannot pull something down from
  # nowhere: a declaration with no recorded pin is reported and left, and a
  # claw-admin gives it a source once, by hand, through the door.
  #
  # THE COST, NAMED. This phase runs on every ride, including an unattended one
  # under the updater, and a satisfiable-but-absent declaration means a download
  # of vendor bytes on that tick. It is bounded: only what a manifest declares,
  # only what the log already records, only what is not already on disk, and the
  # door caps a single payload. The steady state is zero fetches, because the
  # runtime is already there.
  if [ ! -x "$door" ]; then
    bad "no ${door} beside this script, so nothing can converge this claw to its declarations"
    return 0
  fi

  local listing declared id pin_url pin_sha
  listing="$("$door" --list 2>/dev/null || true)"
  if ! declared="$(printf '%s' "$listing" | jq -r '.declared[]?' 2>/dev/null)"; then
    bad "the runtimes door did not return readable JSON, so this claw's declarations could not be read"
    return 0
  fi

  if [ -z "$declared" ]; then
    ok "no workspace declares a runtime, so there is nothing to converge"
    return 0
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ -d "${RUNTIMES_ROOT}/${id}" ]; then
      ok "${id} is declared and installed"
      continue
    fi
    # THE PIN COMES OUT OF THE RECORD, and it is read by the door rather than by
    # this phase. The row's shape is the door's; a second reader of it here
    # would be a second answer to "where did this runtime come from", and the
    # two would drift on the day the row changes.
    pin_url="$(printf '%s' "$listing" | jq -r --arg id "$id" '.pins[]? | select(.runtime == $id) | .url' 2>/dev/null | tail -1 || true)"
    pin_sha="$(printf '%s' "$listing" | jq -r --arg id "$id" '.pins[]? | select(.runtime == $id) | .sha256' 2>/dev/null | tail -1 || true)"
    if [ -z "$pin_url" ] || [ -z "$pin_sha" ]; then
      bad "${id} is declared by a workspace, is not installed, and has never been installed on this claw -- nothing here knows where to get it"
      human "give ${id} a source once: sudo ${GRANTED_RUNTIMES} --install ${id} --url <link> --sha256 <hash>. Every ride after that converges it from the record."
      continue
    fi
    say "  converging ${id} from the recorded pin (${pin_url})"
    warn "${id} was declared and absent, so this run fetched it. On an unattended tick that is a download nobody watched start."
    if "$door" --install "$id" --url "$pin_url" --sha256 "$pin_sha" >/dev/null 2>&1; then
      ok "${id} converged from the pin recorded in ${ADMIN_LOG}"
    else
      bad "${id} is declared but could not be converged from its recorded pin -- run the door by hand and read what it refuses"
    fi
  done <<< "$declared"

  # INSTALLED AND UNDECLARED IS A NOTE, NEVER A REMOVAL. A runtime nobody
  # declares may still be under somebody's open session, and a converging run
  # that deleted it would take a member's toolchain away on a schedule. The
  # removal is a decision, and there is a door for it.
  local installed
  installed="$(printf '%s' "$listing" | jq -r '.installed[]?' 2>/dev/null || true)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case $'\n'"${declared}"$'\n' in
      *$'\n'"${id}"$'\n'*) : ;;
      *) warn "${id} is installed and no workspace declares it. Nothing was removed: that is a decision, and ${GRANTED_RUNTIMES} --remove is where it is made." ;;
    esac
  done <<< "$installed"
}

# ---------------------------------------------------------------- phase 18

# THE NUMBER SKIPS 17 DELIBERATELY. The shared-runtimes phase is 17 on its own
# branch and rides the same release as this one. Two phases numbered 17 would
# merge into a file where `--only 17` runs one of them and the reader cannot see
# which, so this one takes the next free number rather than the next number.

# READ ONE PERSON'S OWN LOGIN KEYS AND WRITE THEM AS REGISTRY LINES.
#
# ONE RULE, USED TWICE. The owner seed and the admin adoption below both turn a
# person into registry lines. Two copies of that rule would drift in one of them
# and nothing would say so: the copy that took a key type the other refused, or
# the copy that stopped skipping a line carrying options.
#
# WHAT IT SKIPS, AND WHY THAT MATTERS MORE THAN IT LOOKS. An `authorized_keys`
# line can carry options in front of the key -- `command="..." ssh-ed25519 ...`.
# The patterns below anchor on the key type at the start of the line, so such a
# line is not taken. An allowed-signers file reads that same leading position as
# its own options with their own meaning, so a line copied across whole would
# turn a restriction on somebody's login into an instruction about their
# signature.
#
# Appends to <outfile>, prints how many keys it took, and answers with a distinct
# status for each way it can find none:
#   2  no such person here
#   3  their home or authorized_keys is a symlink, so the keys are not certainly theirs
#   4  no readable authorized_keys
#   5  readable, and carrying no key of a type this claw accepts
authority_keys_for() {   # authority_keys_for <person> <outfile>
  local who="$1" out="$2" whome ak line n=0
  getent passwd "$who" >/dev/null 2>&1 || return 2
  whome="$(getent passwd "$who" | cut -d: -f6)"
  ak="${whome}/.ssh/authorized_keys"
  if [ -L "$whome" ] || [ -L "$ak" ]; then return 3; fi
  [ -r "$ak" ] || return 4
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *)
        printf '%s %s\n' "$who" "$line" >> "$out"
        n=$((n+1)) ;;
    esac
  done < "$ak"
  [ "$n" -gt 0 ] || return 5
  printf '%s\n' "$n"
  return 0
}

phase_18_authority() {
  head1 18 "the authority registry and the tenant doors"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would create ${AUTHORITY_ROOT}, install ${CLAW_BIN}/claw-authority and ${ETC_ROOT}/claw-authority.md"
    [ -n "$OWNER_ARG" ] && say "  would seed the owner as ${OWNER_ARG} from their own login keys, only if no owner is recorded"
    [ -n "$OWNER_ARG" ] && say "  and, only on that same first laying, would adopt this claw's existing ${CLAW_ADMIN_GROUP} members into the registry from their own login keys"
    say "  would converge ${TENANT_DOOR_ROOT} and ${TENANT_SUDOERS} from the registry"
    return 0
  fi

  install -d -m 0755 -o root -g root "$AUTHORITY_ROOT"
  install -d -m 0755 -o root -g root "$AUTHORITY_DOORS"

  # ---- the member-plane program and the member-facing doc ----
  #
  # THE PROGRAM THAT DRAFTS AN APPROVAL HOLDS NO PRIVILEGE, and that is the
  # whole reason it is installed here beside `bus` rather than inside the
  # provisioning prefix. The design's central claim is that an agent can draft a
  # door and can never install one. That claim is not a rule somebody wrote down;
  # it is this file being world-executable, reaching no root path, and appearing
  # in no sudo grant.
  install -d -m 0755 -o root -g root "$CLAW_BIN"
  install -m 0755 -o root -g root "${PAYLOAD_DIR}/claw-authority" "${CLAW_BIN}/claw-authority"
  check "${CLAW_BIN}/claw-authority is 0755 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '${CLAW_BIN}/claw-authority')\" = '755 root:root' ]"
  # The claim, measured rather than asserted: the drafting program is in no
  # sudoers file on this claw. It is the one control that says an agent's reach
  # stops at a request.
  if grep -rsqF "${CLAW_BIN}/claw-authority" "$SUDOERS_MAIN" "${SUDOERS_DIR}/" 2>/dev/null; then
    bad "a sudoers file names ${CLAW_BIN}/claw-authority -- the drafting program must carry no grant, because an agent runs it"
  else
    ok "no sudoers file names the drafting program: composing a request reaches no privilege"
  fi

  install -m 0644 -o root -g root "${TEMPLATE_DIR}/claw-authority.md" "${ETC_ROOT}/claw-authority.md"
  check "the authority doc is world-readable at ${ETC_ROOT}/claw-authority.md" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '${ETC_ROOT}/claw-authority.md')\" = '644 root:root' ]"

  # ---- the owner, seeded once into an absence ----
  #
  # A CLAW HAS EXACTLY ONE OWNER AND THIS RUN CAN ONLY EVER LAY THE FIRST. After
  # that the owner moves by the current owner signing a transfer, so a later run
  # naming somebody else is a runbook disagreeing with the firm, and it is
  # refused rather than obeyed. Refused, not ignored: a hostname or a bucket
  # passed wrong is a mistake, and an owner passed wrong is somebody taking a
  # claw.
  #
  # THE KEYS COME FROM THE PERSON'S OWN AUTHORIZED KEYS, because the claw already
  # holds them and a second key to distribute is a second key to lose. What opens
  # their login is what speaks for them at the moment the registry is laid. From
  # then on the two records are separate, which is stated in the member doc: a
  # device lost by an admin needs the key door for the login and a signed
  # remove-admin for the authority.
  # Whether THIS run is the one that laid the registry. The adoption below turns
  # on it and on nothing else, so it is set in exactly one place: the branch that
  # writes the owner file into an absence.
  local OWNER_SEEDED_NOW=0

  if [ -s "$AUTHORITY_OWNER" ]; then
    local have_owner
    have_owner="$(awk '!/^#/ && NF {print $1; exit}' "$AUTHORITY_OWNER")"
    if [ -n "$OWNER_ARG" ] && [ "$OWNER_ARG" != "$have_owner" ]; then
      bad "--owner names ${OWNER_ARG} and this claw's owner is ${have_owner}. Ownership moves by ${have_owner} signing a transfer, never by an argument to a provisioning run."
    else
      ok "this claw's owner is ${have_owner}, recorded before this run and untouched by it"
    fi
  elif [ -n "$OWNER_ARG" ]; then
    local okeys orc=0
    : > "${AUTHORITY_OWNER}.tmp"
    okeys="$(authority_keys_for "$OWNER_ARG" "${AUTHORITY_OWNER}.tmp")" || orc=$?
    case "$orc" in
      0)
        install -m 0644 -o root -g root "${AUTHORITY_OWNER}.tmp" "$AUTHORITY_OWNER"
        ok "authority registry seeded: ${OWNER_ARG} is this claw's owner, with ${okeys} of their own key(s)"
        warn "the owner approves from their own device and nothing they need rests on this claw. A lost owner is a break-glass request to the vendor, in writing -- reference/claw-conventions.md carries it."
        OWNER_SEEDED_NOW=1 ;;
      2) bad "--owner names ${OWNER_ARG} and there is no such person on this claw" ;;
      3) bad "${OWNER_ARG}'s home or authorized_keys is a symlink, so the keys this run would read are not certainly theirs. The registry was not seeded." ;;
      4) bad "${OWNER_ARG} has no readable $(getent passwd "$OWNER_ARG" | cut -d: -f6)/.ssh/authorized_keys, so there is no key to record for them" ;;
      5) bad "${OWNER_ARG} carries no key of a type this claw accepts, so the registry was not seeded" ;;
      *) bad "the owner seed for ${OWNER_ARG} failed for a reason this run does not have a name for (${orc})" ;;
    esac
    rm -f "${AUTHORITY_OWNER}.tmp"
  else
    warn "no --owner and no registry: this claw has no authority model, so no tenant door can be approved on it. Pass --owner on a build to lay one."
  fi

  [ -f "$AUTHORITY_ADMINS" ] || : > "$AUTHORITY_ADMINS"
  chmod 0644 "$AUTHORITY_ADMINS"; chown root:root "$AUTHORITY_ADMINS"

  # ---- the admins this claw already had, adopted at the first laying ----
  #
  # THE STATE THIS CLOSES. The registry is authoritative for `claw-admin`, and it
  # was authoritative upward only: everybody the registry names goes into the
  # group, and somebody in the group the registry does not name is reported and
  # left, because an unattended tick must not take a firm's own admin's access
  # away.
  #
  # Every claw already running carries `claw-admin` members and no registry. A
  # first laying seeded from `--owner` alone therefore produced, on the morning
  # after the upgrade, a claw where every existing admin held every door the
  # group holds and no signature could take them out: a signed remove-admin acts
  # on the registry, and the registry had never heard of them.
  #
  # So the first laying adopts them, with their own login keys, by the same rule
  # `--owner` is seeded by. After it the registry names who is in the group and
  # each of them is removable by one signed remove-admin, which is the whole
  # point.
  #
  # ONLY AT THE FIRST LAYING, and that bound is the load-bearing half. A claw
  # that already has a registry has the firm's own signed decisions in it, and a
  # later ride reading the group back into the file would mean anybody who could
  # reach the group could put themselves in the registry -- a provisioning run
  # quietly undoing a signed remove-admin. After this one moment the group
  # follows the registry and never the reverse.
  #
  # THE OWNER IS NOT ADOPTED AS AN ADMIN. A person holds one tier, and the door
  # refuses an add-admin naming the owner for the same reason.
  #
  # ADOPTION IS NOT APPOINTMENT. Nothing here decides that somebody may approve
  # an act; the firm decided that when it put them in `claw-admin`, and this
  # writes down what is already true so that it can be changed by signature.
  if [ "$OWNER_SEEDED_NOW" -eq 1 ] && [ ! -s "$AUTHORITY_ADMINS" ]; then
    local a auid arc akeys adopted="" skipped=""
    : > "${AUTHORITY_ADMINS}.tmp"
    for a in $(getent group "$CLAW_ADMIN_GROUP" 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
      [ -n "$a" ] || continue
      [ "$a" != "$OWNER_ARG" ] || continue
      # EXISTENCE FIRST, THEN THE UID RULE. A name in the group with no passwd
      # entry has no uid to read, and `id -u` answering nothing would have it
      # reported as a system account -- a true refusal with a false reason, which
      # sends the firm to look at the wrong thing.
      if ! getent passwd "$a" >/dev/null 2>&1; then
        skipped="${skipped} ${a}(in the group and no such person here)"; continue
      fi
      auid="$(id -u "$a" 2>/dev/null || echo 0)"
      if [ "$auid" -lt 1000 ]; then
        skipped="${skipped} ${a}(system account, uid ${auid})"; continue
      fi
      arc=0
      akeys="$(authority_keys_for "$a" "${AUTHORITY_ADMINS}.tmp")" || arc=$?
      case "$arc" in
        0) adopted="${adopted} ${a}(${akeys} key(s))" ;;
        2) skipped="${skipped} ${a}(in the group and no such person here)" ;;
        3) skipped="${skipped} ${a}(home or authorized_keys is a symlink)" ;;
        4) skipped="${skipped} ${a}(no readable authorized_keys)" ;;
        5) skipped="${skipped} ${a}(no key of a type this claw accepts)" ;;
        *) skipped="${skipped} ${a}(unnamed failure ${arc})" ;;
      esac
    done
    if [ -s "${AUTHORITY_ADMINS}.tmp" ]; then
      install -m 0644 -o root -g root "${AUTHORITY_ADMINS}.tmp" "$AUTHORITY_ADMINS"
      ok "adopted into the authority registry at its first laying:${adopted}. Each of them is now removable by a signed remove-admin."
    else
      ok "no admin to adopt: ${CLAW_ADMIN_GROUP} held nobody but the owner when the registry was laid"
    fi
    rm -f "${AUTHORITY_ADMINS}.tmp"
    # SAID LOUDLY RATHER THAN LEFT IN THE COUNT. Somebody in the group this run
    # could not adopt keeps every door the group opens and stays outside the
    # registry, which is exactly the state the adoption exists to end. They are
    # named here and named again by the stray report below, and the firm's remedy
    # is a key for them and a signed add-admin.
    [ -z "$skipped" ] || warn "in ${CLAW_ADMIN_GROUP} and NOT adopted:${skipped}. They keep the group's doors and no signature can take them out until the owner signs an add-admin for them."
  fi

  if [ ! -s "$AUTHORITY_OWNER" ]; then
    warn "phase 18 stopped after the plane: with no owner recorded there is no registry to converge from, and an unrun control is not a passed one"
    return 0
  fi

  check "the owner file is 0644 root:root -- a registry its subject can edit is not a registry" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$AUTHORITY_OWNER')\" = '644 root:root' ]"
  check "the owner file holds exactly one person" \
    bash -c "[ \"\$(awk '!/^#/ && NF {print \$1}' '$AUTHORITY_OWNER' | sort -u | wc -l)\" = '1' ]"

  # ---- the group follows the registry ----
  #
  # CONVERGED UPWARD, REPORTED DOWNWARD. Everybody the registry names is put in
  # the group, because a tier that opens nothing is a tier in name. Somebody in
  # the group the registry does not name is REPORTED and left, because this run
  # cannot tell a stale membership from a claw that predates its registry, and
  # taking a firm's own admin's access away on a tick nobody watched start is the
  # wrong side to be wrong on. The signed remove-admin is what takes a person
  # out, and it does.
  local roster p gtext stray=""
  roster="$(awk '!/^#/ && NF {print $1}' "$AUTHORITY_OWNER" "$AUTHORITY_ADMINS" 2>/dev/null | LC_ALL=C sort -u)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    getent passwd "$p" >/dev/null 2>&1 || { bad "the registry names ${p} and there is no such person on this claw"; continue; }
    gtext=" $(id -nG "$p" 2>/dev/null || true) "
    case "$gtext" in
      *" ${CLAW_ADMIN_GROUP} "*) : ;;
      *) gpasswd -a "$p" "$CLAW_ADMIN_GROUP" >/dev/null 2>&1 || bad "could not put ${p} in ${CLAW_ADMIN_GROUP}" ;;
    esac
  done <<< "$roster"
  for p in $(getent group "$CLAW_ADMIN_GROUP" 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
    grep -qxF "$p" <<< "$roster" || stray="$stray $p"
  done
  if [ -n "$stray" ]; then
    warn "in ${CLAW_ADMIN_GROUP} and not in the authority registry:${stray}. Nothing was removed. A signed remove-admin is what takes somebody out; this run will not do it on its own."
  else
    ok "${CLAW_ADMIN_GROUP} holds exactly the people the registry names"
  fi

  # ---- the tenant doors ----
  #
  # THE RUNNING COPY IS REBUILT FROM THE RECORD, EVERY RIDE. `/etc/commonclaw` is
  # inside the roots the backup rail keeps and `/opt/commonclaw` is not, so a
  # restored claw comes back holding every approval and none of the binaries the
  # approvals point at. This loop is what closes that gap, and it is also what
  # repairs a wrapper somebody deleted.
  #
  # NOTHING HERE APPROVES ANYTHING. It lays what a signature already approved.
  # A door with no record is removed; a record with no approved bytes is
  # reported and its grant is dropped, because a grant naming a path this run did
  # not lay is a grant waiting for whatever appears there next.
  install -d -m 0755 -o root -g root "$OPT_ROOT"
  install -d -m 0750 -o root -g root "$TENANT_DOOR_ROOT"

  # DECIDED FIRST, PARSED SECOND, LAID THIRD, and the order is the same repair the
  # door itself carries. A ride that installed the bytes and then discovered the
  # grant file would not parse left a claw holding wrappers and scripts for doors
  # it had just been told were not granted, and the sweep below had already
  # removed whatever the previous ride laid. Deciding on paper costs nothing and
  # a half-converged door plane costs a firm its doors.
  local tmp_sudo rec name grp sha granted="" broken="" accepted=""
  tmp_sudo="$(mktemp)"
  {
    printf '# Managed by manage-claw-authority.sh and re-derived by provision-claw.sh.\n'
    printf '# Do not edit on the claw: it is rewritten whole from %s.\n' "$AUTHORITY_DOORS"
    printf '#\n'
    printf '# Every entry names a wrapper, never a tenant script. The wrapper re-checks\n'
    printf '# the approved content hash on every run and writes the member-plane row.\n'
    printf '\n'
  } > "$tmp_sudo"

  shopt -s nullglob
  for rec in "$AUTHORITY_DOORS"/*.json; do
    name="$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$rec" | head -1)"
    grp="$(sed -n 's/.*"group": *"\([^"]*\)".*/\1/p' "$rec" | head -1)"
    sha="$(sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p' "$rec" | head -1)"
    case "$name" in ''|*[!a-z0-9-]*) bad "a door record at ${rec} carries an unusable name -- skipped, and its grant was not written"; continue ;; esac
    case "$grp" in "$MEMBERS_GROUP"|"$CLAW_ADMIN_GROUP") : ;; *) bad "door '${name}' names group '${grp}', which is not a group a door may be granted to -- skipped"; continue ;; esac
    if [ ! -f "${AUTHORITY_DOORS}/${name}.sh" ]; then
      broken="$broken ${name}"; continue
    fi
    if [ "$(sha256sum "${AUTHORITY_DOORS}/${name}.sh" | cut -d' ' -f1)" != "$sha" ]; then
      bad "the recorded bytes of door '${name}' do not hash to what its record says was approved -- not laid, not granted"
      broken="$broken ${name}"; continue
    fi
    printf '%%%s ALL=(root) NOPASSWD: %s/%s\n' "$grp" "$TENANT_DOOR_ROOT" "$name" >> "$tmp_sudo"
    accepted="${accepted}${name} "
  done
  shopt -u nullglob

  [ -z "$broken" ] || bad "approved door(s) with no usable bytes on this claw:${broken}. The approval survives and the grant does not, which is what a restore looks like before the source is put back."

  # THE PARSE, WHILE NOTHING HAS BEEN LAID. A file that will not parse ends the
  # convergence here: this claw's door plane and its grant file are both left
  # exactly as the last good ride left them, which is a state the firm has seen
  # before and can still use.
  if ! visudo -cf "$tmp_sudo" >/dev/null 2>&1; then
    bad "the tenant grant file FAILED visudo -- nothing was laid, nothing was removed, and this claw's tenant doors are as the last ride left them"
    visudo -cf "$tmp_sudo" 2>&1 | sed 's/^/    /' >&2 || true
    rm -f "$tmp_sudo"
    return 0
  fi

  # THE WRAPPER IS CHECKED BEFORE IT IS LAID, and only when this ride is going to
  # lay one. Every door in `$accepted` becomes a copy of this single file, so
  # wrong bytes here are wrong bytes in every granted door on the claw at once.
  # Checking it on a ride that lays nothing would be a guard measuring something
  # its own run does not consume.
  if [ -n "$accepted" ]; then
    local wrap_sha
    wrap_sha="$(sha256sum "${TEMPLATE_DIR}/tenant-door-wrapper.sh" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$wrap_sha" != "$WRAPPER_SHA256" ]; then
      bad "the tenant-door wrapper in this release's templates is not the wrapper this run expects (${wrap_sha:-missing}, wanted ${WRAPPER_SHA256}) -- nothing was laid, and this claw's tenant doors are as the last ride left them"
      rm -f "$tmp_sudo"
      return 0
    fi
    ok "the tenant-door wrapper about to be laid is the one this release ships"
  fi

  for name in $accepted; do
    install -m 0750 -o root -g root "${AUTHORITY_DOORS}/${name}.sh" "${TENANT_DOOR_ROOT}/${name}.script"
    install -m 0750 -o root -g root "${TEMPLATE_DIR}/tenant-door-wrapper.sh" "${TENANT_DOOR_ROOT}/${name}"
    granted="$granted ${name}"
  done

  # Anything in the door root the registry does not name comes out. A leftover
  # wrapper is inert once its grant is gone, and a leftover script beside a name
  # somebody re-grants later is bytes nobody approved sitting where approved
  # bytes go.
  local f base sweep=""
  shopt -s nullglob
  for f in "$TENANT_DOOR_ROOT"/*; do
    base="$(basename "$f")"; base="${base%.script}"
    case " $granted " in
      *" $base "*) : ;;
      *) rm -f "$f"; sweep="$sweep $(basename "$f")" ;;
    esac
  done
  shopt -u nullglob
  [ -z "$sweep" ] || warn "removed from ${TENANT_DOOR_ROOT}, named by no approval:${sweep}"

  if [ -z "$granted" ]; then
    rm -f "$TENANT_SUDOERS"
    ok "no tenant door is approved on this claw, so ${TENANT_SUDOERS} is absent rather than empty"
  else
    install -m 0440 -o root -g root "$tmp_sudo" "$TENANT_SUDOERS"
    ok "the grant file that was parsed before anything was laid is the one now installed:${granted}"
  fi
  rm -f "$tmp_sudo"

  # ---- what the tenant plane must never be ----
  #
  # THE PAIR THAT MAKES THE GRANT MEAN SOMETHING. Every granted path is the
  # wrapper byte for byte, and no tenant script carries a grant of its own. A
  # grant on the script instead of the wrapper would run with no hash check and
  # write no row, and from the outside the two look identical.
  #
  # THE READ-BACK IS AGAINST THE PINNED NUMBER, not against the template this run
  # just copied from. Comparing a copy to its own source can only ever catch a
  # copy that failed, and the sentence it printed told the firm something much
  # stronger: that every granted path is the wrapper this release ships.
  local n bad_wrapper="" bad_direct=""
  for n in $granted; do
    [ "$(sha256sum "${TENANT_DOOR_ROOT}/${n}" 2>/dev/null | cut -d' ' -f1 || true)" = "$WRAPPER_SHA256" ] \
      || bad_wrapper="$bad_wrapper ${n}"
    grep -qF "NOPASSWD: ${TENANT_DOOR_ROOT}/${n}.script" "$TENANT_SUDOERS" 2>/dev/null && bad_direct="$bad_direct ${n}"
  done
  if [ -n "$granted" ]; then
    [ -z "$bad_wrapper" ] && ok "every granted path is the wrapper this release ships, byte for byte" \
                          || bad "granted path(s) that are not the wrapper:${bad_wrapper}"
    [ -z "$bad_direct" ]  && ok "no tenant script carries a grant of its own, so nothing reaches one except through its wrapper" \
                          || bad "tenant script(s) granted directly:${bad_direct}"
  fi
}

# ---------------------------------------------------------------- phase 19

# WIDE MODE, AND THE ONE FILE IT OWNS.
#
# The setting is the truth and this drop-in is derived from it, which is what
# makes the switch idempotent in both directions. On lays one fixed path; off
# removes that same path. There is no second spelling for either state, so no
# run can leave a grant behind under a name the next run does not look for.
#
# WHAT IT GRANTS, AND WHY IT IS NOT NARROWER. Every member of the members group,
# any command, no password. A narrower grant would be a list of the repairs
# somebody thought of in advance, and the whole point of the ruling is that an
# agent on one of these boxes can repair a wall nobody predicted. A list that
# has to be edited to cover the next wall is the wall.
#
# THE CONTROL PHASE 8 RUNS IS NOT SUSPENDED BY THIS. With wide mode on, exactly
# ONE sudoers file may name the members group and it is this one. Every other
# file naming it is still a failure, so a hand-written grant somebody left in a
# second file is still found, and wide mode never becomes a blanket excuse.
phase_19_wide_mode() {
  head1 19 "wide mode: whether every member holds passwordless root here"

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$WIDE_MODE" = "on" ]; then
      say "  would lay ${WIDE_SUDOERS} 0440 root:root granting %${MEMBERS_GROUP} NOPASSWD:ALL, after visudo -c passes on it"
    else
      say "  would remove ${WIDE_SUDOERS} if this claw carries one"
    fi
    return 0
  fi

  # ---- off: the file goes, and its absence is the end state ----
  #
  # NO GROUP CHECK ON THIS LEG. Removing a grant must work on a claw whose
  # members group somebody has already taken away, which is exactly the claw
  # where a leftover grant would be most surprising.
  if [ "$WIDE_MODE" != "on" ]; then
    if [ -e "$WIDE_SUDOERS" ]; then
      rm -f "$WIDE_SUDOERS"
      warn "wide mode is off and this claw was carrying ${WIDE_SUDOERS}. It has been removed, so no member of ${MEMBERS_GROUP} holds passwordless root here any more."
    else
      ok "wide mode is off and ${WIDE_SUDOERS} is absent, so this group carries no grant"
    fi
    check "${WIDE_SUDOERS} is absent" bash -c "[ ! -e '$WIDE_SUDOERS' ]"
    return 0
  fi

  # ---- on ----
  #
  # A GRANT ONTO A GROUP THAT DOES NOT EXIST IS A GRANT ONTO NOBODY, and sudo
  # says nothing about it: `visudo -c` parses the syntax and resolves no names.
  # So the group is read here rather than assumed, and its absence is a refusal
  # instead of a file that looks installed and opens for no one.
  if ! getent group "$MEMBERS_GROUP" >/dev/null 2>&1; then
    bad "wide mode is on and there is no ${MEMBERS_GROUP} group on this claw, so the grant would name nobody -- phase 8 makes that group"
    return 0
  fi

  local want; want="$(mktemp)"
  cat > "$want" <<WIDEEOF
# Managed by provision-claw.sh. Do not edit on the claw.
#
# WIDE MODE IS ON HERE. Every member of ${MEMBERS_GROUP} holds passwordless root
# on this claw, so an agent in a member's own session can repair the machine it
# is working on without waiting for a person.
#
# This is for the current early set of claws only. It must be off before this
# plane reaches any box beyond them, and the shipped default is off.
#
# THIS FILE IS DERIVED FROM A SETTING, and the setting is WIDE_MODE in
# ${CONF}. Deleting this by hand closes the grant until the
# next provisioning run, which puts it back. Closing it for good is a run with
# --wide-mode off.
%${MEMBERS_GROUP} ALL=(ALL) NOPASSWD: ALL
WIDEEOF

  # THE PARSE HAPPENS WHILE NOTHING HAS BEEN LAID. A malformed file under
  # /etc/sudoers.d breaks sudo for every caller on the claw at once, including
  # whoever holds the only door out. So the temporary file is judged first, and
  # a failure leaves this claw's grant exactly as the last run left it.
  if ! visudo -cf "$want" >/dev/null 2>&1; then
    bad "the wide-mode grant FAILED visudo -- NOT installed, and this claw's wide-mode grant is as the last run left it"
    visudo -cf "$want" 2>&1 | sed 's/^/    /' >&2 || true
    rm -f "$want"
    return 0
  fi
  ok "the wide-mode grant parses under visudo before anything is laid"

  # THREE STATES, THREE SENTENCES, which is the reading Q62 requires. Without it
  # a run that adopted a claw somebody had already opened by hand and a run that
  # rewrote one somebody had opened DIFFERENTLY print the same words, and the
  # operator who has to know which cannot tell.
  local before_grant="" want_grant
  want_grant="$(sudoers_grant_lines "$want")"
  if [ -e "$WIDE_SUDOERS" ]; then
    before_grant="$(sudoers_grant_lines "$WIDE_SUDOERS")"
  fi

  if [ ! -e "$WIDE_SUDOERS" ]; then
    install -m 0440 -o root -g root "$want" "$WIDE_SUDOERS"
    say "  ${WIDE_SUDOERS} created: every member of ${MEMBERS_GROUP} now holds passwordless root here"
  elif [ "$before_grant" = "$want_grant" ]; then
    # ADOPTED, AND ITS BYTES ARE NOT TOUCHED. Somebody opened this claw by hand
    # and wrote the same grant. Rewriting it would change nothing about what the
    # claw permits and would destroy whatever they wrote around it.
    say "  ${WIDE_SUDOERS} already grants exactly this and was adopted unchanged"
  else
    install -m 0440 -o root -g root "$want" "$WIDE_SUDOERS"
    warn "${WIDE_SUDOERS} carried a DIFFERENT grant and has been converged. What it held: $(printf '%s' "$before_grant" | tr '\n' '; ')"
  fi
  rm -f "$want"

  # The mode and the owner converge on every leg, adoption included. A file
  # anybody but root can write is a file anybody but root can widen, and a
  # hand-placed grant is exactly the one likely to have been left at 0644.
  chmod 0440 "$WIDE_SUDOERS"
  chown root:root "$WIDE_SUDOERS"

  check "${WIDE_SUDOERS} is 0440 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$WIDE_SUDOERS')\" = '440 root:root' ]"
  check "the installed file carries the grant this run meant" \
    bash -c "grep -qxF '%${MEMBERS_GROUP} ALL=(ALL) NOPASSWD: ALL' '$WIDE_SUDOERS'"
  check "the installed file parses under visudo" visudo -cf "$WIDE_SUDOERS"

  # A drop-in is inert unless sudoers includes the directory. The admin door
  # reads this too, and both read it rather than assuming it: a claw is not a
  # claim.
  local sudoers_text; sudoers_text="$(cat "$SUDOERS_MAIN" 2>/dev/null || true)"
  case "$sudoers_text" in
    *"includedir ${SUDOERS_DIR}"*) ok "sudoers includes ${SUDOERS_DIR}, so this grant is live rather than written and inert" ;;
    *) bad "sudoers carries no includedir for ${SUDOERS_DIR} -- the wide-mode grant is written and inert" ;;
  esac

  human "wide mode is ON here. It is for the current early set of claws only, and it must be off before this plane reaches any box beyond them."
}


# ---------------------------------------------------------------- phase 20
#
# THE MEMORY FLOOR. Swap, the swappiness that decides how it is used, and the
# guard that acts before the kernel's own killer does.
#
# WHY IT IS AT THE END RATHER THAN BESIDE THE BASE. It belongs with phase 3 by
# subject and it is appended by convention: every phase since 15 was appended,
# the numbers are positional, and renumbering would silently change what
# `--only 12` means on every claw and in every runbook that names a phase.
#
# THE SIZING RULE, and it is one sentence: swap is the size of RAM, never below
# 2 GiB, never above 8 GiB. RAM-sized because the cushion has to hold the working
# set of the thing that ran away. The floor because a small box is the one that
# fills first. The cap because swap is a cushion and not a second memory: past
# 8 GiB a box that needs it is already thrashing, and the disk it costs is disk
# the work needed.
#
# THE REFUSAL. The swapfile may take at most half of what is free on its
# filesystem. Below that the phase refuses and carves nothing: a box whose swap
# would eat more than half its remaining disk has a disk problem, and a swapfile
# that fills the filesystem takes the claw down a second way. Carving a smaller
# one silently would leave a claw carrying a cushion nobody sized and nothing
# recording that it is short.
#
# ADOPTION, NOT REVERSION. Active swap is adopted whatever its size, and the size
# is reported against the plan. Resizing means swapoff, which on a box that is
# already under pressure is the one act that could finish it off. A claw whose
# swap somebody sized deliberately keeps it.

# The three decisions, as functions, because the phase itself cannot be
# rehearsed: it calls mkswap and swapon, and a rehearsal that ran them would
# change the box it was rehearsing on. The controls in
# _workpapers/w129-memory-rail/ drive these with planted numbers instead.
swap_want_bytes() {
  local mem_total_kb="$1" want floor cap
  floor=$(( 2 * 1024 * 1024 * 1024 ))
  cap=$((   8 * 1024 * 1024 * 1024 ))
  want=$(( mem_total_kb * 1024 ))
  [ "$want" -lt "$floor" ] && want="$floor"
  [ "$want" -gt "$cap" ]   && want="$cap"
  printf '%s' "$want"
}

swap_verdict() {
  local want="$1" free="$2"
  if [ "$free" -lt $(( want * 2 )) ]; then printf 'refuse'; else printf 'ok'; fi
}

# What is on right now, in bytes, summed. The KERNEL is asked rather than the
# fstab, because the fstab says what should be on and only this says what is.
swap_active_bytes() {
  { "$SWAPON_CMD" --show=SIZE --bytes --noheadings 2>/dev/null || true; } \
    | awk '{t+=$1} END {print t+0}'
}

# One line in the fstab, added once. Matched on the path rather than on the whole
# line, so a line somebody edited is left alone rather than doubled.
swap_fstab_ensure() {
  local path="$1"
  if grep -qE "^[[:space:]]*${path}[[:space:]]" "$FSTAB" 2>/dev/null; then
    printf 'present'; return 0
  fi
  printf '%s none swap sw 0 0\n' "$path" >> "$FSTAB" || return 1
  printf 'added'
}

phase_20_memory_floor() {
  head1 20 "the memory floor: swap, swappiness, the OOM guard"

  local mem_kb want free verdict
  mem_kb="$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]\+\) kB$/\1/p' /proc/meminfo | head -1)"
  case "${mem_kb:-0}" in
    ''|0|*[!0-9]*)
      bad "cannot read MemTotal from /proc/meminfo, so no swap size could be derived"
      return 0 ;;
  esac
  want="$(swap_want_bytes "$mem_kb")"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would ensure $(( want / 1024 / 1024 ))MB of swap at ${SWAPFILE}, record it in ${FSTAB}, write ${SYSCTL_SWAP}, and configure earlyoom"
    return 0
  fi

  # ---- swap ----
  #
  # ACTIVE SWAP IS ADOPTED. `swapon --show` is read rather than the fstab,
  # because the fstab says what should be on and the kernel says what is.
  local active_bytes
  active_bytes="$(swap_active_bytes)"
  if [ "${active_bytes:-0}" -gt 0 ]; then
    ok "swap is already active: $(( active_bytes / 1024 / 1024 ))MB, against a plan of $(( want / 1024 / 1024 ))MB. Adopted as it is"
    if [ "$active_bytes" -lt $(( want / 2 )) ]; then
      warn "this claw's swap is less than half the plan. Resizing means swapoff, which is the one act that could finish off a box already under pressure, so nothing here changes it"
    fi
  else
    free="$( { df -B1 --output=avail "$(dirname "$SWAPFILE")" 2>/dev/null || true; } | tail -1 | tr -d ' ')"
    case "${free:-}" in
      ''|*[!0-9]*)
        bad "cannot read free space on $(dirname "$SWAPFILE"), so no swapfile was made"
        return 0 ;;
    esac
    verdict="$(swap_verdict "$want" "$free")"
    if [ "$verdict" = refuse ]; then
      # A FAILED CHECK, not a note. A release ride stops here, and it should: a
      # claw this short of disk is a claw somebody has to look at.
      bad "REFUSED to make a $(( want / 1024 / 1024 ))MB swapfile: only $(( free / 1024 / 1024 ))MB is free on $(dirname "$SWAPFILE"), and a swapfile may take at most half of what is free. Nothing was carved, and no smaller one was carved either"
      return 0
    fi
    if fallocate -l "$want" "$SWAPFILE" 2>/dev/null \
       || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( want / 1024 / 1024 )) status=none 2>/dev/null; then
      chmod 0600 "$SWAPFILE"
      chown root:root "$SWAPFILE"
      if mkswap "$SWAPFILE" >/dev/null 2>&1 && swapon "$SWAPFILE" 2>/dev/null; then
        ok "swapfile made and active: $(( want / 1024 / 1024 ))MB at ${SWAPFILE}"
      else
        bad "the swapfile at ${SWAPFILE} was written and could not be formatted or turned on"
      fi
    else
      bad "could not write a $(( want / 1024 / 1024 ))MB swapfile at ${SWAPFILE}"
    fi
  fi

  local fstab_verdict; fstab_verdict="$(swap_fstab_ensure "$SWAPFILE" || printf 'failed')"
  case "$fstab_verdict" in
    added)   ok "${SWAPFILE} recorded in ${FSTAB}, so it survives a reboot" ;;
    present) ok "${SWAPFILE} is already recorded in ${FSTAB}" ;;
    *)       bad "could not record ${SWAPFILE} in ${FSTAB}: this claw's swap does not survive a reboot" ;;
  esac
  check "swap is on right now" bash -c '[ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -gt 0 ]'

  # ---- swappiness ----
  cat > "$SYSCTL_SWAP" <<SYSCTLEOF
# How readily this claw uses its swap. Managed by provision-claw.sh.
#
# The default is 60, which suits a machine whose work is throughput. A claw's
# work is people's sessions, and paging one of those out to make room for cache
# is felt. Ten keeps cold pages of a long-idle session out of the way and leaves
# the working set in memory. Zero is not the answer: it tells the kernel never to
# swap a page it could keep, which turns the cushion back into the pressure it
# was added to absorb.
vm.swappiness = ${SWAPPINESS}
SYSCTLEOF
  chmod 0644 "$SYSCTL_SWAP"; chown root:root "$SYSCTL_SWAP"
  sysctl -p "$SYSCTL_SWAP" >/dev/null 2>&1 || true
  check "vm.swappiness is ${SWAPPINESS} right now" \
    bash -c "[ \"\$(cat /proc/sys/vm/swappiness 2>/dev/null)\" = '${SWAPPINESS}' ]"

  # ---- the OOM guard ----
  #
  # earlyoom, and systemd-oomd is the one that was rejected. Neither ships on
  # this distribution, so "needs no new package" decides nothing and the
  # behaviour does.
  #
  # systemd-oomd acts on a whole cgroup. On a claw every session one person holds
  # lives under that person's own slice, so a runaway in one session would take
  # every other session that person has with it, including the tmux server the
  # work is sitting in. Its swap trigger also waits until swap is nearly full,
  # which is after the thrashing has started.
  #
  # earlyoom watches available memory and free swap and terminates the single
  # process with the worst score. One process, chosen because it is the largest,
  # which on a claw is the thing that ran away. That is what "act before the box
  # stops answering ssh" means here.
  #
  # ITS THRESHOLDS ARE THE PACKAGE'S OWN and they are deliberately BELOW the
  # alarm's line. The alarm posts at 15% available so a person hears first;
  # earlyoom is the last thing between that and the kernel's own killer.
  if command -v earlyoom >/dev/null 2>&1; then
    systemctl enable --now earlyoom >/dev/null 2>&1 || true
    check "the OOM guard is running" systemctl is-active --quiet earlyoom
    check "the OOM guard starts at boot" systemctl is-enabled --quiet earlyoom
  else
    bad "earlyoom is not installed, so nothing acts between memory filling and the kernel's own killer, which arrives after the box has stopped answering"
  fi
}

# ---------------------------------------------------------------- phase 21

phase_21_memory_rail() {
  head1 21 "the memory alarm and the dead-man ping"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would install commonclaw-memory-check.sh, seed ${MEMORY_CONF} and ${MEMORY_ENV}, and install the unit and timer"
    return 0
  fi

  install -m 0755 "${SCRIPT_DIR}/commonclaw-memory-check.sh" /usr/local/sbin/commonclaw-memory-check.sh
  install -d -m 0755 -o root -g root "$ETC_ROOT"

  # SEEDED THE WAY updater.conf IS NOT. These two carry thresholds and a
  # reference, which are a decision the release makes rather than state the claw
  # accumulates, so a re-run rewrites them and a changed line reaches the claw.
  # Writing a reference is safe; a reference is not a value.
  cat > "$MEMORY_CONF" <<MEMEOF
# When this claw says out loud that it is running out of memory.
# Written by provision-claw.sh. NO SECRETS HERE: the heartbeat URL is a
# credential and none rests on this claw.
#
# ENABLED         yes  the beat runs, posts through commonclaw-notify.sh, and
#                      pings the dead-man check.
#                 no   the beat exits quietly. A deliberate silence.
#
# AVAILABLE_PCT   post when less than this share of memory is available. Fifteen
#                 leaves room to act: the OOM guard starts killing below ten.
#
# SWAP_USED_PCT   post when more than this share of swap is in use. Swap filling
#                 is what turns a busy box into an unreachable one.
#
# DEDUPE_HOURS    how long one crossed line stays quiet. Six, not the seat
#                 check's twenty: memory pressure is something a person acts on
#                 now, and a box still under pressure six hours later has earned
#                 a second line. A NEW crossing breaks through the same beat it
#                 appears, because the key carries which line was crossed.
ENABLED="yes"
AVAILABLE_PCT=15
SWAP_USED_PCT=50
DEDUPE_HOURS=6
MEMEOF
  chmod 0644 "$MEMORY_CONF"; chown root:root "$MEMORY_CONF"

  cat > "$MEMORY_ENV" <<MEMENVEOF
# Manager references, never values. Resolved at invocation by the manager.
# Item names follow the naming table in reference/claw-conventions.md.
#
# The heartbeat check is created by a person, one per claw, and its URL put in
# this claw's machine vault. Until that happens this reference resolves to
# nothing, the ping is skipped quietly, and the on-box alarm still runs.
COMMONCLAW_HEARTBEAT_URL=op://${VAULT}/commonclaw-heartbeat-${TARGET_HOSTNAME}/credential
MEMENVEOF
  chmod 0644 "$MEMORY_ENV"; chown root:root "$MEMORY_ENV"

  install -m 0644 -o root -g root "${TEMPLATE_DIR}/commonclaw-memory-check.service" \
    /etc/systemd/system/commonclaw-memory-check.service
  install -m 0644 -o root -g root "${TEMPLATE_DIR}/commonclaw-memory-check.timer" \
    /etc/systemd/system/commonclaw-memory-check.timer
  systemctl daemon-reload

  check "memory check installed and executable" test -x /usr/local/sbin/commonclaw-memory-check.sh
  check "memory check parses" bash -n /usr/local/sbin/commonclaw-memory-check.sh
  check "memory conf is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$MEMORY_CONF')\" = '644 root:root' ]"
  check "memory env holds a reference, not a value" \
    bash -c "grep -q '^COMMONCLAW_HEARTBEAT_URL=op://' '$MEMORY_ENV'"
  check "memory check service registered" systemctl cat commonclaw-memory-check.service
  check "memory check timer registered"   systemctl cat commonclaw-memory-check.timer

  # ---- the phase control, and it has to be able to FAIL ----
  #
  # Two planted thresholds, two verdicts that must differ. At 100% available the
  # reading is always below the line, so a post is unavoidable; at 0% it is
  # always above, so a post is impossible. A control that only asserted the first
  # would pass just as happily against a check that posts on every run.
  #
  # The notifier is a recording stub and the conf is a fixture, so this control
  # reaches no channel and does not touch the claw's own dedupe state.
  local ctl stub_log rc_hot rc_cold posts_hot posts_cold
  ctl="$(mktemp -d)"
  cat > "${ctl}/stub" <<'STUBEOF'
#!/bin/bash
printf 'POST %s\n' "$*" >> "$STUB_LOG"
exit 0
STUBEOF
  chmod 0755 "${ctl}/stub"
  stub_log="${ctl}/posts"; : > "$stub_log"

  printf 'ENABLED="yes"\nAVAILABLE_PCT=100\nSWAP_USED_PCT=0\nDEDUPE_HOURS=6\n' > "${ctl}/hot.conf"
  printf 'ENABLED="yes"\nAVAILABLE_PCT=0\nSWAP_USED_PCT=100\nDEDUPE_HOURS=6\n' > "${ctl}/cold.conf"

  rc_hot=0
  STUB_LOG="$stub_log" MEMORY_CONF="${ctl}/hot.conf" MEMORY_ENV="${ctl}/absent.env" \
    NOTIFIER="${ctl}/stub" PROVISION_CONF="$CONF" \
    /usr/local/sbin/commonclaw-memory-check.sh >/dev/null 2>&1 || rc_hot=$?
  # grep -c PRINTS 0 and EXITS 1 when it matches nothing, so a `|| printf 0`
  # fallback would append a second zero and every integer test below would read
  # a two-line string.
  posts_hot="$(grep -c '^POST' "$stub_log" 2>/dev/null)" || posts_hot=0

  : > "$stub_log"
  rc_cold=0
  STUB_LOG="$stub_log" MEMORY_CONF="${ctl}/cold.conf" MEMORY_ENV="${ctl}/absent.env" \
    NOTIFIER="${ctl}/stub" PROVISION_CONF="$CONF" \
    /usr/local/sbin/commonclaw-memory-check.sh >/dev/null 2>&1 || rc_cold=$?
  posts_cold="$(grep -c '^POST' "$stub_log" 2>/dev/null)" || posts_cold=0

  if [ "$posts_hot" -ge 1 ]; then
    ok "the memory check posts when the line is crossed (threshold planted at 100%, exit ${rc_hot})"
  else
    bad "the memory check posted nothing with the threshold planted at 100%, so it cannot report pressure at all"
  fi
  if [ "$posts_cold" -eq 0 ]; then
    ok "the memory check stays silent when the line is not crossed (threshold planted at 0%, exit ${rc_cold})"
  else
    bad "the memory check posted with the threshold planted at 0%, so it posts regardless of what it read"
  fi

  # An absent conf is the quiet state and must not read as a fault.
  local rc_quiet=0
  STUB_LOG="$stub_log" MEMORY_CONF="${ctl}/nothing.conf" NOTIFIER="${ctl}/stub" \
    /usr/local/sbin/commonclaw-memory-check.sh >/dev/null 2>&1 || rc_quiet=$?
  if [ "$rc_quiet" -eq 3 ]; then
    ok "the memory check exits 3 on a claw with no memory conf, which is the quiet state"
  else
    bad "an absent memory conf gave exit ${rc_quiet}, not 3, so the quiet state is not quiet"
  fi
  rm -rf "$ctl"

  # THE CLASS THIS ALARM POSTS UNDER IS PROVEN IN PHASE 22, beside the notifier
  # that owns the class table. It sat here while nothing installed the notifier,
  # which meant it measured an absent program on a fresh claw: six identical
  # "command not found" strings read as six identical renders and failed a run
  # that had nothing wrong with it. The control moved to the phase that puts the
  # program on the box.

  # ENABLED, unlike the backup and update timers. Those are held back because
  # enabling them commits a claw to something: a repository it may not have, or a
  # release it may not want. This one reads two numbers and, at most, makes one
  # outbound request that is skipped whenever nothing is wired. A rail installed
  # disabled is the silence this whole unit exists to end.
  systemctl enable --now commonclaw-memory-check.timer >/dev/null 2>&1 || true
  check "memory check timer is active" systemctl is-active --quiet commonclaw-memory-check.timer

  if grep -q "^COMMONCLAW_HEARTBEAT_URL=op://" "$MEMORY_ENV"; then
    human "create one heartbeat check per claw at a hosted service, put its URL into ${VAULT} as an API Credential item named commonclaw-heartbeat-${TARGET_HOSTNAME}, and give the check a grace period of ten minutes. Until then this claw's alarm runs and its dead-man ping is skipped"
  fi
}


# ---------------------------------------------------------------- phase 22

# APPENDED, NOT INSERTED BESIDE THE PRODUCERS IT SERVES. Phase numbers here are
# positional and every phase since 15 was appended; renumbering would silently
# change what `--only 12` means on every claw and in every runbook that names a
# phase. So the delivery path lands after the producers that call it, and the
# ordering costs nothing: a producer whose notifier is absent degrades to the
# journal by design, and the phase that installs it runs in the same pass.
phase_22_notification_rail() {
  head1 22 "the notification rail"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would install commonclaw-notify.sh to ${NOTIFY_BIN}, seed ${NOTIFY_CONF} and ${NOTIFY_ENV},"
    say "  and prove every message class renders differently"
    return 0
  fi

  install -d -m 0755 -o root -g root "$ETC_ROOT"
  install -d -m 0755 -o root -g root /var/lib/commonclaw/notify

  install_adopting "${SCRIPT_DIR}/commonclaw-notify.sh" "$NOTIFY_BIN" "the notifier"

  # SEEDED THE WAY THE MEMORY RAIL'S TWO FILES ARE. They carry a decision the
  # release makes and a manager reference, not state the claw accumulates, so the
  # end state is this release's and a changed line reaches the claw. Writing a
  # reference is safe; a reference is not a value.
  #
  # WRITTEN THROUGH install_adopting rather than with a plain `cat >`, so a claw
  # carrying a hand-placed copy learns which of the two it got. wagmi-claw has
  # carried both of these files since August and its copies differ from this
  # release; a silent rewrite would drop whatever somebody had added to them with
  # nothing in the run's output saying so.
  local seed; seed="$(mktemp)"
  cat > "$seed" <<'NOTIFYCONFEOF'
# How this claw delivers its own findings. Written by provision-claw.sh.
# NO SECRETS HERE. The webhook is a credential and none rests on this claw.
#
# ENABLED   yes  findings go to the channel this claw's webhook posts into.
#           no   findings stay in the journal. A deliberate silence, and the
#                producers see a clean exit rather than a delivery failure.
#
# WEBHOOK_CMD is the pluggable resolution path, the same shape as
# FETCH_TOKEN_CMD in updater.conf: a command whose stdout is the URL. Empty
# means the manager reference in notify.env is used instead.
ENABLED="yes"
WEBHOOK_CMD=""
NOTIFYCONFEOF
  install_adopting "$seed" "$NOTIFY_CONF" "the notify config" 0644

  cat > "$seed" <<NOTIFYENVEOF
# Manager references, never values. Resolved at invocation by the manager.
# Item names follow the naming table in reference/claw-conventions.md.
#
# One webhook per claw, never one for the fleet. A shared URL means a leak from
# any claw posts as every claw, and it carries no name saying which machine it
# belongs to.
COMMONCLAW_SLACK_WEBHOOK=op://${VAULT}/commonclaw-slack-webhook-${TARGET_HOSTNAME}/credential
NOTIFYENVEOF
  install_adopting "$seed" "$NOTIFY_ENV" "the notify env file" 0644
  rm -f "$seed"

  check "the notifier is installed and executable" test -x "$NOTIFY_BIN"
  check "the notifier parses" bash -n "$NOTIFY_BIN"
  check "the notify config is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$NOTIFY_CONF')\" = '644 root:root' ]"
  check "the notify env file holds a reference, not a value" \
    bash -c "grep -q '^COMMONCLAW_SLACK_WEBHOOK=op://' '$NOTIFY_ENV'"
  # The notifier refuses a conf carrying a literal URL before it sources the
  # file. This asserts the file this run WROTE carries none, which is the other
  # half: a refusal nothing can trigger proves nothing about what was written.
  if grep -q '^[[:space:]]*WEBHOOK_URL=' "$NOTIFY_CONF"; then
    bad "${NOTIFY_CONF} carries a literal WEBHOOK_URL. That is a credential at rest inside the backed-up config root: rotate it, then remove the line"
  else
    ok "the notify config carries no literal webhook URL"
  fi

  # ---- the class control, and it has to be able to FAIL ----
  #
  # Every class renders, and the renders differ. A table read for its title and
  # ignored for everything else renders every row identically, and that is the
  # defect a per-class control is for.
  #
  # NOTIFY_NOW pins the clock. Without it the payload carries a wall-clock
  # timestamp, so two renders of the same table differ whenever a second ticks
  # between them, and the control ends up reporting on the clock.
  #
  # The state directory is a fixture, so this control never touches the claw's
  # own dedupe stamps, and --dry-run reaches no channel.
  local ctl; ctl="$(mktemp -d)"
  local p prev="" out differed=1
  for p in seat-expiry seat-fault backup-health update-health memory-pressure claw-note; do
    out="$(NOTIFY_NOW=FIXED NOTIFY_STATE_DIR="${ctl}/state" \
      "$NOTIFY_BIN" --dry-run --class "$p" --summary "provisioning control" 2>&1)" || true
    [ -n "$prev" ] && [ "$out" = "$prev" ] && differed=0
    prev="$out"
  done
  if [ "$differed" -eq 1 ]; then
    ok "every message class renders differently, so the class table is being read"
  else
    bad "two message classes render identically, so the class table is not being read"
  fi

  # THE OTHER DIRECTION. The same class six times must come out identical, or
  # the loop above is measuring the clock rather than the table, and a control
  # whose failing branch is unreachable is decoration.
  local same=1
  prev=""
  for p in claw-note claw-note claw-note claw-note claw-note claw-note; do
    out="$(NOTIFY_NOW=FIXED NOTIFY_STATE_DIR="${ctl}/state" \
      "$NOTIFY_BIN" --dry-run --class "$p" --summary "provisioning control" 2>&1)" || true
    [ -n "$prev" ] && [ "$out" != "$prev" ] && same=0
    prev="$out"
  done
  if [ "$same" -eq 1 ]; then
    ok "known-answer control: one class rendered six times comes out identical, so the comparison above compares renders"
  else
    bad "one class rendered six times gave differing renders, so the divergence control measures something other than the class table"
  fi

  # THE LOOP ABOVE CANNOT FAIL ON THE AXIS ITS OWN COMMENT NAMES, and saying so
  # here is cheaper than a claw discovering it. The payload carries the class
  # SLUG in its context block, so two renders differ whatever the title table
  # does. What that loop really catches is a notifier that is absent or broken,
  # which is the failure it was written after, and it is kept for that.
  #
  # The claim that each row is read for its TITLE needs its own control, and this
  # is it: six classes, six distinct titles, pulled out of the rendered text.
  # `|| true` ON THE ASSIGNMENT, and it is the whole reason this phase can run
  # on a claw nobody has wired yet. The notifier exits 3 when no webhook
  # resolves, which this phase treats as a supported state eleven lines below.
  # Under `set -euo pipefail` that 3 leaves the pipeline, the loop, the command
  # substitution and the assignment in turn, and kills the run. The two controls
  # above carry `|| true` on their own capture for the same reason and survive
  # the identical exit. This one did not, so the first claw on the rail with no
  # channel wired aborted its whole apply here, at phase 22, eleven lines above
  # the sentence that tells the firm how to wire one. Measured on a tenant claw
  # on 2026-09-02. [O 2026-09-02]
  #
  # The exit code is all that is lost. A dry run prints its rendered payload
  # before it exits 3, so the titles are captured either way and this control
  # still measures the table on a claw with no webhook.
  local titles distinct
  titles="$(for p in seat-expiry seat-fault backup-health update-health memory-pressure claw-note; do
    NOTIFY_NOW=FIXED NOTIFY_STATE_DIR="${ctl}/state" \
      "$NOTIFY_BIN" --dry-run --class "$p" --summary "provisioning control" 2>/dev/null \
      | sed -n 's/^  "text": "[^·]*· \(.*\) · .*/\1/p'
  done)" || true
  # grep -c PRINTS 0 and EXITS 1 on no match, so the fallback is an assignment
  # rather than an appended second line.
  distinct="$(printf '%s\n' "$titles" | sort -u | grep -c . )" || distinct=0
  if [ "$distinct" -eq 6 ]; then
    ok "the six classes render six distinct titles, so the class table is read row by row"
  elif [ "$distinct" -eq 0 ]; then
    # Zero is a different finding from two-sharing-a-heading, and naming it as
    # the sharing case sends a reader to the class table when the notifier
    # printed nothing at all.
    bad "the six classes produced no renders to compare, so nothing was measured about the class table: the notifier printed no payload this control could read"
  else
    bad "the classes render ${distinct} distinct title(s), not six: two of them share a heading and a finding lands under the wrong topic"
  fi

  # A class nobody put in the table is a usage error, not a generic heading.
  local typo_rc=0
  NOTIFY_NOW=FIXED NOTIFY_STATE_DIR="${ctl}/state" \
    "$NOTIFY_BIN" --dry-run --class not-a-class --summary "provisioning control" >/dev/null 2>&1 || typo_rc=$?
  if [ "$typo_rc" -eq 2 ]; then
    ok "an unknown class is refused as a usage error rather than posted under a generic heading"
  else
    bad "an unknown class gave exit ${typo_rc}, not 2"
  fi
  rm -rf "$ctl"

  # Whether anything ARRIVES is a person's step and it is the last one. A dry run
  # that resolved a webhook would still prove nothing about the channel.
  local resolve_rc=0
  "$NOTIFY_BIN" --dry-run --class claw-note --summary "provisioning control" >/dev/null 2>&1 || resolve_rc=$?
  case "$resolve_rc" in
    0) ok "the webhook resolves on this claw, so the rail is wired end to end but for the arrival" ;;
    3) warn "no webhook resolves on this claw yet: the producers exit cleanly and their findings stay in the journal"
       human "put this claw's incoming-webhook URL into ${VAULT} as an API Credential item named commonclaw-slack-webhook-${TARGET_HOSTNAME}, then post one message and look at the channel. Until then every check here reaches the journal and nobody else" ;;
    *) warn "the notifier's dry run exited ${resolve_rc}, which is neither delivered nor unwired -- read its journal line" ;;
  esac
}

# ---------------------------------------------------------------- phase 23

phase_23_stall_check() {
  head1 23 "the stall check"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would install commonclaw-stall-check.sh to ${STALL_CHECK}, seed ${STALL_CONF},"
    say "  install the unit and timer, and enable the timer"
    return 0
  fi

  install -d -m 0755 -o root -g root "$ETC_ROOT"

  install_adopting "${SCRIPT_DIR}/commonclaw-stall-check.sh" "$STALL_CHECK" "the stall check"
  install_adopting "${TEMPLATE_DIR}/commonclaw-stall-check.conf" "$STALL_CONF" "the stall-check config" 0644
  install_adopting "${TEMPLATE_DIR}/commonclaw-stall-check.service" \
    /etc/systemd/system/commonclaw-stall-check.service "the stall-check unit" 0644
  install_adopting "${TEMPLATE_DIR}/commonclaw-stall-check.timer" \
    /etc/systemd/system/commonclaw-stall-check.timer "the stall-check timer" 0644
  systemctl daemon-reload

  check "the stall check is installed and executable" test -x "$STALL_CHECK"
  check "the stall check parses" bash -n "$STALL_CHECK"
  check "the stall-check config is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$STALL_CONF')\" = '644 root:root' ]"
  check "the stall-check service registered" systemctl cat commonclaw-stall-check.service
  check "the stall-check timer registered"   systemctl cat commonclaw-stall-check.timer
  check "systemd accepts both units as written" \
    systemd-analyze verify /etc/systemd/system/commonclaw-stall-check.service

  # ---- the phase control, and it has to be able to FAIL ----
  #
  # Two bus fixtures, two verdicts that must differ. One holds an orchestrator
  # handle whose oldest unread message is older than the threshold; the other
  # holds the same handle with the same message already read. A control that
  # only asserted the first would pass just as happily against a check that
  # reports a stall on every run.
  #
  # STALL_NOW_EPOCH pins the clock, so the ages are the fixture's rather than
  # the hour the ride happened to run in. The conf and the bus are fixtures and
  # --state posts nothing, so this control reaches no channel and touches
  # neither the claw's own buses nor its dedupe stamps.
  local ctl bus found_hot found_cold
  ctl="$(mktemp -d)"
  bus="${ctl}/bus"
  install -d -m 0755 "${bus}/inbox" "${bus}/cursors"
  cat > "${bus}/handles.json" <<'HANDLEEOF'
{"control-orch":{"owner":"nobody","role":"orchestrator"},
 "control-worker":{"owner":"nobody","role":"worker"}}
HANDLEEOF
  printf '{"ts":"2026-01-01T00:00:00+00:00","from":"control-worker","subject":"x"}\n' \
    > "${bus}/inbox/control-orch.jsonl"
  # A worker handle with the same aged unread message. It must NOT be reported:
  # the rule is orchestrator handles, and a check that swept every handle would
  # post about every finished delegate on the claw.
  cp "${bus}/inbox/control-orch.jsonl" "${bus}/inbox/control-worker.jsonl"
  printf 'ENABLED="yes"\nTHRESHOLD_HOURS=3\nDEDUPE_HOURS=20\nBUS_DIRS="%s"\n' "$bus" > "${ctl}/stall.conf"

  found_hot="$(STALL_CONF="${ctl}/stall.conf" STALL_NOW_EPOCH=1800000000 \
    "$STALL_CHECK" --state 2>/dev/null || true)"
  # The same bus with the cursor past the message: read mail is not a stall.
  printf '1\n' > "${bus}/cursors/control-orch.cursor"
  found_cold="$(STALL_CONF="${ctl}/stall.conf" STALL_NOW_EPOCH=1800000000 \
    "$STALL_CHECK" --state 2>/dev/null || true)"

  case "$found_hot" in
    *control-orch*) ok "the stall check reports an orchestrator handle whose unread mail is past the threshold" ;;
    *) bad "the stall check found nothing against a fixture holding a three-year-old unread message, so it cannot report a stall at all" ;;
  esac
  case "$found_hot" in
    *control-worker*) bad "the stall check reported a WORKER handle, so it sweeps every handle and will post about every finished delegate on this claw" ;;
    *) ok "the stall check leaves worker handles alone, which is what keeps its first run from posting a page of finished delegates" ;;
  esac
  case "$found_cold" in
    *control-orch*) bad "the stall check reported a handle whose mail is READ, so it reports regardless of what it measured" ;;
    *) ok "the stall check stays silent when the mail has been read" ;;
  esac
  rm -rf "$ctl"

  # ENABLED, for the memory check's reason. The beat reads files already on this
  # box and posts at most one message a day per distinct stall. A rail installed
  # disabled is the silence this unit exists to end.
  systemctl enable --now commonclaw-stall-check.timer >/dev/null 2>&1 || true
  check "the stall-check timer is active" systemctl is-active --quiet commonclaw-stall-check.timer
}

# ---------------------------------------------------------------- phase 24

phase_24_wake_rail() {
  head1 24 "the wake rail and the orchestration settings"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would run install-bus-nudge.sh for ${#PEOPLE[@]} account(s) and write ${ORCHESTRATE_CONF_FILE}"
    return 0
  fi

  # ---- the wake rail ----
  #
  # The installer owns the whole act: the program, its adapters, the member doc,
  # the conf, the machine opt-in and one systemd instance per account. It is
  # called rather than reimplemented, because a second copy of that sequence
  # would drift from the door a claw-admin runs by hand.
  if [ "${#PEOPLE[@]}" -eq 0 ]; then
    warn "no people on this claw, so no wake-rail instance was stood. The program and the opt-in are stood by the installer only when it has an account to stand one for"
  elif [ ! -x "${SCRIPT_DIR}/install-bus-nudge.sh" ]; then
    bad "cannot stand the wake rail: ${SCRIPT_DIR}/install-bus-nudge.sh is missing or not executable"
  elif "${SCRIPT_DIR}/install-bus-nudge.sh" "${PEOPLE[@]}" >/dev/null; then
    ok "the wake rail is standing for ${#PEOPLE[@]} account(s)"
  else
    bad "install-bus-nudge.sh reported a failure -- a session on this claw learns about unread mail when it next happens to look"
  fi

  check "the nudge program is installed" test -x "${CLAW_BIN}/bus-nudge"
  check "the delivered sentence carries no interpolation but the bus directory" \
    "${CLAW_BIN}/bus-nudge" --law

  # ---- the orchestration settings ----
  #
  # TWO KINDS OF LINE IN ONE FILE, and the phase treats them differently.
  #
  # The bus path and the substrate are FACTS about this machine. Phase 16 lays
  # the shared bus and this file is where a session reads its path, so the run
  # asserts them: a claw whose bus moved and whose conf did not is a claw whose
  # delegates register on a bus their orchestrator is not reading.
  #
  # The model and the permissions flag are DECISIONS. They are seeded once and
  # whatever the claw carries afterwards is kept, so a release ride cannot flip a
  # firm back to the fleet default with nothing saying so. This is the seat
  # roster's law applied line by line rather than file by file, because the same
  # file holds both kinds.
  local cur_model="$DELEGATE_MODEL" cur_skip="$DELEGATE_SKIP_PERMISSIONS" kept=""
  if [ -r "$ORCHESTRATE_CONF_FILE" ]; then
    local v
    v="$(sed -n 's/^ORCHESTRATE_DELEGATE_MODEL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ORCHESTRATE_CONF_FILE" | tail -1)"
    [ -n "$v" ] && { cur_model="$v"; kept="the model"; }
    v="$(sed -n 's/^ORCHESTRATE_DELEGATE_SKIP_PERMISSIONS="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ORCHESTRATE_CONF_FILE" | tail -1)"
    [ -n "$v" ] && { cur_skip="$v"; kept="${kept:+${kept} and }the permissions flag"; }
  fi

  cat > "$ORCHESTRATE_CONF_FILE" <<ORCHEOF
# The orchestrate skill's settings for this machine. Written by
# provision-claw.sh. NO SECRETS HERE.
#
# WHY THIS FILE AND NOT THE SKILL'S OWN config.yaml. The skill reads the
# environment, then this file, then its shipped config.yaml. Under a managed
# install the skill folder is root-owned and replaced on every update, so a
# ruling written there is either refused or overwritten. This is the layer a
# machine's ruling survives in.
#
# The first two lines are facts about this claw and provisioning asserts them on
# every run. The last two are decisions: they are seeded once and whatever this
# claw carries afterwards is kept.
ORCHESTRATE_SHARED_BUS="${BUS_HOME}"
ORCHESTRATE_SUBSTRATE="claude"
ORCHESTRATE_DELEGATE_MODEL="${cur_model}"
ORCHESTRATE_DELEGATE_SKIP_PERMISSIONS="${cur_skip}"
ORCHEOF
  chmod 0644 "$ORCHESTRATE_CONF_FILE"; chown root:root "$ORCHESTRATE_CONF_FILE"
  [ -n "$kept" ] && say "  kept ${kept} this claw already recorded in ${ORCHESTRATE_CONF_FILE}"

  check "the orchestration config is 0644 root:root" \
    bash -c "[ \"\$(stat -c '%a %U:%G' '$ORCHESTRATE_CONF_FILE')\" = '644 root:root' ]"
  check "the orchestration config names the bus this claw actually carries" \
    bash -c "[ \"\$(sed -n 's/^ORCHESTRATE_SHARED_BUS=\"\\(.*\\)\"$/\\1/p' '$ORCHESTRATE_CONF_FILE')\" = '$BUS_HOME' ]"
  check "the shared bus the config names exists on this claw" test -d "$BUS_HOME"

  # A file every session reads has to be readable by every session.
  check "every member can read the orchestration config" \
    bash -c "[ \"\$(stat -c '%a' '$ORCHESTRATE_CONF_FILE' | cut -c3)\" != '0' ]"
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

# ABOVE THE PHASE GATE FOR THE SAME REASON. Phase 2 writes the setting into the
# config, phase 8 measures what the members group is allowed to carry, and phase
# 19 lays or removes the grant. All three need the same answer, so it is
# resolved once, before any of them, and `--only` cannot reach a phase that
# would have to guess.
wide_mode_resolve

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
if want_phase 17; then phase_17_runtimes;     fi
if want_phase 18; then phase_18_authority;    fi
if want_phase 19; then phase_19_wide_mode;   fi
if want_phase 20; then phase_20_memory_floor; fi
if want_phase 21; then phase_21_memory_rail;  fi
if want_phase 22; then phase_22_notification_rail; fi
if want_phase 23; then phase_23_stall_check;  fi
if want_phase 24; then phase_24_wake_rail;    fi

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
