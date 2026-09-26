# The wake rail

The session bus is files. A session writes a report into an inbox and announces
it to nobody. The reader finds it when it next looks, and an idle session never
looks again. This rail closes that gap for the sessions that are still running.

`bus-nudge` watches the buses on the machine and tells a live session that it
has unread mail. That is all it does.

## The law it runs under

**One sentence, and nothing else.** The rail may deliver exactly one string,
which names a bus directory and says nothing more. Run `bus-nudge --law` to see
it and to prove it carries no other interpolation; the check is a command, so
nobody has to take the claim on trust. The program refuses to start when the
check fails.

**The bus stays the only input.** A nudge carries no instruction, no subject and
no body. A session that receives one reads its own inbox, and the inbox is what
it acts on. A wrong or stale nudge costs a turn and can never inject work. The
rail also writes nothing to a bus: a rail that recorded its own failures into an
inbox would raise unread mail, which would raise a nudge, which would raise more
mail. Failures go to the log.

**Same user.** A handle is nudged only by a process running as the account that
registered it. Everything delivery needs is written by the session under its
owner's account at mode 0600, so this is what the file permissions already say.
The rail states it as a refusal so that a root instance cannot quietly widen it.

**Never resurrect.** A handle whose process is gone is refused. Restarting a
recorded session makes a second, divergent copy under a new process; the
original does not come back.

**Never retry into spam.** One nudge per handle per newest message. A session
that was nudged and did not read gets nothing more until new mail arrives.

## The opt-in, and what it permits

A session holds a message from a sender that cannot attest its permission mode
and waits for a person to approve it. A rail with no screen cannot answer that
prompt. So the installer sets `crossSessionInbound` to `accept` in the machine's
managed settings, which is the ruling this claw runs under: every session opts
in.

What that permits is a local process, holding a session's own 0600 auth key,
writing one turn into that session. It opens nothing off the machine and it
crosses no account. A repository may tighten the setting for sessions started
inside it, and a session that does is refused before anything is sent.

## Core and adapters

The core knows about buses, accounts, processes and one sentence. It knows
nothing about how a session is reached, because the transport is the thing that
differs per machine. Delivery is an adapter, and the adapters sit beside the
program. Each answers the same three questions: deliver the fixed text to a live
consenting session, refuse the dead without resurrecting them, fail loudly when
the transport changes.

Which adapter runs resolves in one order: the command line or the environment,
then the machine conf, then detection. Nothing left to resolve is an error. A
declared substrate whose adapter is absent is refused by name, because a rail
that quietly delivered nothing would read exactly like a quiet bus.

The machine conf is `/etc/commonclaw/bus-nudge.conf`, which is the file the
installer writes and the file a claw-admin edits. The program reads that path by
default, so a hand run of `bus-nudge` reads what the service reads.
`BUS_NUDGE_CONF` in the environment points it somewhere else, which is how a
setting is tried before it is written down.

A live tmux server on an account counts as a session. Detection asks `claude`
first and `tmux` next, so an account with nobody signed in to a core and one
tmux server left running from weeks ago resolves `tmux`, and the rail delivers
into that pane rather than reading the account as idle. The pane gets the same
one sentence. Closing that server is what makes the account idle. `bus-nudge
--check` names the adapter it resolved, so it answers which of the two states an
account is in.

## Install

`scripts/install-bus-nudge.sh` stands it, one systemd instance per account, each
running as that account. Its header says what it installs and what it adopts
rather than overwrites. It is idempotent, and an instance somebody disabled
stays disabled.

The install also records where this machine's shared bus is, at
`/etc/orchestrate.conf`, taking the path the machine already keeps for its
sessions. The rail asks for that path rather than carrying one, so a program
that runs on any machine does not name this one. A file that is already there is
kept as it is.

The service is long-running rather than a timed beat. An idle session's
supervisor exits about a minute after the session goes quiet, so a nudge that
waits for the next beat arrives at a process that has already gone. The timer
beside the service exists only to start it again if systemd ever gives up on
restarting it.

## Generations, the guard and the sweeper

The desktop app can reconnect a conversation under a new process and leave the
old process running. Both carry one session id. The old one holds the
transcript open and takes a turn whenever something wakes it. Each of those
processes is a generation of the session.

**The nudge goes to the newest generation.** Where the harness records its
sessions, the rail sends a handle's nudge to the newest running process that
carries the handle's session id. Newest comes from the kernel's start time for
each process. The older ones get nothing, and the rail's log names each by pid
and start time. Where no record names the session, the pid the handle
registered with decides.

