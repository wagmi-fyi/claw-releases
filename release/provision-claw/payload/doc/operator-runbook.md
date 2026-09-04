# Operator runbook

For the person who runs this claw. A **claw** is the machine a firm's work lives
on. A **member** is somebody with a login here. You know this box. This document
covers how it takes updates, and the rails you wire on it once.

This copy ships with the release it describes. What the claw carries right now is
in `/etc/commonclaw/release.json`.

## 1. What a release is, and how this claw decides to take one

A release is a whole tree. It carries the provisioning code, the templates that
code installs, the skills every claw runs, and notes written for the people using
the claw. That tree is the **payload**. It is published as a tag in one
repository, and a claw fetches its own updates from there, so no other machine
holds a key to this one.

A **channel** is a pointer file naming the release one tier of claws currently
takes. This claw declares which channel it reads, in
`/etc/commonclaw/updater.conf`. That file is written once at build and never
rewritten, so a wrong value in it is a finding rather than something to edit
past.

The claw compares the version the channel names against the version it carries.
The comparison has three answers.

| Verdict | What happens |
|---|---|
| carried is at or above the offer | nothing newer exists. The claw records a no-op |
| carried is below the offer | the claw fetches, verifies and applies |
| either version is not digits and dots | the claw applies nothing and says so |

The pointer also carries a **digest**, a hash of the payload at that tag. The
claw fetches the payload, computes the digest with its own function, and refuses
when the two differ. That catches a truncated fetch, a corrupt fetch, the wrong
tag, and a payload changed after it was published. It proves nothing about who
wrote the payload. The control for that is who holds write access to the
repository.

The rail only rolls forward. A pointer moved backwards moves no claw, because a
claw never goes back a version. Undoing a release means publishing a newer one
that restores the older content.

Two modes decide whether the claw takes an offer on its own. `auto` applies in
the quiet window. `manual` applies nothing until somebody here asks, and the claw
still checks and still records what it is declining. Change it through the door
rather than by editing the file:

```
sudo /opt/commonclaw/provision-claw/scripts/set-update-mode.sh --mode manual
```

Manual leaves the timer running. The updater reads the file and exits as a no-op.

## 2. Taking an update by hand

Ask what is on offer first. This changes nothing. It writes no run record and
creates no log directory:

```
sudo /opt/commonclaw/provision-claw/scripts/commonclaw-update.sh --check
```

Then apply:

```
sudo /opt/commonclaw/provision-claw/scripts/commonclaw-update.sh --now
```

`--now` is the operator's override. It ignores the quiet window, applies on a
claw pinned to manual, and retries a release the claw has stopped retrying.

Watch the output while it runs. The provisioning run prints one line per check,
each line saying what it measured, and prints the count at the end.

**Attended** means somebody is reading that output as it goes, ready to stop
before a second machine is touched. Take one claw at a time, and finish reading
the first before starting another.

## 3. Reading the result

**The record file**, `/etc/commonclaw/release.json`, rewritten on every apply
whether it passed or failed. `version` is what the claw now carries and
`previous` is where it came from. `tree_digest` is the payload the claw measured,
and it should equal the digest the channel promised. A clean result reads
`last_verdict` as `applied`, `consecutive_failures` as 0, and `failing_version`
as empty, which together say no held failure is being carried forward.

**The changelog entry**, appended to `/etc/commonclaw/changelog.md`. Every entry
carries the date, the revision, what changed in plain terms, and whether it was a
fix or a feature. The file is world-readable, because its first reader is a
member's own agent asking why something on the claw behaves differently today.
Only provisioning writes there, and a failed run writes nothing.

**The health line**, printed at the end of the run. It is two measurements. No
unit has failed, and no unit is sitting in `activating` with a restart count. The
second half catches a service that crashes and restarts forever. A unit with a
restart policy never settles into a failed state, so a check reading failed units
alone would call that claw healthy.

**The two stage trees.** `/root/fleet-stage` holds the payload the claw runs now,
and `/root/fleet-stage.previous` holds the last one that applied cleanly, which
is the way back. Each carries its own `release.json` naming its version.

