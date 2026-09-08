- **This claw can now hold one email address for your firm, with the sessions on
  the machine behind it.** Somebody outside writes to the firm. They do not have
  to guess which person or which agent to reach. What arrives is carried to the
  sessions whose work it is, and what those sessions write goes back out the same
  way. Nobody carries a message by hand.

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
  the filesystem. From 1.5.0 the phase's own git calls stand there whatever
  directory the caller is in, and the operator runbook says to ride from the same
  place.

  **What to do.** Nothing. A claw takes this on its next update.

## What somebody has to do

Nothing new. The two items 1.4.0 named still stand: put this claw's channel
webhook into its vault, and enrol this claw's dead-man check.

Nothing here moves either core for anybody, and no core floor changed.
