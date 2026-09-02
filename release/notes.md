- **An update no longer stops on a claw that has no alarm channel wired.** Near
  the end of an update, this claw checks that its own alarm messages are built
  correctly. One of those checks called the message tool six times and read what
  came back. On a claw with no channel wired the tool says so by exiting with an
  error code, which is the honest answer and the one the very next check is
  written to handle: it says no channel resolves here yet, and it tells you how
  to wire one.

  That error code was reaching the update itself, and the update stopped there,
  eleven lines above the sentence that would have told you what to do. The two
  checks beside it already survived the same answer. This one now does too.

  It only ever happened on a claw with no channel wired, which is why it was
  never seen: every machine that had taken a release before this one had a
  channel. If your update failed part way through with nothing obviously wrong,
  this is almost certainly what happened.

- **The machine that runs the fleet can now enrol its own dead-man check.**
  Every claw pings a check that lives off the machine, so that something which
  is not the claw notices when the claw goes quiet. Setting that up sends the
  address to the claw over a remote login. The machine the operator runs from is
  itself a claw, and it cannot log into itself, so it was the one machine the
  step could not finish for. It now has a way to write the address down locally,
  and it refuses to do that under any name but its own.

- **A quieter machine log.** The rail that tells a session it has unread mail
  watches every mailbox on the machine and only ever delivers to its own
  account's. A mailbox belonging to somebody else was written into the log every
  time it was looked at, which on a busy machine was about 138,000 lines a day
  for one account, crowding out the records of everything else. It is now
  written once when something about it changes, which is what the rest of the
  rail already did.

- **The same rail now waits, rather than delivering to nobody.** It decides
  whether anybody is signed in by counting live sessions. It had been deciding
  by whether a folder existed, and that folder stays behind for good once
  somebody has signed in even once. So an account nobody had used for weeks
  looked occupied. Release 1.4.1 said a watcher that finds nobody waits; on this
  kind of session it only waited if the person had never signed in at all. Now
  it waits whenever nobody is there.

- **A setting added by a release now reaches a machine that already has the
  file.** The wake rail's settings file is written once, when the machine is
  first built, and never touched again, so that a choice somebody made is never
  quietly reverted. The cost was that a setting added later never appeared, and
  nothing told anybody it existed. A missing setting is now added at the bottom
  of the file with its default and a note saying which release it came from.
  Nothing already in the file is changed, whatever its value.

## Errata for release 1.4.1

Published notes cannot be edited after the fact, so the correction is here.

**1.4.1's notes said the end of an update reports whether this machine's
services are well. That is true from the update after the one that installed
1.4.1, not from that one.** An update is carried out by the copy of the updater
the machine already had, and the new copy is what the update installs. So the
apply that landed 1.4.1 ran on the older updater and took no reading. Every
update from this one on takes it. The half an operator runs by hand worked from
the day 1.4.1 landed.

This is the same class of correction 1.4.0's notes needed, and it is worth
stating as a rule rather than a coincidence: **a fix to the updater reaches a
machine one release after it ships.**

## If your update failed at the alarm-channel step

Some claws failed an update part way through, at the step described in the first
item above. Nothing on those machines needs undoing.

- **Nothing was left half-installed that matters.** The update stopped inside a
  check, not inside a change. Everything the run had already put in place is
  the same material the next update puts in place again.
- **The machine is still running the release it was running before.** The
  version it records did not move.
- **It has two attempts left.** A machine tries the same release three times
  before it stops trying and records that it is stuck. One attempt was used.
- **The next update takes it.** A newer release is always accepted, whatever the
  count says, because a newer release is how a stuck machine gets unstuck. This
  release is that newer release.
- **The failed attempt's copy of the release is not the way back and nothing
  asks you to use it.** The machine keeps the last release that actually
  applied, and that is what it converges back to if anybody needs it to.

## What somebody has to do

Nothing new. The two items 1.4.0 named still stand: put this claw's channel
webhook into its vault, and enrol this claw's dead-man check.

Nothing here moves either core for anybody, and no core floor changed.
