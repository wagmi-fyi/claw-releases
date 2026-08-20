- **Your claw's agents token is now one file for the whole claw.** It used to be
  copied into each person's home. It is now a single root-owned file, and a new
  group decides who can read it. Nothing about how you work changes: your session
  still resolves the same references the same way.

  What changes for whoever runs the claw. Rotating the token is one write instead
  of one per person: install it once and everybody in the credential group has it.
  Onboarding somebody no longer touches a credential at all. It grants them the
  group and writes the small loader in their home that reads the file, the grant
  is its own step, and it gets its own line in the claw's admin log, so you can
  always answer who can read the token and when that started. Taking one person's
  access away is now removing them from the group, which is immediate and reaches
  only them. Retiring the token itself is still a claw-wide act.

  A session that is already open keeps the token it started with. After a
  rotation, people reconnect. Tell them rather than leaving them to notice.

- **Moving an existing claw onto this shape means ROTATING the token, not moving
  it.** Read this before you update if your claw already has per-person copies.

  Those copies live in people's homes, and homes are captured by the backup rail.
  So the token value is already inside every snapshot still in the retention
  window, which is months rather than days. Deleting the copies removes them from
  the disk and from nothing else. The value goes on opening the vault for anybody
  who can restore a snapshot. Converging without rotating is therefore not a fix,
  and it looks like one, because afterwards the claw has exactly the right shape.

  What to do: mint a new agents-broker service-account token in your manager,
  revoke the old one there, and drop the new value when you run the install. Do
  not copy the value you already have into the new location.

  The installer enforces this. When it finds per-person copies it reads their
  digests and refuses an offered token that matches one of them, before it writes
  anything. After a successful convergence it tells you to go and revoke the old
  token at the manager, because that is the only act that actually retires it.

  Do the install in the same sitting as the update. Applying this release
  repoints everybody's loader at the new shared file, and that file does not
  exist until you install the token. Between those two moments nobody's session
  resolves anything. The update run says so and gives you the command. It is one
  command and it covers everybody.

- **Do not put a credential in the claw config directory.** The configuration
  directory is one of the four paths the backup rail captures. Anything written
  there is inside every snapshot for the whole retention window, and deleting the
  file afterwards does not reach a single snapshot. It is also the first place
  anybody looks, which is why this is worth saying out loud rather than leaving to
  be inferred.

  The agents token is deliberately kept outside every path the rail captures. The
  code does not carry its own copy of that list. It asks the backup rail where it
  captures at the moment it writes, and refuses to write if the rail cannot
  answer. If somebody later adds a backup target that would cover the token, the
  run goes red instead of the credential quietly entering every snapshot.

- **Who can administer this claw is now three tiers instead of one, and changing
  it is signed off the box.** The firm's owner is named at setup. The owner can
  make somebody an admin and take it away again, and each of those acts is a
  request the owner signs from their own device. Nothing an admin needs rests on
  the claw itself, so somebody who takes over a claw cannot promote themselves.

  A claw that already had administrators keeps them. They are adopted into the
  register at the first run and each of them can then be removed by a signed
  request, the same as anybody added afterwards. Four kinds of entry cannot be
  adopted, because there is nothing to adopt them by: a system account, somebody
  with no readable keys, somebody whose only key carries login options, and a
  name in the group with no person behind it. They keep whatever the group gave
  them and the run says so out loud rather than leaving it quiet. If one of those
  is a real person, the owner signs to add them and they become removable.

  A lost owner is a break-glass request to the vendor, in writing.

- **Shared programming runtimes are now installed once for the claw instead of
  once per person.** A claw declares which runtimes it carries, the versions are
  pinned, and everybody's shell finds the same copies. Adding or changing one is
  a claw-admin act through the member plane, so it is logged like the rest.

- **Somebody made on this claw now gets a working git identity in the same
  step.** Before this, a new person's first commit failed on a machine that did
  not know who they were, and somebody had to notice and fix it by hand.

- **Two smaller repairs.** A run that converges the claw's state directory now
  says which of three things happened, rather than printing the same sentence
  whether it created the directory, found it already right, or moved it back from
  something else. If it moved it, it names the old value, because something set
  that and whatever it was will do it again. And when somebody cannot reach the
  claw's session bus, the run now checks their path into it in three separate
  steps and names the directory that refused them, instead of reporting one
  failure that could have been any of three things.

Nothing here moves either core for anybody, and no core floor changed.