**A session can ask whether it was replaced.** `session-guard` prints `live` or
`superseded` and exits 0 or 1, with its reason on stderr. Superseded means a
newer process carries the same session id. A session that reads superseded
stops acting and says so once. The orchestrate skill runs the guard first on
every resume and every beat, and tells each delegate it spawns to do the same.
The rail and the sweeper load the same file, so all three agree on which
process is newest.

**The sweeper ends the old generation.** `session-sweep` runs every five
minutes as the account, under its own timer, `session-sweep@<account>.timer`.
It sends SIGTERM to an older process once a newer process of the same session
has run for the grace period and holds its session socket open. A background
agent is left running, because its harness starts a killed one again from the
transcript; `claude stop <id>` retires one of those. The grace period is
`SWEEP_GRACE_SECS` in the machine conf, 300 seconds as shipped.
`session-sweep --dry-run` shows what a pass would end, and `--check` shows the
grace period and where it came from.

Disabling the timer switches the sweeper off, and a later install leaves it
off. The rail's `ENABLED` setting does not reach it.

## The continuity rail

The rail above reaches only sessions still running. An orchestrator is a
registration and a workpaper, and its process is not part of it, so the session
mail waits for has often gone. `session-continuity` starts it again, every two
minutes as the account, under `session-continuity@<account>.timer`. It also keeps
a live orchestrator writing down what it holds, and re-grounds a compacted one.

A pass resumes each orchestrator handle this account owns that has unread mail,
from its recorded session id and directory, with one fixed turn:
`/orchestrate full resume operation please`. A turn a resumed session starts with
expands into the skill. Written into a live session they arrive as words, so a
hook there loads the skill. `--law` proves each fixed sentence interpolates
nothing, and refuses to run otherwise.

**Two resume forms, and the listing says which.** Flags passed to a resume of an
already-backgrounded session start a copy under a new id. One with a background
row is resumed bare; one with no row takes the flags.

**The twin check comes before every resume.** Nothing is resumed while a live
process carries the handle's session id, or a live session its name. Either means
the session is here, and it is nudged instead.

**The forced write.** A live orchestrator is told to write its postures and its
skills in use to the workpaper after two hours of its own activity, or once its
last turn passes half the automatic compaction window. Activity is the transcript
growing, so a quiet session owes nothing. The rail then reads whether that file
moved; unmoved after thirty minutes is a line in the human's queue.
`--set-workpaper` names it where the search cannot.

**After a compaction, the same turn.** A hook records each compaction. A live
session gets the turn through the wake rail's adapter, and the resume hook loads
the skill for that exact phrase. A gone session is resumed with it. An unmoved
workpaper thirty minutes later is a queue line.

**The rail ends what it started.** A resumed session does not exit by itself, so
a pass stops one once the listing reads it idle and its transcript has been quiet
fifteen minutes. `claude stop` keeps the conversation.

**A resume that fails writes a hold**, and nothing of that account is resumed
until `--clear-hold <handle>` clears it. A line goes to `human`.

## What fails silently here

- **A reconnect that changes the session id escapes all three.** The guard, the
  rail and the sweeper link processes by session id. When a conversation comes
  back under a new id, its old process reads as a session of its own. It stays
  until somebody ends it.

- **A stopped instance and a quiet bus look the same.** Nothing announces that
  the watcher is gone. `systemctl is-active` and `bus-nudge --check`, which
  reports the pids of any watcher already running for this account, are what
  answer it.
- **A session that opted in through a launch flag rather than a settings file is
  refused.** The consent check reads the files that decide the setting, and a
  flag leaves no file. The ruled shape is the machine-wide managed setting,
  which the check does read.
- **A nudge delivered to a session with nothing to do costs a turn.** The rail
  reads the cursor, so it fires only on real unread mail, and a handle whose
  session has ended is refused rather than nudged.
- **A shared bus nobody recorded is a bus nobody watches.** Where
  `/etc/orchestrate.conf` names no shared bus, the rail watches each account's
  own bus and nothing else, which reads exactly like a quiet shared one. The
  install says so when it finds that file already there without the entry, and
  `bus-nudge --check` reports the bus list it resolved.
- **A held account looks like a quiet one.** Once the continuity rail holds, no
  orchestrator of that account comes back and nothing else says so. The line on
  the `human` handle is the notice, and `session-continuity --check` names the
  hold.
- **Nothing watches this rail.** The same hole the notifier names about itself.
  Silence means healthy, and it also means the instance is off.
