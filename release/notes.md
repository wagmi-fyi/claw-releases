- **After this update, quit and reopen the desktop app once on each claw you
  use.** This release moves the session bus, the message rail your agents use to
  reach each other, to a group of its own. A program that is already running
  keeps the access it started with. So a session you opened before the update
  cannot post on the bus after it, and a session you open afterwards posts as
  before. One reconnect per claw is the whole change for you, and there is no
  period where both ways work.

  **If you run orchestrations,** respawn their delegates after the update, for
  the same reason. A delegate started before the update cannot report on the
  bus.

  **You do not have to restart anything else.** The watchers that tell a session
  it has bus mail, and the mail service, are restarted by the update itself when
  they need the new group.

  **Take the update in a quiet moment,** when no orchestration is in the middle
  of a unit. Nothing on the bus is lost or rewritten. Every message, inbox and
  handle stays where it was.

- **Your claw can now hold your firm's API credentials, and keep the ones that
  renew themselves working.** Some providers hand out a login token that changes
  each time it is renewed. When two agents renew it at once, one of them breaks
  it. Your claw now runs one service that holds each of these credentials, renews
  it for everybody, and hands your agents the current one. It holds a plain API
  key the same way.

  **Adding a provider.** On the claw, type:

      token add <provider>/<account> --metadata <the provider's OAuth address>

  or `token add <provider>/<account> --key` for a plain API key. The command
  prints the steps for that provider, with the name of the item to create in
  your firm's password manager. Your agent can walk you through them. There are
  three ways, and the command picks one:

  - **Paste** the values from the provider's own page into that item in your
    password manager app.
  - **Approve in your browser** with a small helper you copy from the claw and
    run on your own computer with `uv`. It writes the item for you.
  - **Approve through a tunnel** to the claw, for a provider that has to send you
    back to the claw itself.

  Then a person with administrator rights on the claw runs the one command the
  steps name, and the credential is in place. `token check <provider>/<account>`
  proves it works.

  **What your agents do.** Your agents ask the service for the current token each
  time they call the provider, through a small library already on the claw, in
  `/opt/commonclaw/lib/python`. When the provider refuses a token, the service
  renews it once and every agent gets the new one. A provider that stops
  accepting the renewal shows up in `token status`, and one message goes to your
  firm's desk.

  **Who can use what.** Each credential names a group of your people. The default
  is the people who can already read your firm's credentials, and you can narrow
  it to one team. `token status --seeded-by <person>` lists what a person set up,
  so when somebody leaves you know what to hand over.

  **The claw never prints a token.** The `token` command, the helper and the
  administrator's command show a short fingerprint in its place. Nobody types a
  credential into a conversation or a shell at any step.

  **How the service is built.** It runs under its own account, which is never
  counted as a person on your claw. It answers only the people on your claw,
  plus any account your claw's settings name. What it keeps between restarts is
  locked with a key that opens on this machine alone, so a backup copy of it
  opens nowhere else. The same frame will carry other services that hold a
  credential for your firm.

  **What you see on the next apply.** A new step installs the token service,
  prints its health as a note, and checks that no service account on the claw is
  counted as a person. The health note reads not ready until a provider is added
  and its credential is in place, and that is the ordinary state of a claw that
  has none.

  **What you have to do: nothing,** until you want to add a provider.

- **The session bus gets its own group, and the group for people holds people
  only.** Until now one group on your claw did two jobs. It listed the people who
  work here, and it decided who could post on the session bus. The mail service
  posts on the bus, so it had to be in that group, and parts of the claw then
  treated it as a person. On a claw with wide mode on, that also put the mail
  service's account inside the grant that gives people root.

  From this release there are two groups. `claw-members` lists the people on your
  claw and nothing else. `claw-bus` decides who may post on the bus: every
  person, and every service that posts there, such as the mail service and the
  token service. The update moves the bus over to `claw-bus` and moves the mail
  service's account out of `claw-members`. This move is why you reconnect once,
  as the first entry says.

  **For whoever runs the claw.** `claw-members` is every person, and it is what
  wide mode's root grant names, so that grant now reaches people and nobody else.
  `claw-bus` carries no grant of any kind, and the update checks that no sudoers
  file names it. A person you add with the onboarding door joins both groups. A
  service joins `claw-bus` alone, from its own installer. The apply says how many
  paths it moved to `claw-bus` and names each account it moved. A second apply
  moves nothing and says so.

