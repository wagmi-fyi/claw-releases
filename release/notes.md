- **1.5.0 could not be applied on any claw, and this release fixes that.** The
  update ran, put the mail gatekeeper on the box, and then failed its own last
  check on it. The check asked for a file that the same update had just declined
  to write, so it failed everywhere rather than on some machines. Your claw kept
  the version it already carried and told you the apply had failed.

  The cause was one seam between two programs. The part that installs mail looked
  for the name of your claw's vault in a config file that has never carried it.
  Finding nothing, it wrote no file and said so. The update then read that
  missing file as a failure. Now the update hands the vault name straight to the
  installer, which is how every other credential-holding part of a claw has
  always been done, and the file is written on every install.

  Two claws were read directly, staging and the hub, and the config file on
  neither one carries that name. Nothing a claw does can put it there, so the
  failure was a property of the release and reached every machine that took it.

  **What you have to do: apply 1.5.1.** Nothing else. There is no state on your
  box to clean up first.

  **The gatekeeper a failed 1.5.0 apply left on your claw is kept exactly as it
  is.** If your claw ran 1.5.0 and failed, the mail service, its account, its
  directories and your routing table are already there and already correct. This
  release adopts all of it, writes the one missing file, and changes none of the
  rest. Your routing table is never rewritten by an update.

  **The reference this release writes holds no key.** It is a line naming where
  your claw's own machine vault keeps the provider key, and the key itself goes
  in later, by hand, once, with the door described below. A claw with no key
  wired is not broken: the service runs, reports that it reaches no provider,
  and waits.

  **One state still stops the file being written**, and it is now the only one: a
  box that reports no short hostname, where the reference would name no item at
  all. The update says so in a note and does not fail the apply.

- **This claw can now hold one email address for your firm, with the sessions on
  the machine behind it.** Somebody outside writes to the firm. They do not have
  to guess which person or which agent to reach. What arrives is carried to the
  sessions whose work it is, and what those sessions write goes back out the same
  way. Nobody carries a message by hand.

  This capability was cut as 1.5.0, which no claw could apply. It arrives here
  for the first time.

  The part this release installs is plumbing, and it is built to stay that way.
  It reads no mail for meaning. It picks no recipient beyond the table you give
  it. It answers nothing on its own. It keeps no copy of your correspondence,
  which rests at the provider. It holds no key on disk: the value lives in the
  running process from start to stop, and this claw's own machine vault holds it
  the rest of the time.

  Which mail waits for a person to look at it is your firm's rule, written down
  in your own document, and no code path here decides it.

  **Two steps turn it on, both a person's, both once.** The operator runbook on
  the claw carries them in full.

  The first puts your provider key into this claw's own machine vault:

  ```
  sudo /opt/commonclaw/provision-claw/scripts/install-email-provider-key.sh
  ```

  It takes the value through memory, files it, reads it back through the same
  reference the service uses, and destroys the drop. It then restarts the
  service, because a running process holds the key it started with.

  The second makes the address, after the key is wired:

  ```
  email inbox create --username <name> --display-name "<Display Name>"
  ```

  That address is in every From: line a recipient will ever see, so no release
  picks it and a second one is refused.

  **A claw with neither step done is not broken.** The service is installed and
  running, it reports that it reaches no provider, and it waits. The update says
  the same thing in two notes and does not fail the run. This is the ordinary
  state of a claw whose firm has not wired mail, and a rail that failed an apply
  for it would stop a release above the sentence saying how to fix it.

  **What an agent on the box gains** is the `email` command: send, read a thread,
  read a message, see and change the routing table, read the health line, and
  make the claw's one inbox. It talks to the service over a socket that only
  members of this claw can open. It never refuses a caller, so anybody who can
  open that socket can send as the firm. Every send is written to a log with the
  account it came from, measured rather than claimed.

  **The table also records where your firm's mail rules live.** The document your
  email agent applies to everything that goes out sits in that agent's own
  directory, and nothing else on the machine could name that directory. The
  routing table now carries the path:

  ```
  email self set runbook <absolute path>
  ```

  `email self` reads it back, and the update prints one note when it is unset.
  Nothing opens the file. It is a pointer and nothing more.

  **What to do.** Nothing, on a claw with no mail. A firm that wants the address
  runs the two steps above, in that order.

- **A claw carrying the mail gatekeeper takes its updates in the early morning
  rather than within the hour, and this release does not change that.** The mail
  service runs under an account of its own, and that account is a member of the
  group this claw treats as its people, because that membership is what lets the
  service put a message on the session bus.

  Deciding whether an update would replace somebody's core reads that same group.
  The service account has no core and never will, so it reads as a person below
  the version floor, and every update from here on is classed as one that would
  replace a core. An update classed that way waits for the quiet window, which is
  04:00 to 06:00 on this machine's own clock, and lands regardless once 26 hours
  have passed without that window being reached.

  **What that means for you.** Your updates still land, and they still land
  within a day. They land overnight instead of on the next check. Nothing is
  skipped, nothing fails, and no version is missed.

  **What to do.** Nothing. Somebody standing at the box who wants an update to
  land at once runs it with --now, which is the flag that walks past the window.

  This was measured on 2026-09-08 on the first claw to carry the mail service,
  where the update check deferred a release that declares itself quiet and moves
  no core. It is a defect this release family carries and it is written down.

- **The skill that runs a firm's email is in the open library and does not
  arrive with this release.** The service moves mail. The judgement about mail
  sits with an agent, and that agent is launched from a skill called `email`.
  The skill says what an email agent is and what it never does, how a firm stands
  one up, what to do with each mail that arrives, and how anybody else on the
  claw asks for a send. It carries a template for the firm's own communication
  runbook, the document that says who signs, what tone the firm writes in, and
  which mail waits for a person. The launch writes that document, then records
  its path in the routing table with the command above.

  **What to do.** Nothing on the claw. This release installs no skill and no
  agent. A firm that wants an email agent takes the skill from the library and
  runs its launch.

- **An update run by hand from inside a home directory no longer reports every
  other person's git identity as missing.** The people phase writes and reads
  each person's git name and address as that person. It did so from wherever the
  operator happened to be standing. git looks at its working directory before it
  does anything else, and one person cannot look inside another person's home, so
  every reading for everybody but the operator died there. The run then said
  those people had no git identity. They had one the whole time.

  What that cost a claw: one update on 2026-09-04 reported six failed checks
  against one person, recorded the old version, and wrote no changelog entry, on
  a box whose files had already converged. Nothing in the output named the
  operator's directory as the cause.

  The scheduled update never met this, because the system hands it the root of
  the filesystem. From this release the phase's own git calls stand there
  whatever directory the caller is in, and the operator runbook says to ride from
  the same place.

  **What to do.** Nothing. A claw takes this on its next update.

## Errata for release 1.5.0

Published notes cannot be edited after the fact, so the correction is here.

**1.5.0 was published to the staging channel on 2026-09-08 and applied nowhere.**
No claw on any tier carries it. Its own notes describe the mail gatekeeper, the
email skill and the people phase as things a claw takes on its next update, and
no claw ever did, because the apply failed on every machine at the check
described at the top of this file. Those three items are carried here and this
is the release that lands them.

The one claw that ran 1.5.0 is staging, and it failed. What that box has is what
a failed apply leaves: the files converged, the version not advanced, and no
changelog entry. Taking this release from there needs nothing done first.

## What somebody has to do

Nothing new. The two items 1.4.0 named still stand: put this claw's channel
webhook into its vault, and enrol this claw's dead-man check.

Nothing here moves either core for anybody, and no core floor changed.
