- **A fix to the wake rail now actually runs after an update.** The rail is the
  thing that tells a session it has unread mail. An update replaces the program
  it runs, and the copy already running kept going on the bytes it started with,
  so a corrected rail sat on the machine doing nothing until somebody restarted
  it or the box was rebooted. The update now compares the program and its
  delivery parts before and after it copies them, and restarts a watcher that
  was already running when they changed. A watcher that was stopped is started
  the way it always was, once. A watcher whose bytes did not change is left
  alone. Each restart prints a line naming what it was running and what it moved
  onto.

  **This matters to anybody who took 1.4.2.** That release carried two wake-rail
  fixes, and on a machine where the watcher had been up since before the update,
  neither of them was running. Taking this release puts them into service.

- **The wake rail reads the settings file on the machine.** The file is at
  `/etc/commonclaw/bus-nudge.conf`, which is where the install writes it. The
  program had been looking somewhere else, so every machine ran the rail on the
  shipped defaults and a setting written into that file changed nothing. The
  program now reads the file the install writes. The one setting that mattered
  most before anybody tuned anything, the switch that turns the rail off, now
  does what it says.

- **A machine somebody left a terminal session open on gets the nudge in that
  terminal.** The rail finds a session by asking each way of reaching one in
  turn. A `tmux` server counts, and a `tmux` server left running weeks ago still
  counts. So an account with nobody signed in to a core and one old terminal
  session behind it gets the message delivered into that terminal rather than
  going quiet. Closing that server is what makes the account quiet. This is not
  a change; it is what the rail has always done, and the wake-rail document on
  every claw now says so.

- **Enrolling a dead-man check over a remote login keeps the file locked down.**
  Writing the address to the far machine creates a file that only the owner can
  read. A file already sitting there from an earlier run kept whatever
  permissions it had, because the setting that locks a new file down does
  nothing to one that already exists. The old file is now removed first. The
  same thing was fixed for the local case in 1.4.2.

- **Publishing a release refuses when the operator has no name set.** The
  release commit takes its author from the operator's own git settings. With no
  name and no address set, git accepted it and the commit landed signed by
  nobody. It now stops before it reads any credential or touches the network,
  and it names the two settings to fix.

## Errata for releases 1.4.0 through 1.4.2

Published notes cannot be edited after the fact, so the corrections are here.

**Every release from 1.4.0 on has verified a settings file the wake rail was not
reading.** The install wrote the file, checked it, and reported it. The program
looked at a different path and found nothing, so it ran on its shipped defaults
throughout. Nothing failed, because the defaults and the shipped file said the
same thing. What was lost is that a machine could not change the setting. From
this release the two name one file.

**1.4.2's two wake-rail fixes did not run on a machine whose watcher was already
up.** They installed correctly and they verified correctly. The watcher kept the
old program in memory until something stopped it. On the machines that took
1.4.2, that means the quieter machine log and the waiting behaviour arrived only
where somebody restarted the watcher by hand. This release puts them into
service on the next update.

## What somebody has to do

Nothing new. The two items 1.4.0 named still stand: put this claw's channel
webhook into its vault, and enrol this claw's dead-man check.

Nothing here moves either core for anybody, and no core floor changed.
