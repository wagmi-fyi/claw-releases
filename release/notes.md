- **A secret is now read with one command, and the token is no longer sitting in
  your shell.** Until this release every session on a claw started with the
  broker token in its environment. Anything that printed a variable could print
  it, and a printed credential lands in a transcript the backup rail keeps for
  the whole retention window. Deleting the transcript afterwards reaches none of
  the copies. This release takes the value out of every session and puts the read
  in one place.

  **What changes for a person.** A bare `op read` stops working. Read a secret
  with the claw's own command instead:

  ```
  /opt/commonclaw/bin/op-agents read "op://<vault>/<item>/<field>"
  ```

  It takes the token from the claw's file inside that one command and hands it to
  the manager. Your shell never holds the value. Every argument goes through
  unchanged, so anything you could type after `op` you can type after
  `op-agents`. Without the wrapper the same read is one line:

  ```
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "$COMMONCLAW_AGENTS_TOKEN_FILE")" \
    op read "op://<vault>/<item>/<field>"
  ```

  **What changes for a session.** The same thing, and nothing else. An agent
  session is told where the token file is, in `COMMONCLAW_AGENTS_TOKEN_FILE`, and
  is never told what is in it. That variable holds a path, so printing it,
  grepping for it and expanding it are all safe.

  **There is nothing to reconnect after a rotation, and that is new.** No session
  holds the value, so each read takes the file as it is at that moment. A session
  you opened this morning resolves a token rotated this afternoon. Before this
  release a rotation reached a session only when that session restarted.

  **You do not have to do anything.** The apply rewrites the loader in every home
  on the claw and installs the command. A person who had the old shape gets the
  new one on the same run. A session you already have open keeps the value it
  started with until you close it.

  **Nothing about who can read the token changed.** Membership of `agents-cred`
  is still the whole access model, the file is still `640 root:agents-cred`, and
  it still rests outside every path the backup rail captures. Somebody outside
  that group still resolves nothing.

  **The claw's own services changed the same way.** The memory check, the
  notifier and the mail gatekeeper each read their token out of a file at the
  moment they use it. None of them takes a credential out of an inherited
  variable any more, so running one by hand under `sudo` can no longer resolve
  with whatever token your own session was carrying.

- **Releases stop waiting for the quiet window on a claw with the mail service,
  and the mail service's account loses what it was given by mistake.** Your
  claw keeps one group for everybody who works on it, and since 1.5.0 the mail
  service's own account is in that group too, because that is how it posts to
  the session bus. Parts of the update read the group as the list of people on
  your claw. So they asked the mail account for its Claude Code version, found
  none, and held every release for the 04:00 to 06:00 window. A second update
  on the same release went further and set the mail account up like a person:
  a Claude Code install, the file that loads your claw's credentials, access to
  the claw's vault token, and a unit that watches for bus mail.

  From this release your claw tells a person from a service by the account's
  number. People get numbers from 1000 to 60000. Services are made with numbers
  below that. Every part of the update that means "the people on this claw" now
  asks that question first.

  **What you see on the next apply.** The people step names each thing it takes
  back from the mail account, one line each, and says how many. The mail
  service keeps its messages, its routing table, its logs and its settings
  exactly as they are, and it is not restarted. A second apply takes back
  nothing and says so. On a claw that never had the mail service, the step says
  there is nothing to take back.

  **One more release waits, and it is this one.** Your claw decides whether to
  wait for the window using the update program it already has. So on a claw
  with the mail service, this release itself still waits for the window, or for
  an operator who applies it by hand with `--now`. Releases after this one are
  decided by the fixed program and do not wait on the mail account.

  **What you have to do: nothing.** The mail account stays in the shared group,
  because it still needs to post to the bus. A process already running as the
  mail account keeps the access it started with until it restarts. Nothing in
  this release needs that restart.

- **A change to your claw's routing table now reaches the mail service straight
  away.** The routing table is the file that says which desk a message goes to
  and what your claw's own address and communication runbook are. It has always
  been the record. Until this release the service read it once when it started
  and answered from that copy for as long as it ran, so an edit you made by hand
  was invisible until somebody restarted the service. The documents told you to
  edit the file and did not tell you it would not be read.

  The service now checks the file before every command it answers and before
  every mail it routes, and re-reads it whenever the bytes have changed. An edit
  made by hand takes effect on the next thing that happens. Nothing has to be
  restarted.

  Measured on staging on 2026-09-08: with the file on disk holding one value,
  `email self` answered the old one until the unit was restarted.

  **What to do.** Nothing. A claw takes this on its next update, and your
  routing table is not rewritten by an update.

- **`email self clear runbook` puts the recorded runbook path back to empty.**
  `email self set runbook <path>` records where your firm's communication
  runbook rests. There was no way back through the command, so the only road to
  an empty field was editing the file. Now the command says both directions.

  An empty argument to `set` is still refused. Clearing a field is something you
  say on purpose, and a caller whose variable came out empty did not say it.

  Your claw's own address has no such verb, and that is deliberate. The address
  is in every `From:` line anybody who writes to you ever sees, so changing it
  means telling everybody who holds the old one. Editing the file is the slow
  door that step deserves, and the service now picks that edit up on its next
  reading.

