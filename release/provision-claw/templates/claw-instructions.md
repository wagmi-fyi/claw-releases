# This claw

Sessions here load this file automatically. Every word in it is paid for on
every turn, by everybody it reaches. Keep it short. What is true of one
workspace belongs in that workspace's own briefing.

## Never write a credential into a workspace

A workspace is git-initialized, backed up, and group-owned. A secret written
there is committed. It stays in snapshots after you delete it. Everyone in the
group can read it. Deleting the file undoes none of that.

## Never two copies of anything

One instructions file. One skills directory. The other convention is a symlink
to it, and `AGENTS.md` beside this file is a symlink for that reason. Two files
that say the same thing drift, and the drift is silent.

## A directory here with no manifest is unfinished work

`.workspace.yaml` is what makes a directory a workspace. Report a directory
that has none. Do not make one by hand. Do not work in one.

## A group change reaches a person at their next login

An existing session keeps the groups it started with. Access that fails
immediately after a grant is usually this, and not a fault.

## Everything else

`/etc/commonclaw/workspace-conventions.md` holds every mechanism this claw
uses, including where a credential does come from. Provisioning reinstalls that
file on every run, so it is current. This file restates none of it.

## Write what this claw is over the rest

Say what the firm does and how work is done here. Keep the four sections above:
they are what a session has to hold before it acts, and this is the only place
that hands them over without being asked.
