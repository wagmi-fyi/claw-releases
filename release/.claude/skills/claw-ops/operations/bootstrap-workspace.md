# Bootstrap a Workspace

**Required role: `claw-admin`.** Creating a workspace grants directory access, so the operation sits with the people who are responsible for who reaches what.

Create a directory where one domain of work completes: a group owns it, a manifest declares it, and both cores read it natively.

## Intent

The firm decides its own domains of work and opens them itself. Nobody outside the claw is in that loop, and no request leaves the machine.

## This operation does not build the layout

The claw already carries the script that builds it, root-owned and idempotent, and that script is the one the provisioner runs. This operation opens the door and reports what came back. There is no second implementation here to drift from it, which is why a workspace made this way is identical to one made at provisioning.

## Execution

Run `scripts/bootstrap-workspace.sh --help`, then run it. Arguments pass through to the claw's scaffold unchanged, so its interface is the only interface. It emits JSON on stdout and its checks are the result.

Members named must already have accounts on the claw. Creating a person is a different act on a different plane; this operation grants an existing person access to a new directory.

A re-run adds what is missing and touches nothing else. An instructions file or a manifest already there belongs to the people working in that directory and is never overwritten.

## The two controls

The scaffold runs both, and it refuses to report success when either fails.

**Shared write.** A second member writes a file the first member created. When this fails the setgid bit or the default ACLs are wrong, and the directory will quietly become one person's.

**Exclusion.** A non-member is refused. When this fails the workspace is open and the group buys nothing.

Each control needs the right accounts to exist. When the claw cannot supply them the scaffold says the control did not run, and an unrun control is not a passed one. Re-run once the accounts exist.

## When the door is closed

Two answers, and the script distinguishes them:

- The caller is not in `claw-admin`. The claw's own admin runs this, or grants the role first.
- The grant is absent. The claw was provisioned before the grant existed, or the drop-in is gone. It is repaired from the provisioning plane, not from here.

Neither is worked around. Report which one it is.

## After the scaffold

Replace the instructions file with the workspace's real context: what the work is, what the databases hold, which skills matter. The scaffold gives a shape, not a briefing.

Each member opens the workspace once in each core. A group change takes effect at the member's next login, and an existing session keeps its old groups, which is the usual reason a fresh grant looks like it did nothing.
