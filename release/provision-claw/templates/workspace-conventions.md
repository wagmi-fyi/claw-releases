# Workspace conventions

Read this before you work under `/srv/workspaces`. Every agent on this claw follows it.

## What a workspace is

A workspace is a directory where one entire domain of work completes: one client, or one function.

Every workspace is a directory. Not every directory is a workspace.

A workspace holds the work, the state, and the expertise for its domain. Work that spans two domains belongs in two workspaces.

## Where things are

| Path | Holds |
|---|---|
| `/srv/workspaces/<name>/` | one workspace |
| `~/workspaces` | a symlink to `/srv/workspaces`, in every person's home |
| `/srv/connections/` | connection services, where this claw has any. These are not workspaces. |
| `/etc/commonclaw/` | the claw config, and the machine's own credentials, which no member reads |

Open `~/workspaces` to see everything you can reach. A folder picker starts at home, so that is one hop.

## The manifest

Each workspace carries `.workspace.yaml` at its root. The manifest is what makes the directory a workspace.

| Field | Meaning |
|---|---|
| `name` | the workspace name. It matches the directory. |
| `group` | the unix group that owns it, `ws-<name>` |
| `claw` | the claw it was created on |
| `created` | the creation date |
| `channel` | the chat channel bound to this workspace. Empty until somebody binds it. |
| `runtimes` | the shared language runtimes this work needs, for example `[node-22]`. Empty declares nothing. |

A directory under `/srv/workspaces` with no manifest is unfinished work. Report it; do not treat it as a workspace.

Bind a channel only when its members are the people you would hand this agent to. Everyone who reaches a bound channel reaches the work behind it.

## The layout

| Path | Holds |
|---|---|
| `CLAUDE.md` | the briefing for this workspace. `AGENTS.md` is a symlink to it. |
| `.claude/skills/` | this workspace's expertise. `.agents/skills` is a symlink to it. |
| `_workpapers/` | running state, one file per workflow |
| `database/` | structured state. Git-ignored, because the backup rail protects it and git cannot merge it. |
| `.venv/` | the virtual environment. Run python through `.venv/bin/python`. |
| `.git/` | version control, initialized group-shared |

This table describes a workspace root, and a git repository nested inside a workspace is a project that carries none of it.

**Never two copies of anything.** One instructions file, one skills directory. The other convention is a symlink to it. Two files drift into two briefings for one directory, and the drift is silent.

## Language runtimes

A runtime is installed once for the whole claw, under `/opt/commonclaw/runtimes`, and every member reaches the same copy. Declare what your work needs in the manifest's `runtimes` field; provisioning converges the machine to what the workspaces declare.

Do not install a runtime into your home or into this workspace. A copy per person helps nobody else, and a copy per workspace is the same waste one directory down.

**Your dependencies are still yours.** `node_modules`, `.venv`, lock files and any project-local toolchain stay inside the project that owns them. They change on your clock; the runtime changes on the machine's. The backup rail excludes the whole class, because it reproduces from what it was installed from.

`/etc/commonclaw/runtimes.md` says how to declare one, what happens the first time a claw is asked for a runtime it has never seen, and why the version on PATH may not be the one a shell already open is using.

## Access

A workspace is mode 2770 with setgid, owned by group `ws-<name>`, with default ACLs. Membership of that group is the whole access model.

Files you create inherit the group. Every member can write what another member created.

A group change takes effect on the person's next login. An existing session keeps its old groups.

## Credentials

**Never write a credential into a file in a workspace.** A workspace is group-owned, git-initialized and backed up, so a secret written here is committed, kept in snapshots after you delete it, and readable by everyone in the group.

Resolve what you need from this claw's agents vault, at the moment you use it. Config files carry `op://` references. They never carry values.

**A resolution that fails because this claw has no agents vault is the answer.** Say so and stop. Provisioning does not build one; the firm that owns the claw does. Do not go looking for a value somewhere else on the machine: what you would find is a credential resting where none belongs, and using it hides the gap instead of closing it.

A connection service is the better shape where a claw has one. It holds a secret under its own service user and hands a calling agent a capability rather than the credential, so the value never enters your process. A claw may have none, and then `/srv/connections/` is empty. That is not a fault.

## Git here

A workspace is a git repository from the moment it is scaffolded, and the group shares it. What follows holds in every repository on this claw.

**This claw is the system of record.** What is committed here is the work. A copy anywhere else is a mirror of this one.

**Commit before you park.** A session that changed a workspace commits before it stops. Work left uncommitted is invisible to the next session, which cannot build on it and can destroy it without knowing it was there.

**Batch.** One commit for one finished piece of work, not one commit per edit.

**Stage hunks, not the tree.** `git add -A` on a shared tree picks up whatever another session left half-written. Read what you are about to commit, then stage the changes you made.

**One worktree per concurrent editor.** Two sessions in one checkout collide on the index and on each other's unsaved files.

**Never amend, and never force-push, anything another session may already hold.** Rewriting shared history is the one act here with no clean way back.

**`main`, and branches that die young.** A branch that lives a long time diverges, and reconciling it costs more than the isolation bought.

**The repository is local.** Do not add a remote. Whoever operates the claw decides that, one repository at a time, and writes the reason into the repository.

### Who a commit is by

A person commits as themselves. That identity is set when the account is made, so no session has to guess it.

An agent commits as the seat it runs under and adds a `Co-Authored-By` trailer naming the model. The seat records which person is accountable. The trailer records that a model did the writing.

Publishing to a remote is a third identity's job, and it never happens from a workspace.

## Working here

Put expertise in `.claude/skills/`, not in the briefing. Keep running state in `_workpapers/`.

The operator scaffolds a new workspace. Ask for one rather than making a directory that no manifest governs.
