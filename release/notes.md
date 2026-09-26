- **You can have work run on its own.** Ask your agent on the claw to schedule
  a job and it runs on a timer under your own account, with nobody signed in.
  You can also ask what is scheduled here, and take over the jobs of somebody
  who has left so they keep running under your account. Accounts that exist
  gain this at the update. New accounts gain it at onboarding.

- **A change to who can reach a workspace now reaches that person's scheduled
  work.** Work running under somebody's account kept the access it started with
  until they logged out and back in, and nothing said so.
  A grant or a revoke now restarts that person's service manager when its
  access differs from the account's. Their timers come back and the next run is
  on time. Anything else they had running under it stops, and the grant says
  so.

- **An orchestrator that has stopped comes back by itself when mail waits for
  it.** Every two minutes a check looks for one of your orchestrator sessions
  that has unread mail and no process behind it, and starts it on the same
  conversation. It never starts one that is already here. A session it started
  is stopped again after fifteen quiet minutes, and the conversation is kept. A start that fails stops the check for that account,
  and one line goes to the `human` handle saying why. To see what a pass would
  do, run `/opt/commonclaw/bin/session-continuity --check`.

- **Your claw's journal holds one line per event from six more programs.** The
  backup rail, the updater, the memory check, the notifier, the seat check and
  the stall check each wrote every event twice: once under its own name, once
  under the name of the file it runs from. A search on the name found one, and
  reading the unit found both. Lines already in your journal stay as they are.

- **An update no longer records who hears about waiting mail.** That line
  printed the address, and an update's output is kept as a log. It now says one
  person is told and where to read who: run
  `/usr/local/sbin/commonclaw-mail-check.sh --state` as root and the first line
  names them. Logs an earlier update wrote still carry it. Delete them if you
  would rather they did not.

- **An update leaves `/etc/orchestrate.conf` alone when nothing in it changes.**
  The file's date now says when a setting last changed.

- **The operator runbook says how to read the claw's health between updates.**
  It gives the whole path, because that script is on nobody's path.

## What a firm never sees

The backup rail reclaims space once a day, and the rule written for that gate
was stricter than the value every claw runs. The two now agree, the value lives
in one place, and the document cites it.

The rail that brings an orchestrator back clears its own record of a handle
nothing has written to in a month, unless that record says something is still
outstanding.

A skill document said no heartbeat check had been created. Two claws carry it
and the document now says so.

Our own release tooling moved its run records out of the repository it
publishes from, and a directory of old records whose names were replaced now
carries a README saying its scripts are records. Two control suites that were
failing on baselines older than three releases are repaired.

## What somebody has to do

Nothing. No group changes, so nobody has to end a process or reopen the app.
No core moves and no core floor changed.

Every person's account gains one timer. It starts within two minutes of the
update and does nothing until an orchestrator of that account has mail and no
session. To turn it off for an account, disable
`session-continuity@<account>.timer`; a later update leaves it off.

Whoever applies this release by hand passes `--now` on a claw pinned to manual
updates. A claw that updates on its own takes it on its next scheduled run.
