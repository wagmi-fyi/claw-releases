# {{WORKSPACE}}

The work for **{{WORKSPACE}}** on `{{HOSTNAME}}`. The group that owns this
directory is `{{GROUP}}`.

This file is read by every core. `AGENTS.md` is a symlink to it, so there is one
briefing, never two that drift.

## Never write a credential into a file here

This directory is git-initialized, backed up, and group-owned. A secret written
here is committed, kept in snapshots after you delete it, and readable by
everyone in `{{GROUP}}`. Deleting the file undoes none of that.

This is a property of the directory, not a rule somebody chose. It holds
whatever else changes.

## Read the claw conventions for everything else

`/etc/commonclaw/workspace-conventions.md` says where a credential does come
from on this claw. It holds every other rule a workspace here follows.
Provisioning installs that file on every run, so it is current.

This briefing restates none of it. A mechanism named in two places drifts in one
of them, and the drift is silent.

## Replace this file

This is a scaffold, not a briefing. Write what the work actually is: what the
databases hold, which skills matter, what a good result looks like, and what
this workspace must never do.

Keep the two sections above. A session that lands here reads this file, and from
here it is one hop to the conventions it must follow.
