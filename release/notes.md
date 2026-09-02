- **Your claw has swap now, and something that acts before it runs out of
  memory.** On 2026-09-01 a claw filled its memory, started thrashing, and
  stopped answering ssh for half an hour. Nobody was told, because nothing on
  the box was watching and nothing off it noticed the silence. Three things
  changed and this is all of them.

  **A swapfile, sized at the machine's own memory, never smaller than 2 GB and
  never larger than 8 GB.** It is a cushion, not more memory: what it buys is
  the minutes between a session running away and the box becoming unreachable.
  A claw that already had swap keeps exactly what it had. A claw whose disk is
  too full to hold one is told so and given none, because a swapfile that fills
  the disk takes the machine down a second way.

  **A guard that ends one runaway process instead of letting the machine seize
  up.** It picks the largest, which is nearly always the thing that ran away,
  and it leaves everything else you have open alone.

  **An alarm, every five minutes, into the channel this claw posts to.** It says
  so when available memory drops below fifteen percent or swap goes past half
  full, and it repeats at most once every six hours while the condition lasts.

- **Something off this claw now notices when it goes quiet.** The same
  five-minute beat makes one request to a heartbeat check that lives somewhere
  else. When the requests stop, that check raises the alarm. This is the half an
  on-box alarm cannot do: a box that is thrashing, off, or gone posts nothing,
  and silence from something running on the box reads exactly like health.

  Standing that check up used to be four steps done by hand, per machine, and it
  had been done zero times. It is now one command on the operator's side, which
  makes the check, points it at your alarm channel, and hands the claw its own
  address; and one command here, which files that address in this claw's vault
  and proves the claw can read it back before destroying the copy.

  That address is a credential. Whoever holds it can silence the alarm by
  pinging it themselves, or pretend this claw is healthy. It is handled the way
  the channel webhook is: it lives in the vault, it is resolved at the moment it
  is used, and it never rests on the claw in readable form. It appears in no
  command, no log line and no message.

- **Your claw now installs the thing its own checks talk through.** Every check
  on this machine could already find what it was built to find, and every one of
  them wrote what it found to a journal nobody reads. The poster that carries a
  finding to your channel existed and nothing put it on a claw, so a freshly
  built machine had producers with nothing to call. Provisioning installs it
  now, with its two settings files beside it. Neither file holds the webhook: it
  stays in this claw's vault and is fetched at the moment a message goes out.

  A copy somebody placed by hand is kept when it matches what the release
  carries, and replaced when it does not, and the run says which of the two it
  did.

- **This claw says out loud when a piece of work stopped being read.** The
  message rail is files. One session writes a report into another session's
  inbox and tells nobody, so it waits until somebody happens to look. When the
  session that owns the inbox has ended, nobody looks, and in August three
  pieces of work sat that way for days.

  Once an hour the claw checks whether anything that coordinates work has mail
  it has not read for more than three hours, and posts the names and the ages to
  your channel. It never posts what the messages say. A run that is being read
  normally is left alone, and the same stall says so once a day rather than
  every hour.

- **A session here learns it has mail instead of finding out later.** The wake
  rail was built and nothing installed it. Provisioning now stands it for every
  person on the claw. It tells a live session, in one fixed sentence and nothing
  else, that mail is waiting. It carries no instruction, so a stale one costs a
  moment and can never put work into your session.

  The program itself also moved house in this release. Its source now sits with
  the rest of the tools that coordinate work, and a release picks it up from
  there. One copy either way, so your claw carries what it carried and the
  sentence is the same sentence. The reason to mention it at all is that the
  release digest changes because of the move.

- **How work is coordinated here is a setting on the machine rather than
  whatever each session happens to hold.** One file at
  `/etc/orchestrate.conf` records which shared rail the sessions use, what kind
  of machine this is, which model a delegated session runs on, and whether a
  delegated session stops to ask before acting.

  The first two are facts about this claw, so every run asserts them. A rail
  that moved and a file that did not is a claw whose sessions register somewhere
  their coordinator is not reading, and that reads exactly like a quiet rail.
  The last two are your decisions. They are written once and kept exactly as you
  leave them, so an update cannot put a firm back on a fleet default with
  nothing saying so.

- **Your claw's changelog now records every release an update crossed, not just
  the last one.** When a claw is several releases behind, one update moves it
  all the way to the newest release in one step. Everything in the releases it
  passed over landed on your machine, and until now the changelog only carried
  the newest release's notes. A machine that jumped five releases told you about
  one of them.

  After an update lands, your claw reads the notes of every release it passed
  over and writes one changelog entry for each, oldest first, with that
  release's own class and the words its author wrote. Each of those entries
  opens by naming the update it arrived on, so you can see at a glance that they
  all landed together on the same day. They sit below the newest release's
  entry, because that one is written while the update is still running and these
  are written after it has finished.

  Nothing is written if the update did not finish. An entry in this file means
  the release landed, and that stays true. If your claw cannot reach the release
  repository afterwards, the entries it could not fetch are simply missing and
  the machine's log says which ones, rather than the update failing over a
  record.

  If your claw was one of the ones that jumped several releases before today,
  this release does not go back and fill them in. It fills in every crossing
  from now on.

- **`commonclaw-update.sh --check` now really changes nothing.** It reports what
  release is on offer and always said it wrote nothing, and it was quietly
  leaving a record of the check in `/var/log/commonclaw/updater/` on its way
  out, creating that directory if the machine had none. Asking a question should
  not move the thing you are asking about. It now writes nothing at all, and
  there is no second log to reconcile: the answer goes to the system journal and
  to your screen.

- **An update keeps its own progress log.** Your claw already kept the
  machine-readable result of every update in `/var/log/commonclaw/updater/`. It
  now keeps the full output of the run beside it, under the same timestamp, so
  the two read side by side. If an update ever fails, whoever looks into it has
  the account of what the run was doing and not only which check went red.

- **A correction to release 1.3.0's notes.** That release's section on turning
  wide mode on says to run the update by hand passing `--wide-mode on`. No
  updater accepts that flag, and none ever will: an update must not be able to
  move that switch. What 1.3.0 meant is two runs. First the ordinary update,
  which fetches the release, verifies it and applies it. Then one provisioning
  run out of the tree that update just left on the machine, carrying the same
  arguments plus `--wide-mode on`. The first run records the new release; the
  second records and lays the grant. Published notes cannot be edited after the
  fact, so the correction is here.

## What somebody has to do

Two of the rails above stay quiet until a person acts. Neither one fails a run,
and neither one makes noise about being unwired.

1. **Put this claw's channel webhook into its vault, and post one message to see
   it arrive.** Until that is done, the memory alarm and the stall report have
   nowhere to go. They run, they find what they find, and nothing leaves the
   box.

2. **Enrol this claw's heartbeat check.** One command on the operator's side
   makes the check and points it at your alarm channel. One command here files
   the address. The claw's own vault account needs permission to write to that
   vault; read alone is what such an account ships with, so a refusal at the
   second step is the ordinary first answer rather than a fault. Where the
   account cannot write, the address is filed from a machine that can. Until
   both halves are done, the five-minute beat skips the heartbeat in silence:
   no error, no noise, and no off-box cover.

Nothing here moves either core for anybody, and no core floor changed.
