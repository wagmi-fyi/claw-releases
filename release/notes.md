- **A skill you put on the claw yourself is no longer deleted by an update.**
  The machine-wide skill directory is open to a firm. Until this release, an
  unattended update emptied it of everything the release did not carry. The
  update read the list of skills the release ships and removed every other entry
  it found. Nothing named what went, and the claw's record afterwards listed the
  release's own skills, so the record agreed with itself. A claw whose operator
  rode the update by hand, with a list naming their own skills alongside the
  release's, kept them. That has been the only way a firm's own machine-wide
  skill survived an update.

  From this release the claw keeps a ledger of what an update installed, in
  `/etc/commonclaw/skills.yaml`. An update removes only what that ledger names,
  so a skill a release retires still goes. Everything else stays as you left it,
  and every run prints a line naming it by its full path, so the run's own record
  says what this claw is carrying.

  **Your skill wins a name it shares with ours.** Where a release ships a skill
  whose name one of yours already uses, yours takes precedence on your claw and
  the shipped one is installed nowhere there. Every update prints a line saying
  which name that happened to, so the state cannot go quiet. To take the shipped
  skill instead, move your entry off the claw and update again.

  **What to do.** Nothing, on a claw carrying only what the release ships. If
  your own skills were in the machine-wide directory before this release and are
  gone, put them back after taking it. Section 10 of the operator runbook says
  where the three places are and what reaches whom.

- **A release now reaches one machine on a tier before it is offered to the
  rest.** Machines take releases in tiers. The older order offered a release to a
  whole tier and then found out whether it worked there, so when it did not,
  every other firm on that tier was already being offered a release that would
  have failed on their machines as well. An operator can now run a named release
  on one machine by hand while the rest of the tier has not been offered it, and
  the offer follows when that run passes. The command refuses unless a tier at or
  below the machine's own already carries the release, and it refuses to run
  unattended, so the scheduled update cannot use it.

  **Nothing changes on a firm's side.** No setting moves and no machine behaves
  differently on its own. The effect a firm sees is one step removed: the release
  their machine is offered has already been run on a machine on their own tier,
  with a person watching it.

- **Cutting a release now works from wherever the operator is standing.** The
  tool that pins the per-file record of a release used to need every path spelt
  out from the root of the machine. Given a short path it read the release tree,
  then changed into it, and then looked for its own digester at that short path a
  second time, which by then pointed inside the tree instead of beside it. The
  run died after it had already read the tree. The same thing sent the written
  record inside the release tree rather than to the directory the operator named.
  All three paths are now resolved in full before anything changes directory,
  which is what the publishing tool has done since the same defect was measured
  in it.

  **A member sees nothing from this.** The tool runs on the machine where a
  release is cut and it is not part of what a claw takes, so no claw installs it
  and nothing on any machine changes.

- **The wake rail carries the same program with four comments reworded.** The
  rail is the thing that tells a session it has unread mail. Four comment lines
  in it named this company and one of its machines, and the rail's source is
  published openly, where a name like that does not belong. The lines now describe
  the machine a measurement was taken on rather than naming it. **Nothing runs
  differently.** The change is to text the program never reads, and it is listed
  here only because the file on your machine changes, so the update replaces it
  and restarts the watcher that was running it.

## Errata for every release up to 1.4.3

Published notes cannot be edited after the fact, so the corrections are here.

**Every release since the machine-wide skill directory existed has emptied it of
anything the release did not carry, and no release said so.** The update removed
each entry it found that its own list did not name, wrote its record of what it
had installed, and reported a clean run. A firm who put a skill there lost it on
the next unattended update, with nothing in the run's output naming what went. If
you are missing a machine-wide skill you placed yourself, that is where it went.
This release stops it, and the removal cannot be undone by taking the release, so
put the skill back afterwards.

**One placement behaved differently, and it failed loudly instead.** A firm who
dropped a real directory straight into one of the two machine reading places, and
nowhere else, kept the file. The update refused to replace a real directory with
a link and the whole run failed. So that firm lost no skill and got a red update
instead, on every run, until somebody moved the directory. From this release that
placement is left alone and named in a line, and the run passes.

## What somebody has to do

Nothing new. The two items 1.4.0 named still stand: put this claw's channel
webhook into its vault, and enrol this claw's dead-man check.

Nothing here moves either core for anybody, and no core floor changed.