The claw also writes one file per update run under
`/var/log/commonclaw/updater/`, including for runs that failed, with the apply's
whole output beside it under the same timestamp. Read the newest pair.

## 4. When a check fails

The carried version does not advance. The claw records what happened:
`last_verdict` says the apply failed, `failing_version` names the release, and
`consecutive_failures` counts. After three failures on one version the claw holds
and records a stuck status. A newer release is still accepted, because a newer
release is the repair path.

A provisioning run converges the claw. It is not a transaction and no wrapper
makes it one, so a failure part way leaves the claw where the run reached. The
previous stage is kept, so re-applying it converges the claw back, and only a
stage that applied cleanly is ever kept there.

Read two things first. The failing check by name, out of the run's own output.
Then the newest file under `/var/log/commonclaw/updater/`.

Then stop. A failed run is a report about this claw or about the release, and
whoever cut that release needs it. Do not hand-edit a file the rail owns to get
past a check, or add a flag or an exclusion for the same purpose. Making a check
pass does not make the claw right, and a check that is wrong is wrong for every
claw on the channel.

One failure has no repair on the box. A release that breaks the updater leaves a
timer running broken code, and nothing here heals that. Your SSH access is the
way in.

## 5. Crossing several releases in one update

One apply moves the claw from the version it carries to the version the channel
names. The releases in between are never applied as separate hops. Their content
arrives anyway, because a release is a whole tree and a run consumes it entire.

Their notes arrive too. Once the apply passes, the claw reads the release
repository's tag list and writes one changelog entry for each release strictly
between where it was and where it now is, oldest first. Each of those entries
opens by saying which update it arrived on. A repository that will not answer
leaves a warning naming the release whose entry is missing, and the update still
counts as applied.

Read the skipped releases' own notes yourself. A release that needs somebody
present says so in its own landing section, and that section is written for a
claw taking that release on its own tick. A crossing never reads it.

A member who has never signed in defers the update to the quiet window. The claw
reads a person with no core installed as below the version floor, so it
classifies the release as core-moving whatever the releases themselves declare.
`--now` walks past that.

## 6. Wide mode

Wide mode gives every member of the `claw-members` group passwordless root on
this claw. One setting decides it, `WIDE_MODE` in
`/etc/commonclaw/provision.conf`, and one file is derived from that setting,
`/etc/sudoers.d/commonclaw-wide-mode`. Absent means off, and off is what ships.

The grant covers every command, deliberately. An agent working in a member's
session meets walls nobody predicted, and a grant naming the repairs somebody
thought of in advance needs an edit before it covers the next wall.

Only an operator naming the setting moves it, on a provisioning run:

```
sudo /opt/commonclaw/provision-claw/scripts/provision-claw.sh ... --wide-mode on
```

An update passes no such flag, by design, so no release can open a claw or close
one. A run passing nothing keeps what the claw already records. A recorded value
that is neither `on` nor `off` ends the run instead of being guessed at, because
guessing wrong is silent in both directions.

Exactly one file may name the members group, and it is the file provisioning
writes. A hand-placed grant in a second file fails the run whatever the setting
says.

Turning wide mode on while the claw also has to move version is two runs. Take
the update first. Then run provisioning out of the stage that update just left,
adding `--wide-mode on`. Nothing between the two is a hand edit.

## 7. The rails, and what a person wires once

This claw's checks write what they find to the journal on a machine nobody logs
into. These rails carry a finding off the box.

**The alarm channel.** One incoming webhook per claw, posting into one chat
channel. A person creates the webhook, puts its URL into this claw's own machine
vault as an API Credential item, and confirms the claw's service account can read
that item. `/etc/commonclaw/notify.conf` is the switch and
`/etc/commonclaw/notify.env` holds the reference. No URL rests on the claw, and
the poster refuses a config file carrying one. An absent config is a quiet state:
the poster exits clean and writes a notice.

**The memory alarm.** `commonclaw-memory-check.sh` runs on a timer and posts when
available memory or swap use crosses its line. Past the channel there is nothing
to wire.