- **The conventions your agents read now describe where this claw keeps
  credentials.** Every agent on your claw reads one conventions file before it
  works. Until this release it said one credential rests on the claw and
  described the claw's services in a way that was never built. It now says what
  is true.

  - A static secret, such as an API key, still comes from your claw's agents
    vault through the same one command, `op-agents read`.
  - A credential that serves the whole firm can be held by a service on the
    claw. Your agents reach each service by a command named for what it hands
    out: `email` for the firm's mail, and `token` for the firm's accounts at
    other providers. An agent asks the token service for the current token and
    never refreshes one itself. The library it asks with is in
    `/opt/commonclaw/lib/python`.
  - Every credential on the claw serves the whole firm. A personal one, such as
    your own mailbox, stays on your own machine, and your personal agent reaches
    the claw over mail when it needs to.

  **What you have to do: nothing.** The file is replaced on the next apply, and a
  session reads the new one the next time it starts.

  **For whoever runs the claw.** The reference now says that each connection
  service's data key rests on the claw beside the machine credential, sealed by
  the host key. A rebuilt claw starts each service with an empty store and takes
  its seed from the vault again. A token service row seeded through the tunnel
  has no copy in the vault, so on a rebuilt claw a person walks the tunnel again.

- **Smaller fixes.**

  - **`email status` now says when the mail provider refuses your claw's key.**
    Before this release, a claw whose key the provider turned away read
    "routes.json names no inbox yet". Anyone who followed that line ran
    `email inbox create` and only then met the real answer. The status line now
    gives the provider's own answer, for example "the account answered 403". Fix
    the key first. The inbox comes after it.
  - **A watcher you turned off stays off.** If you ran
    `systemctl disable --now bus-nudge@<you>` to stop the bus-mail watcher, every
    update used to turn it back on. From this release the update leaves it off
    and says so in a note. A watcher you disabled before this release has no
    record of being on yet, so this one update turns it on once. Disable it again
    afterwards and it stays off.
  - **`op-agents` names the right cause when it cannot read the token.** On a
    claw that has no agents token at all, it used to tell you to check your group
    membership. It now says the claw has no token and names the command that
    installs one. When the token is there and you cannot read it, it still names
    the group.
  - **Files the mail service writes keep the permissions the install gives
    them.** A change made through the `email` command used to leave the routing
    table at 0644. The service now writes its files at 0640. Restarting the
    service no longer changes the time each mail thread was first seen.
  - **One update applies at a time.** Once your claw carries this release, an
    update started by hand while the scheduled one is running stops at once,
    names the run that holds the claw, and changes nothing. Run it again when
    that one ends.

## Errata for release 1.5.2

Published notes cannot be edited after the fact, so the corrections are here.

**1.5.2 says the mail service is not restarted by that update, and it was.** The
update installed a new version of the service's program, so the service
restarted onto it. Its messages, routing table, logs and settings were kept as
the notes said. On restart the service rewrote the time it had first seen each
mail thread. This release keeps those times.

**1.5.2 says a write by the `email` command leaves the routing table in the shape
the release seeded it in.** The contents and their order held. The file's
permissions did not: a write left it at 0644 where the install makes it 0640.
Both directories above it are closed to accounts outside the service's group,
so nobody else could read it. This release writes it at 0640.

**1.5.2 says that release itself still waits for the quiet window on a claw that
carries the mail service.** That depends on whether the mail account had been
given a core by an earlier update. Where it had one, the update applied without
waiting, measured on 2026-09-12. `--now` was the safe instruction in both cases.

## What somebody has to do

**Each person reconnects the desktop app once on each claw after the update,**
and each orchestration respawns its delegates. The first entry says why.

**Whoever applies this release by hand passes `--now` on a claw pinned to manual
updates.** That flag is what walks a person standing at the box past the manual
setting. A claw that updates on its own takes this release on its next scheduled
run, whatever the hour, so choose the moment by applying it by hand in a quiet
one.

**The update installs one package where it is missing,** the distribution's
`python3-cryptography`, which the token service uses to lock what it keeps.

The two items 1.4.0 named still stand: put this claw's channel webhook into its
vault, and enrol this claw's dead-man check. The two mail steps 1.5.1 named
still stand for a firm that wants an address: put the provider key into the
claw's own machine vault, then make the address once.

Nothing here moves either core for anybody, and no core floor changed.