- **A write by the command leaves the file in the shape the release seeded it
  in.** The service used to sort the table's fields when it wrote, so the first
  write moved `self` past three of its siblings and every later comparison
  carried that move. Every write now goes through one function that keeps the
  order the shipped template carries. A table your claw has written and the
  template it was seeded from differ only where a value differs.

  **What to do.** Nothing. A table already written in the old order is put back
  into the template's order by the next write the command makes.

- **You can type `email` and reach the command.** `/opt/commonclaw/bin` is on
  nobody's PATH, in a login shell or out of it, so a member who followed the
  release notes and typed `email inbox create` got `command not found`. An
  apply now links `/usr/local/bin/email` at the command, which is a directory
  every shell on this system already searches.

  The directory itself stays off PATH. Everything else in it, the credential
  broker included, is still reached by its full path, so nothing a session
  inherits decides which program a read gets. One link, for the one command a
  person types.

  A file somebody put at `/usr/local/bin/email` is left exactly as it is, and
  the apply says so in a note rather than replacing it.

  **What to do.** Nothing. A claw takes this on its next update.

- **A refused mail call now tells you what the provider said.** The part that
  talks to your mail provider reports its cause under one name and the service
  read another, so `email inbox create` against a key the provider rejects
  answered "no reason given". The same refusal told root, through a command
  only root can run, that the account answered 403.

  The service now reads the cause the provider's adapter actually writes, so
  the sentence reaches whoever typed the command.

  **What to do.** Nothing.

- **An update that holds a release back now says so in its exit status when a
  person was watching it.** A claw defers a release to the quiet window when
  applying it would replace a core somebody could be working in. That is the
  rail doing its job, and a scheduled update that defers still reports success,
  the way it always has. What changed is the case where an operator ran the
  update by hand: it now returns 3 instead of 0, so a person or a script reading
  only the status cannot take a run that applied nothing for a run that landed
  the release. The line the update prints is word for word what it printed
  before, and the record it writes carries the same verdict.

  **What you have to do: nothing.** If you never run updates by hand, the status
  your claw reports is unchanged. If you do, an update that returns 3 has
  changed nothing on your box and its message says when it will land. Pass
  `--now` to take the release straight away.

  The update that applies this release is the one your claw already carries, so
  the new status arrives with this release and is first used by the next one.

- **A channel pointer no longer carries a written note.** The file the release
  rail publishes for each tier is what tells your claw which release to take. It
  used to carry a paragraph somebody wrote by hand alongside the version, the
  tag and the checksum. That paragraph described the same release the release's
  own notes describe, nothing kept the two in step, and once published it could
  not be corrected. It is gone, and the pointer now holds machine fields only.

  **What you have to do: nothing.** Your claw never read that field. What a
  release is stays where you already read it: these notes, and the changelog
  entry your claw writes when the release lands.

## Errata for releases 1.5.0 and 1.5.1

Published notes cannot be edited after the fact, so the corrections are here.

**Both releases show `email` as a command you type, and on every claw that took
them it was not found.** Their notes give `email inbox create` and
`email self set runbook` as the steps a firm takes. The program was installed
at `/opt/commonclaw/bin/email`, and that directory is on no shell's PATH, so the
bare name answered `command not found`. The full path worked the whole time.
From this release the bare name works as the notes said.

**1.5.1 describes the mail account's effect on updates as a delay alone, and a
second update did more.** Its notes say a claw carrying the mail service takes
its updates in the early morning and that nothing is skipped or fails. That part
holds. They do not say that a second update on the same release set the mail
account up like a person: a Claude Code install in its home, the credential
loader, membership of the group that reads the vault token, and a bus-mail
watcher. Measured on the hub on 2026-09-08. This release takes each of those
back, as the second entry above says.

## What somebody has to do

**The operator who applies this release by hand passes `--now` on a claw that
carries the mail service.** The choice to wait for the window is made by the
update program the claw already has, which is 1.5.1's, and that program still
reads the mail account as a person with no Claude Code. So this one release
still defers on such a claw, whatever it declares. `--now` is the flag the rail
carries for a person standing at the box, and it also walks past a claw pinned
to manual updates. Read the verdict line the update prints as well as its exit
status: the program deciding this ride is the one that still returns 0 when it
defers. Releases after this one are decided by this release's program, which
tells a person from a service by the account's number, and they do not wait on
the mail account.

The two items 1.4.0 named still stand: put this claw's channel webhook into its
vault, and enrol this claw's dead-man check. The two mail steps 1.5.1 named
still stand for a firm that wants an address: put the provider key into the
claw's own machine vault, then make the address once.

Nothing here moves either core for anybody, and no core floor changed.