**The dead-man ping.** Every healthy beat of the memory check makes one request
to a check that lives off the claw, and that check alarms when the requests stop.
So a claw that is off, thrashing, or running a broken timer is noticed by
something that is not the claw. Wiring it takes two halves. Off the box, create
the check and pipe its ping URL down one ssh command into this claw's
memory-backed runtime directory. On the claw, one command files that URL in the
machine vault, reads it back through the reference the memory check resolves, and
destroys the drop:

```
sudo /opt/commonclaw/provision-claw/scripts/install-heartbeat-url.sh
```

A refusal here names what refused. The door classifies the credential manager's
exit rather than asserting a cause, so the message says whether the call was
malformed, the vault refused the write, or the manager could not be reached.
Re-running is safe: a create that fails creates nothing and an edit that fails
changes nothing.

**The stall check.** It watches the session buses on this claw for a coordinating
handle holding unread mail past a threshold, and posts the handle names, their
counts and their ages. It reports no subject and no message body. It reads files
already on the box, so nothing else here needs wiring.

**The wake rail.** A session bus is files, and a message written into one
announces itself to nobody. This rail tells a live session that it has unread
mail, in one fixed sentence carrying no instruction. An account with no session
running is a normal state for it: the rail idles, re-checks on its own interval,
and logs one line when that state changes. A missing delivery adapter is a
different thing, and it stops the unit, because a rail that quietly delivered
nothing would read exactly like a quiet bus. The installer counts what it
installed and enabled, and reports each account's unit state as a note.

## 8. The backup rail

Snapshots leave the claw encrypted and land in an object store.
`/etc/commonclaw/backup.env` names the repository password and the store's key
as manager references, resolved at the moment the rail runs. No value rests here.

The timer fires four times a day. A run captures the work root, every home
directory including session transcripts, this claw's config, and consistent
database copies taken through each database's own backup interface beforehand.
Asking what it captures needs no credential:

```
/usr/local/sbin/commonclaw-backup.sh targets
```

Virtual environments, caches and downloaded core binaries stay out, because they
rebuild in less time than a restore takes.

Every run applies the retention policy, which keeps one snapshot a day for the
recent week and one per week and month behind that. The numbers live in the
script. Reclaiming the space behind a forgotten snapshot is the expensive half,
so it runs once a day, gated on the time since the last reclaim that succeeded.
To force one early, delete `/var/lib/commonclaw/last-prune`; the next run finds
no stamp, reclaims, and logs that it did. A failed reclaim writes no stamp, so
the run after it retries on its own.

`commonclaw-backup.service` is a one-shot unit carrying no restart policy, so a
failed backup run stays in the failed state and the health line in section 3
reports it.

The rail never initializes a repository by itself, and a run that cannot read one
stops loud. An object store can refuse reads while writes succeed, so an
unreadable repository is a thing to investigate. Initializing over one that is
still there destroys it.

## 9. Credentials

One credential rests on this claw: the service-account token that opens the
claw's own machine vault. It is encrypted with the host's own key, so the blob is
useless anywhere else.

Replacing it means dropping the new value onto memory-backed storage and then
opening the door. The value reaches no screen and no command line:

```
op read "op://{vault}/{hostname}-machine-broker-service-token/credential" \
  | ssh {claw} 'umask 077; cat > /run/user/$(id -u)/commonclaw-machine-token'
ssh {claw} 'sudo /opt/commonclaw/provision-claw/scripts/install-machine-token.sh'
```

Nothing else rests here. Config files on this claw carry manager references and
never values, which is what makes them safe to read and to commit.

Retiring a credential means retiring it at the manager. Rewriting a file on the
claw revokes nothing, because the old value is inside every backup snapshot still
within the retention window, and a delete on the box reaches no snapshot.

## 10. Your own skills

The machine-wide tier is `/opt/commonclaw/skills`, linked into both cores'
machine-wide skill directories. Releases put skills there. Your own belong there
too, when everybody on the claw should have them.

Provisioning keeps a ledger of what a release installed, in
`/etc/commonclaw/skills.yaml`, and it removes only what that ledger names.
Anything you put in the tier by hand stays as you left it. Every run names it in
a note, so the run's own record says this claw is carrying it.

