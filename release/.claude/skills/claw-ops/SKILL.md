---
name: claw-ops
description: "Operate a claw from inside it. Use when somebody on a claw needs a new workspace for a domain of work, when asking which workspaces exist and who reaches them, when checking the backup rail's last run, when checking whether a core login is about to lapse, when asking which core seats this claw expects, or when a seat that has gone has to come off the roster."
---

# Claw Ops

The on-claw plane. This is what the firm's own people run from inside their claw, through their own agent, in their own session.

A **claw** is one firm's Linux machine. **CommonClaw** is the project. A claw is provisioned and repaired from outside it; everything here happens from within, by the people whose work lives there.

## Activation

1. Read `reference/authority-model.md`. It carries the two roles, the door a privileged operation goes through, and what each role can observe.
2. Establish the role the caller holds. Group membership answers it, and `scripts/claw-status.sh` reports it.
3. Open the operation. Each one states its required role in its header.

## Operations

| Operation | File | Role | Use When |
|---|---|---|---|
| Bootstrap a workspace | `operations/bootstrap-workspace.md` | `claw-admin` | A domain of work needs its own directory, group, manifest, and members |
| Claw status | `operations/claw-status.md` | `member` | Somebody asks what exists on this claw, who reaches it, or whether the rail and the seats are healthy |
| Seats | `operations/seats.md` | `member`, `claw-admin` to retire | Somebody asks which core seats this claw expects, or a seat this claw expects has gone and its row has to come off |

## Reference

| Reference | File | Precondition |
|---|---|---|
| Authority model | `reference/authority-model.md` | Before any operation. The roles, the door, and the limits of what each role can see |

## Scripts

Agent-invoked. Structured JSON to stdout, progress to stderr, `--help` on each. The JSON is the result.

| Script | Job |
|---|---|
| `scripts/bootstrap-workspace.sh` | open the door, then run the claw's own scaffold behind it |
| `scripts/claw-status.sh` | read this claw's state from what the caller can reach |
| `scripts/seats.sh` | read the seat roster and the seat check's own recent verdicts |
| `scripts/seats-retire.sh` | open the door, then run the claw's own seat retirement behind it |

## What is proven

Every operation is unproven until a claw runs it, and a change proves itself at each tier before it reaches the next. What each one has actually been through is recorded in that claw's own run ledger on the provisioning plane, not here — a proof list kept in a skill goes stale the moment somebody promotes a change.

Report the outcome of a first run rather than assuming a step worked. An operation whose ledger carries no run is unproven, whatever it looks like on the page.

## Dependencies

| Needs | Why | Verify |
|---|---|---|
| `jq` | Builds this skill's JSON and reads expiry fields without reading values | `jq --version` |
| `sudo` | The door to a privileged operation. The grant itself is installed at provisioning | `sudo -n -l` |
| `systemctl` | The rail's last run comes from unit state | `systemctl --version` |
| the claw's own seat check | It is the one reader of the roster's grammar, and the seats operation asks it rather than parsing that file a second time | it answers `--state` |

## Limits

This skill must not:

- Do root work of its own. A privileged operation calls the claw's own root-owned script through the sudo door, and there is no second implementation of it here.
- Provision or repair the claw. That plane runs from outside and holds its own skill.
- Read another person's home, credentials, or session history.
- Print, log, or carry a credential value. Expiry fields and lengths only.
- Report something it could not observe as absent. Unreadable and missing are different answers.
