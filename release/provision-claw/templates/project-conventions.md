# Project conventions

Where projects live on this claw, what one is called, what a project directory
holds, and where a launch may not go.

## The tree

Root: `/srv/workspaces`

The first level is **workspaces**, one per function. Each carries
`.workspace.yaml`, a unix group, and a briefing.

**A launch never creates a workspace.** The operator scaffolds one, because a
directory with no manifest is not a workspace. A launch that would need a new
workspace stops and asks for one.

The second level is a **family**, a directory inside a workspace grouping
projects of one kind. A workspace may have none.

A **project** is the leaf. It is the thing that finishes.

## Naming

Kebab-case, saying what the work is. No dates in a name.

## What a project directory holds

The project directory is the constant. Management state lives directly in it,
tracked by the workspace repository.

| Path | Created |
|---|---|
| `workpaper.md` | always. State, journal, and the boot sequence at its head. |
| `plan.md` | when the project runs as an orchestration |
| `action-items.md` | when the project is waiting on a person, Q-numbered |

Code sits in a repository nested inside the project directory, as `src/` or a
name that says what it is. The workspace repository ignores that directory,
because tracking it would record a commit hash holding no content. A repository
that pushes carries `REMOTE.md` at its own root saying what triggers the push.

Beyond the state files, a project directory holds its design and its archive.
A unit working on the project keeps scratch in its own job directory. Durable
evidence goes to `_workpapers/<unit>/` in the repository the unit changed, or
under the project's `archive/` when the unit changed no repository. A closed
unit's output moves under `archive/`. Nothing else lands in the project
directory.

## The index

Each family directory carries `CLAUDE.md`. Every project has one section in it,
headed by a sentence naming the project and what it is, followed by what a
reader needs before touching it.

The workspace's own `CLAUDE.md` indexes the families.

## Where a launch may not go

- Never a new directory under `/srv/workspaces`. That is the operator's act.
- Never a project at a workspace root where the workspace has families. It goes
  in the family that owns it.
- Never inside a nested project repository. Those carry their own history and
  none of the workspace layout.
- Never a second directory for work that already has one.
- Never a credential in any file here. The tree is group-owned, git-tracked and
  backed up, so a secret written here stays in snapshots after the file goes.

## Git

The workspace repository tracks the project directory and its state. It is
local, with no remote, unless the operator has written a reason into it.

A project's own code repository is nested and ignored. Commit before parking.
Stage hunks, not the tree. One worktree per concurrent editor.