The other two places need nothing from an operator. A member's own
`~/.claude/skills` reaches that person's sessions and nobody else's. A workspace
can carry skills as well, and those reach whoever is working in it.

Skill names have to be unique across the claw. One core resolves a same-name
collision by authority, and the other lists every copy and leaves the model to
pick. So where a release ships a skill whose name yours already uses, yours
takes precedence on this claw and the shipped one is not installed at all. Every
run prints a line saying which name that happened to. To take the shipped skill
instead, move your entry off the claw and update again.

## 11. Where to look

| Path | Holds |
|---|---|
| `/etc/commonclaw/release.json` | the version carried, its digest and tag, when it landed, the last verdict, the failure count |
| `/etc/commonclaw/updater.conf` | the mode and the channel. Seeded once, never rewritten |
| `/etc/commonclaw/changelog.md` | one entry per release this claw has taken |
| `/etc/commonclaw/provision.conf` | this claw's identity, and `WIDE_MODE` |
| `/etc/commonclaw/admin-log.md` | what this firm's own admins did to this claw |
| `/etc/commonclaw/backup.env` | the backup rail's manager references |
| `/etc/commonclaw/notify.conf`, `notify.env` | the alarm channel's switch, and its manager reference |
| `/etc/commonclaw/memory.env` | the dead-man ping's manager reference |
| `/etc/commonclaw/stall-check.conf` | the stall check's threshold |
| `/etc/commonclaw/session-bus.md` | what the bus is, for a member |
| `/etc/commonclaw/claw-authority.md` | who may approve an operation on this claw, and how |
| `/etc/commonclaw/workspace-conventions.md` | how work is filed here, for a member |
| `/etc/commonclaw/runtimes.md` | the shared language runtimes, for a member |
| `/etc/commonclaw/skills.yaml` | which skills a release installed here, and the ledger pruning reads |
| `/opt/commonclaw/skills` | the machine-wide skill tier, releases' and yours |
| `/etc/sudoers.d/commonclaw-wide-mode` | the wide-mode grant, when the setting is on |
| `/etc/orchestrate.conf` | where this machine's shared session bus is |
| `/var/log/commonclaw/updater/` | one record per update run, and the apply's output |
| `/var/lib/commonclaw/updater/deferred` | the release being held, and since when |
| `/var/lib/commonclaw/last-prune` | when the last reclaim succeeded |
| `/root/fleet-stage` | the payload this claw is running |
| `/root/fleet-stage.previous` | the last payload that applied cleanly. The way back |
| `/opt/commonclaw/provision-claw/scripts/commonclaw-update.sh` | the updater. `--check` and `--now` |
| `/opt/commonclaw/provision-claw/scripts/provision-claw.sh` | the provisioning run itself |
| `/opt/commonclaw/provision-claw/scripts/set-update-mode.sh` | the mode door |
| `/opt/commonclaw/provision-claw/scripts/install-machine-token.sh` | the machine-token door |
| `/opt/commonclaw/provision-claw/scripts/install-heartbeat-url.sh` | the dead-man ping's claw half |
| `/usr/local/sbin/commonclaw-backup.sh` | the backup rail. `targets`, `snapshots`, `restore` |
| `/usr/local/sbin/commonclaw-notify.sh` | the poster every check calls |
| `/usr/local/sbin/commonclaw-memory-check.sh` | the memory alarm and the ping |
| `/usr/local/sbin/commonclaw-stall-check.sh` | the stall check |
| `/opt/commonclaw/bin/bus` | the session bus program |
| `/opt/commonclaw/bin/bus-nudge` | the wake rail |
| `/opt/commonclaw/doc/wake-rail.md` | the wake rail's own contract |
| `/opt/commonclaw/doc/operator-runbook.md` | this document |

## 12. What this document does not cover

The rail's own contract, and what a release is required to carry, are in the
release repository's README. What one release changed is in that release's own
notes, and in this claw's changelog. The documents written for a member are named
in the table above, under `/etc/commonclaw`.
