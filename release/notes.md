- **A person who is not signed in no longer fails your claw's update.** The
  rail that tells a session it has mail runs one watcher per person on the
  machine. Each watcher needs a live session to hand a message to, and until
  now, finding none it stopped and was restarted, forever. On a claw with more
  than one person that is the ordinary state most of the time, and on 2026-09-02
  it stopped a release from landing on a machine where one person happened to be
  away.

  A watcher that finds nobody now waits instead. It says so once in the machine
  log, looks again every minute, and starts delivering the moment that person
  opens a session. The thing that is still treated as a fault is a machine with
  no way to reach a session at all, because waiting does not fix that.

  The installer changed with it. It now reports that a watcher is installed and
  switched on, which is what it can promise, and says separately whether one is
  running right now. And the unit has a limit on how often it may restart, so
  something nobody can fix cannot fill the machine log while it tries.

- **Your claw's admin door now proves its scope by reading the grant, not by
  asking what one person may run.** The door gives your admins a fixed list of
  the claw's own scripts and nothing else, and the check for that used to ask
  the system what one of those people could run. On a claw where every member
  deliberately holds full root, the honest answer to that question is
  "everything", so the check went red on three counts while reporting the truth
  about the machine.

  It now reads the grant file itself, which is the only place the door's own
  scope is written, and holds it to exactly the scripts it should name. On a
  claw where everyone holds full root, it also checks that the wide grant comes
  from the one file that is supposed to carry it, so a grant somebody left
  behind in a second file is still found. Where members do not hold full root,
  the live refusal checks run exactly as before.

  One sentence in that output claimed more than it measured. It said a person's
  permissions carried the granted scripts "and nothing else" while a full-root
  entry sat two lines below it. Nothing was hidden, because the next check
  caught that entry, and the sentence has been rewritten to say what it looked
  at.

- **The end of an update now says whether this machine's services are well.** A
  service set to restart itself never settles into the state the usual health
  command looks for. It sits in "starting" and that command reports nothing
  wrong, so a service failing every ten seconds reads as a healthy box. Every
  update now ends with a reading that looks for both: nothing failed, and
  nothing stuck restarting. It never fails the update, because the release
  landed and a service misbehaving for its own reasons is a separate matter.

- **The heartbeat door no longer blames the wrong thing when it refuses.** The
  step that files this claw's dead-man address in its vault could not write from
  any command sent over ssh, and it reported that as a missing vault permission.
  The real cause was the tool refusing the shape of the call. Both writes now
  make that call correctly, and where one is still refused the door prints what
  the tool actually said and names which kind of refusal it read, rather than
  naming a cause it did not measure.

- **A claw whose ordinary door refuses the operator can now be enrolled.** The
  command that stands the dead-man check used one word for two jobs: the name of
  the check, and the machine to send the address to. Where those had to differ,
  the enrolment either could not reach the machine or would have stood a second
  check under the wrong name. They are now two things, and the second one
  defaults to the first, so nothing that works today changes.

- **A directory the notifier writes into keeps the mode it was given.** Two of
  this claw's components wrote to the same place and each re-set its permissions
  on every run, so the mode flipped back and forth with the traffic. Nothing was
  locked out, because both run as root. It is fixed in the notifier and in three
  places in the backup script for the same reason.

- **Three files that ship with every release are now required by the run that
  uses them.** A release that lost one of them would have passed every check and
  arrived on your claw incomplete. The wake rail's delivery adapters are held to
  each one by name for the same reason.

- **The operator's runbook now rides with the release.** After this release
  every claw carries it at `/opt/commonclaw/doc/operator-runbook.md`, beside
  the wake rail's own document. It is replaced when a release carries a newer
  one, and a copy that differs is named in the run's output before it goes.

## Two corrections to release 1.4.0's notes

Published notes cannot be edited after the fact, so the corrections are here.

**1.4.0's notes said an update keeps its own progress log, that `--check` writes
nothing, and that the changelog fills in every release an update crossed. All
three are true from the next update, not from the one that installed 1.4.0.**
The update itself is performed by the copy of the updater the claw already had,
because the new copy is what the update installs. So 1.4.0's own apply ran on
1.3.1's updater and did none of the three. The claw that took 1.4.0 has the
right updater now, and everything those three paragraphs promise happens on the
next update it takes.

**1.4.0's notes said a refusal at the heartbeat door means the claw's vault
account is missing write permission. That is one possible cause and it was not
the one anybody met.** The door could not write from any command sent over ssh,
whatever permissions the account held, because the tool it calls refuses that
shape of call when its input is not a terminal. The account had held write all
along. 1.4.1 fixes the call and stops the door naming a cause it did not
measure. If somebody granted that permission on a claw in response to the old
message, nothing is wrong; the grant is harmless and the door now works either
way.

## What somebody has to do

Nothing new. The two items 1.4.0 named stand: put this claw's channel webhook
into its vault, and enrol this claw's heartbeat check.

Nothing here moves either core for anybody, and no core floor changed.
