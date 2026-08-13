- **You can now remove a workspace, and change who reaches one, without
  asking anybody.** Until this release your admins could create a workspace and
  could not take one away, and adding somebody to an existing one only worked as
  a side effect of re-running the script that creates directories. There was no
  way at all to take somebody off. That was never a decision anybody made about
  what you are allowed to do on your own machine. It was a door that had not been
  built, and from the outside an unbuilt door and a refusal look the same.

  Changing who reaches a workspace:

      sudo /opt/commonclaw/provision-claw/scripts/manage-workspace-access.sh --grant  alice finance
      sudo /opt/commonclaw/provision-claw/scripts/manage-workspace-access.sh --revoke alice finance
      sudo /opt/commonclaw/provision-claw/scripts/manage-workspace-access.sh --show   finance

  Two things about it worth knowing. A grant or a revoke reaches the person at
  their next login, because a session keeps whatever access it started with, so
  if a fresh grant looks like it did nothing the answer is to reconnect. And
  taking the last person off a workspace is allowed. You get a warning and the
  workspace stays, with its files and its backups, until somebody is put back on
  it or you remove it deliberately.

- **Removing a workspace, and what you get back if you change your mind.** The
  door removes the directory, the group, and every membership of that group, in
  one act:

      sudo /opt/commonclaw/provision-claw/scripts/destroy-workspace.sh --workspace finance --confirm finance

  You name the workspace twice. That is a confirmation rather than a gate, and it
  is spelled as a repeated argument instead of a yes-or-no prompt on purpose: an
  agent session cannot answer a prompt deliberately, and a door your agents
  cannot use is closed to half the people it was built for. Naming it twice is
  one act that a person and an agent both perform the same way.

  It will not remove a directory that is not a workspace, and it will not remove
  anything outside your workspace root.

  A workspace with real work in it is not treated as a special case. You may
  retire a full one, and the door tells you plainly what that costs when it
  finishes:

      Everything here that was older than the last backup snapshot can be restored
      from the rail for as long as retention keeps that snapshot. Anything written
      since that snapshot is gone for good.

  That sentence is the whole protection and it is stated rather than implied. Your
  backups are what makes removing a workspace reversible, and they are a real
  bound rather than an unlimited one.

- **Every one of those acts is written down in your own record.** A grant, a
  revoke and a removal each append one row to the member-plane log on this
  machine, naming who did it. Asking who reaches a workspace writes nothing,
  because reading is not an act.
