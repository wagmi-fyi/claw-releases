- **The claw now says what makes a group change reach you.** A program that is
  already running keeps the groups it started with. Two of yours on a claw
  outlive every login. One is the desktop app's server on the claw, which every
  session you open from the app runs under. The other is the daemon that starts
  your background agents. Quitting the app and opening it again reconnects to
  the same server, so a change to your groups does not reach you until both
  have ended.

  The conventions file your agents read now says what ends them, under Access.
  Whoever runs the claw ends both as root. You can end your own from a terminal
  on the claw. Then you open the app again. The scripts that grant a workspace,
  add a person or change a tier now point at that section. They used to tell you
  to log in again.

  **What you have to do: nothing,** unless a session still reads
  `Permission denied` on the bus or in a workspace. That session started before
  the change. Ask whoever runs the claw to end your processes, then open the app
  again.

  **For whoever runs the claw.** The claw briefing template carries the new
  heading. It seeds only a claw that has no briefing yet, so an existing claw
  keeps the words it has until somebody edits its briefing by hand.

- **A session the desktop app replaced now stops, and its old process is ended.**
  The desktop app can reconnect a conversation under a new process and leave
  the old one running. The old one kept the transcript open and took a turn
  every time the wake rail nudged it. From this release the rail nudges only the
  newest process of a session. A new command, `session-guard`, tells a session
  whether a newer process replaced it, and an orchestrator runs it first on
  every resume and every beat. A new timer, `session-sweep@<you>.timer`, ends
  the old process once the new one has run for five minutes and holds its
  socket open. Background agents are left alone.

  The timer starts with this update. An old process already left behind on
  your claw is ended on its first passes, within about ten minutes of the
  update.

  **What you have to do: nothing.** To change the five minutes, set
  `SWEEP_GRACE_SECS` in `/etc/commonclaw/bus-nudge.conf`. To switch the sweeper
  off, disable your `session-sweep@<you>.timer`.

- **`email inbox create` now adopts an inbox your organisation already has.**
  Before this release, a create for an address that already existed at the
  mail provider failed with "answered 403" and nothing else. From this release
  the command finds that inbox in your organisation and records it, so the mail
  service connects to it. No second inbox is made. If another organisation holds
  the name, the command says so, and you pick another name.

  Every refusal from the provider now carries the provider's own words, for
  example "Inbox already exists". Before, it carried the status number alone.

  **What you have to do: nothing.** If your claw's mail already works, nothing
  changes for you. If `email inbox create` failed for you with a 403, run it
  again after this release lands.

- **`email inbox create` now needs `--username`.** Before this release, a
  create with no name went through, and the mail provider picked a name for the
  inbox. The claw then recorded that address and used it. From this release the
  command stops with a usage line and asks the provider for nothing. The mail
  service refuses a nameless create too, for a caller that goes round the
  command.

  The mail service no longer prints a command name between backticks. Its
  status line now reads "a person makes it with 'email inbox create --username
  NAME'". A backtick in a line that somebody pastes into a shell command runs
  whatever sits between the two.

  **What you have to do: nothing.** If your claw's mail already works, nothing
  changes for you. If you make the inbox from now on, give it a name with
  `--username`.

- **Your firm's admin can now finish connecting a provider without a root
  login.** In 1.6.0 the last step of `token add`, the command that hands the
  credential to the claw, needed somebody with root on the claw. From this
  release that command is on the same grant as your claw's other admin
  commands. An admin runs it from their own login with `sudo`, and the steps
  `token add` prints now say so.

  **What you have to do: nothing.** A provider you already connected keeps
  working.

  **For whoever runs the claw.** The command now starts in `/` and reads
  nothing from the directory it was called from, so an admin can run it from
  inside a workspace.

## Errata for release 1.6.0

Published notes cannot be edited after the fact, so the corrections are here.

**1.6.0 says to quit and reopen the desktop app once after the update.** That
reconnects to the same server on the claw, and the server keeps the groups it
started with. The step that works is for whoever took the update to end each
person's server and background-agent daemon as root, right after the apply. Each
person then opens the app again. Measured on 2026-09-14: an app left open
started a fresh server holding the new group three seconds after its old one
ended, with nothing from the person.

## What somebody has to do

**Whoever applies this release by hand passes `--now` on a claw pinned to manual
updates.** That flag is what walks a person standing at the box past the manual
setting. A claw that updates on its own takes this release on its next
scheduled run.

This release changes nobody's groups, so nobody has to end a process or reopen
the app because of it.

The two items 1.4.0 named still stand: put this claw's channel webhook into its
vault, and enrol this claw's dead-man check. The two mail steps 1.5.1 named
still stand for a firm that wants an address: put the provider key into the
claw's own machine vault, then make the address once with
`email inbox create --username NAME`. If the address already exists in your
organisation, making it now connects the claw to it.

Nothing here moves either core for anybody, and no core floor changed.
