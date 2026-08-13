# Provisioning: {hostname}

**Project:** {project} · **Started:** {date} · **Operator:** {who}

The durability acceptance spans days, so this run outlives any one session.
Record outcomes here as they land, not at the end.

## Inputs (by name, never by value)

| Input | Value or reference |
|---|---|
| Claw address | |
| Timezone | |
| Object-store bucket | |
| Service-account token | operator-supplied. The claw cannot resolve it from a reference: resolving anything in that vault needs this token. It reaches the host-encrypted store by pipe, never rendered. The recoverable copy is the item the manager's own wizard offers to save at mint time, inside the claw's vault, which the owner's account reaches. |
| Repository password | `op://{hostname}/commonclaw-restic-{hostname}/password` |
| Object-store key | `op://{hostname}/commonclaw-backup-{hostname}/` — `username` is the key id, `credential` the secret half |
| Staff keys file | |

## Layers

| Layer | State | Evidence |
|---|---|---|
| Base | | |
| Identity | | |
| Credential plane | | |
| Cores | | |
| Durability: init + first backup | | |
| Durability: restore spot-check | | |
| Distribution | | |
| Monitoring: all three fail-path controls | | |
| Monitoring: the seat roster names the people it should, and nobody else | | |
| Monitoring: delivery verified | | |

## Two separate claims

**Provisioned** — the script reports `ok`, every human step is done, the restore
spot-check passed. Date:

**Protected** — the rail ran clean across the full acceptance window. Date:

These are not the same claim. A one-shot backup proof does not establish the
second one.

## Acceptance window

| Day | Runs green | Snapshots growing | Config versions stable | Usage under cap |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |

## People

| Person | User | Workspaces | Core 1 login | Core 2 login | Phone |
|---|---|---|---|---|---|

## Unproven steps exercised

Every step marked unproven in `reference/evidence-base.md` that ran here, and
what happened. A step that survived its first real run stops being unproven —
update the ledger, that is the point of it.

| Step | Outcome | Ledger updated |
|---|---|---|

## Walls hit

A wall is information about the design, not an error to patch around. Record
what broke, what was re-derived, and what was recommended.

## Open for the human
