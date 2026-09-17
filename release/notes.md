- **Mail sent to your firm's address now reaches the sessions on your claw.**
  Before this release, the mail service connected to the provider and said it
  was listening, and a received mail still reached no session. The service
  could not read a message the provider sent in pieces, and it lost its place
  when a read timed out in the middle of a message. It dropped each such
  message without a word. It now reads both cases.

  Three more changes keep the connection useful:

  - The service keeps the connection open with a regular ping. Before, the
    provider closed it after ten quiet minutes.
  - After an ordinary close, the service reconnects in about a second. Before,
    the wait grew to a minute and stayed there.
  - On every connect, the service asks the provider for the mail that arrived
    while it was away, and routes each one once. It keeps its place in a small
    file beside the routing table, so a restart does not route a mail twice.

  The first time the service starts after this update, it starts from that
  moment. Mail that arrived before then is still at the provider, and no
  session receives it.

  `email status` says more. Its `health` line says since when the service is
  connected, how many times it reconnected, and what the last stop said. A
  message from the provider that the service did not act on is counted under
  `passed_over`, with no content.

  **What you have to do: nothing.** The mail service restarts on the new
  program during the update.

- **Your claw now tells a named person when mail is waiting and nobody reads
  it.** A new check runs every five minutes. It raises an alert when a mail has
  waited unread for more than an hour, and it says whether the session that
  should read it is running. It also raises an alert when the mail service has
  been disconnected for more than an hour. The alert goes to your claw's alarm
  channel, and by mail to one address you choose. It names the handles, counts
  the mails and gives their ages. It never carries a sender, a subject or any
  text of a mail. An unchanged alert repeats once a day, and a new late mail
  sends a new one at once.

  **What you have to do:** on a claw that has a mail address, set
  `MAIL_ALERT_TO` in `/etc/commonclaw/email-gatekeeper.conf` to the address of
  the person who should hear about it. Until then the alert goes to the alarm
  channel only. The next check reads the value, and nothing needs a restart.
  `LATE_MINUTES` and `REMIND_HOURS` in the same file change the hour and the
  day. A claw with no mail address stays quiet.

- **The `email` skill now arrives on every claw with the update.** The skill
  is what an email agent is launched from. Your sessions find it without
  anybody installing it. It now carries its own document on the mail service:
  what the service does and never does, the routing table, the send log, and
  how to read its health.

  **What you have to do: nothing.** If your claw already holds its own skill
  called `email` in the machine-wide skills directory, the update leaves yours
  in place, installs nothing under that name, and says so on every update.

- **Your claw's admin can now check whether anybody's shell startup files
  export a password-manager token.** A line like that in a `.bashrc` puts the
  token into every shell the person starts, where one careless command can
  print it. Ask a session to run the claw-ops skill's startup-token check. It
  lists each person, file, line number and variable name, and never the value.
  It changes nothing.

  **What you have to do: nothing.** If the check names a line in your files,
  remove it. Your sessions read secrets through the claw's own reader.

- **The claw-ops skill now says how to install a skill for everybody on the
  claw, and how an update treats that install.** A skill you install by hand
  under a name the update does not ship stays in place through every update.

  **What you have to do: nothing.**

- **The wake rail and the message bus now come from the published skills
  library.** A session that starts a helper session now hands it the claw's
  shared bus, as your claw's settings name it. The wake rail keeps reading its
  settings from `/etc/commonclaw/bus-nudge.conf`. Its program gains one
  refusal: on a machine without a process table it refuses to start and says
  so. Every claw has a process table, so the rail runs as before. It restarts
  on its new program during the update.

  **What you have to do: nothing.**

## Errata for release 1.5.0

Published notes cannot be edited after the fact, so the correction is here.

**1.5.0 says that what arrives at the firm's address is carried to the sessions
whose work it is.** From 1.5.0 through 1.6.1 that did not happen for a received
mail, as the first item above says. A mail sent to the address in that time is
still at the provider, and no session received it.

## What somebody has to do

**On a claw that has a mail address, set `MAIL_ALERT_TO`** as the second item
says.

**Whoever applies this release by hand passes `--now` on a claw pinned to manual
updates.** A claw that updates on its own takes this release on its next
scheduled run.

This release changes nobody's groups, so nobody has to end a process or reopen
the app because of it. The mail service and the wake rail restart on their own
during the update.

The steps earlier releases named still stand: put this claw's channel webhook
into its vault, and enrol this claw's dead-man check. For a firm that wants an
address: put the provider key into the claw's own machine vault, then make the
address once with `email inbox create --username NAME`.

Nothing here moves either core for anybody, and no core floor changed.
