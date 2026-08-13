# {{WORKSPACE}}

The work for **{{WORKSPACE}}** on `{{HOSTNAME}}`.

This file is read by every core. `AGENTS.md` is a symlink to it, so there is one
briefing, never two that drift.

## Layout

| Path | Holds |
|---|---|
| `.workspace.yaml` | the manifest: the group, the creation record, the channel binding |
| `database/` | structured state. Git-ignored: the backup rail protects it, git cannot merge it. |
| `_workpapers/` | running state, one file per workflow |
| `.claude/skills/` | this workspace's expertise. `.agents/skills` is a symlink to it. |
| `.venv/` | the virtual environment |

## Rules

- Run python through `.venv/bin/python`, not the system interpreter.
- This directory is shared. Every member of `{{GROUP}}` works here.
- Commit your work. This is a git repository, initialized group-shared.
- **Never write a credential into a file here.** Connections arrive through the
  connection services under `/srv/connections/`, which hold the secrets so no
  agent has to.

The claw-wide conventions every workspace follows are at
`/etc/commonclaw/workspace-conventions.md`.

## Replace this file

This is a scaffold, not a briefing. Write what the work actually is: what the
databases hold, which skills matter, what a good result looks like, and what
this workspace must never do.
