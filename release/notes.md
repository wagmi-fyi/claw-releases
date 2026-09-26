- **An orchestrator resumes its method after a compaction.** A compaction is
  when a long conversation gets summarized to make room. Within two minutes, a
  running orchestrator session gets one fixed turn:
  `/orchestrate full resume operation please`. A new hook loads the
  orchestrate skill when that exact turn arrives. A session that has stopped
  is started again with that turn. If its workpaper has not changed thirty
  minutes later, one line goes to the `human` handle.

- **A running orchestrator is told to write down what it holds.** After two
  hours of work, or at half the compaction point, it gets one turn asking it
  to write its standing rules and the skills in use into its workpaper. A
  quiet session is told nothing.

- **Long sessions compact at 600,000 tokens**, sixty percent of what Fable and
  Sonnet 5 hold. A Haiku session keeps compacting at its own smaller limit.
  The update writes the number into your own settings only where you have set
  none. To change it, set `autoCompactWindow` in `~/.claude/settings.json`.

- **The claw tells you when you are signed out.** Once an hour it asks each
  account's harness whether it is signed in. When one is not, a line goes to
  the mail alarm address, and to the claw's alert channel where one is set.
  The line repeats each day it lasts.

- **The claw's filing rules sit in one file everyone can edit.**
  `/srv/workspaces/project-conventions.md` says where projects live and what
  they are called. The update writes it where none exists and leaves an
  existing one alone.

- **A scheduled job now reaches a workspace its owner was granted after their
  last login.** A person's service manager keeps the access it started with.
  The update restarts one that is out of date when that person has no session
  open. When they do, the update's log names them and the command to run.
  Scheduling a job that hits this now says why it failed.

- **Your agent can tell you what the continuity rail did.** That rail is the
  claw program that watches orchestrator sessions. It reports each one's last
  wake, last start and any sign-in wait.

- **The email orchestrator starts under the orchestrate skill.** The first
  two bullets cover it.

## Changes with no visible effect

Print-mode sessions no longer register on the bus. The rail writes one journal
line per act. `/etc/orchestrate.conf` names the continuity rail. The release
tool writes its own two-line message when it moves a channel.

## What somebody has to do

Most claws need nothing from a person. This release changes no groups and moves
no core.

An orchestrator whose starting directory holds several workpapers needs its
owner to name one, once:
`/opt/commonclaw/bin/session-continuity --set-workpaper <handle> <path>`.
The rail's line to `human` names the handle when it cannot tell.

Whoever applies this release by hand passes `--now` on a claw pinned to manual
updates, and passes `env -u SSH_CONNECTION` when riding over ssh.
