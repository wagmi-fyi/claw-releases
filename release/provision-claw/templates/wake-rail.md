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

## What fails silently here

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
- **Nothing watches this rail.** The same hole the notifier names about itself.
  Silence means healthy, and it also means the instance is off.
