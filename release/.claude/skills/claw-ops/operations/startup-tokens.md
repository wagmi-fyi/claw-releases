# Startup Tokens

**Required role: `claw-admin`.** The check reads every person's shell startup files, and only root reads another person's home.

Answer which people's shell startup files set or export a 1Password token.

## Why it matters

The claw keeps its agents token in one root-owned file, and a session is told where that file is. A line in a person's `.bashrc` or another startup file can still export a token of its own. Every shell that person starts then carries the value, and one careless command prints it into a transcript. The agents token door removes the per-home copy it knows the path of. A line somebody wrote by hand stays.

## What it reports

One entry per hit, grouped by person: the file, the line number, and the variable's name. A claw with no hit reports `none`. The line and its value are never printed.

It reads the startup files a login or an interactive shell reads, for bash, zsh and fish. A comment does not count. A file that is absent or unreadable is skipped.

## Execution

Run `scripts/startup-tokens.sh --help`, then run it. It writes JSON on stdout and changes nothing.

The survey is the agents token door's own, run with `--survey` through the grant that door already holds. Only the door reads a home. The function that reads the files lives with the door, so there is one copy of the rule.

## Reading the result

A hit is a note. The check cannot tell whose token the line exports. Tell the person which file and which line. The person removes the line and uses `/opt/commonclaw/bin/op-agents` for a read. If the value is this claw's agents token, it has been in their sessions and in their home's snapshots, so rotate it through the door.

## When the door is closed

Two answers, and the script distinguishes them:

- The caller is not in `claw-admin`. The claw's own admin runs this, or grants the role first.
- The grant is absent. It is repaired from the provisioning plane.

Neither is worked around. Report which one it is.
