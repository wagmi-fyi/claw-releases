- **A claw can now give every member passwordless root on their own box, and it
  is off unless somebody turns it on.** This is for a firm that runs its own
  claw and wants no gate between a person and their machine. It is not a default
  and it never becomes one by accident.

  The setting is recorded in the claw's own configuration, and provisioning owns
  the grant file that carries it. A run that passes nothing keeps whatever the
  claw already recorded. A run that turns it off removes the grant. Nothing else
  on the claw may hand that group a sudo grant: with wide mode on, exactly one
  file may name the members group and it is the one provisioning writes, so a
  grant somebody added by hand in a second file is still a failure. Turning it on
  gives every member of the group root on the box, and the run says that out
  loud rather than applying it quietly.

- **The session bus now records which session is behind a handle.** Before this,
  a handle that had gone away looked exactly like a handle that was working. The
  board now shows live, gone, or a question mark when there is no session
  recorded to ask about, and a new `bus whois` answers the same question for one
  handle. The question mark is deliberate: an unknown state is not reported as
  dead.

- **A bus handle that starts with a dash is refused.** It reads as a flag to
  every program that receives it, so what used to register a strangely named
  handle now stops and says why.

- **The claw carries a check for its own git conventions.** Point
  `check-git-conventions.sh` at a repository and it reports which rules that
  repository breaks: an unborn HEAD, a missing git identity, two copies of a
  briefing where there should be a symlink, a manifest that is not there, a
  tracked line that looks like a credential. It is read-only and it never
  reaches the network. It also says which rules it could not test, because a
  check that did not run has found nothing, which is not the same as finding
  nothing wrong.

- **The workspace conventions now say that a repository nested inside a
  workspace is a project, not a workspace.** The layout rules describe a
  workspace root. A project inside one carries no manifest and no briefing, and
  the document used to leave that to be inferred.

Nothing here moves either core for anybody, and no core floor changed.

## Landing this release on a claw that already runs wide mode

Read this before you apply 1.3.0 if somebody has hand-placed a sudoers file for
the members group on your claw. Phase 19 derives the grant from the recorded
setting, and a claw that records nothing is a claw with wide mode off, so an
unattended run would take passwordless root away from every member. The first
landing is therefore attended: run the update by hand passing `--wide-mode on`,
which records the setting in the claw's configuration and lays the correct grant
file at `/etc/sudoers.d/commonclaw-wide-mode`, and remove your
hand-placed file only after that file exists. Removing it first takes sudo away
from the session doing the work. Later runs need no flag: they carry the
recorded setting forward on their own.
