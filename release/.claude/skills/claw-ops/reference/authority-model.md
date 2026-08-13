# Authority Model

Who may run what on a claw, how a privileged operation reaches root, and where each role's sight ends.

## Two roles, and they are per-claw facts

| Role | Who holds it | What it runs |
|---|---|---|
| `member` | anybody in a workspace group | read-only operations. Can request a privileged one |
| `claw-admin` | the firm's own responsible people, stamped at provisioning | privileged operations, through the door below |

The roles belong to the claw, not to the company that provisioned it. A firm adds its own members through its own admin, and nobody outside the claw is in that loop.

An agent does whatever its principal does, and never more. A member's agent holds a member's authority because it runs as that member. There is no elevation path inside a session, and no operation here asks for one.

## The door

A privileged operation does not reimplement root work. It calls the **same root-owned, validated, idempotent script the provisioner calls**, through a sudo grant on exactly those scripts and nothing wider.

Three properties make the grant safe to hold, and each is checkable:

- The granted script is owned by root and writable by nobody else. A grant on a script its caller can edit is a grant of everything.
- The grant names the scripts by absolute path. No directory wildcard, no `ALL`.
- The script validates its own arguments and is idempotent, so a re-run converges rather than doubling.

A closed door is an answer, not an obstacle. When the grant is absent or the caller is not `claw-admin`, report that and stop. Never route around it with a hand-rolled equivalent of the privileged step; that is a second implementation of a rule that then drifts from the one the provisioner enforces.

## Where sight ends

Permissions on a claw are the isolation boundary, so a member-plane readout sees a partial claw by design. The distinction that matters:

**Unreadable is not missing.** A workspace directory is group-owned and closed to non-members, so a caller outside the group cannot traverse it and finds nothing inside. Reporting that as an absent manifest turns somebody else's healthy workspace into a defect report. Establish reachability first, then absence.

What each role reaches:

| Surface | Reachable by |
|---|---|
| the workspace root listing | anybody |
| a workspace's contents and its manifest | that workspace's group |
| group rosters | anybody |
| systemd unit state, including the rail's last run and result | anybody |
| the system journal and syslog | the journal groups and root |
| the seat roster, which is a claw-level declaration rather than anybody's own state | anybody |
| a person's own core credentials and their expiry | that person |
| another person's home | nobody but them |

Name what could not be observed, every time. An absence claim derived from a permission wall is a claim about the caller, not about the claw.
