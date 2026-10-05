- **The continuity rail holds only the orchestrator that failed to resume.**
  When the harness refuses one orchestrator, for example because its folder is
  not trusted, the rail stops resuming that one and goes on resuming the
  others. It tries the held one again once an hour, and a resume that works
  clears the hold. Before this release one refusal stopped every orchestrator
  of the account until somebody cleared it by hand. A signed-out harness still
  stops the whole account.
- **A hold now says what to do.** The message names the orchestrator and the
  harness's reason. It ends with the step that fixes it. For a folder the
  harness does not trust, it names the folder and says to run the agent there
  once and accept the prompt.
- **A hold can reach a handle somebody reads.** Set `ORCHESTRATE_HOLD_NOTIFY`
  in `/etc/orchestrate.conf` to a bus handle, and each hold's message goes
  there as well as to `human`. Left unset, it goes to `human` alone.

## Changes with no visible effect

`session-continuity --check` shows each hold's scope, `account` or `handle`,
and when a handle's hold is next tried. A hold written by an earlier release is
read by its sign-in word: `signed-out` holds the account, and anything else
holds the handle. The claw-ops continuity readout reports the two scopes as
separate findings. A hold's message drops any path other than the
orchestrator's own folder, and any value long enough to be a token. A
provisioning run keeps the `ORCHESTRATE_HOLD_NOTIFY` line where a claw sets it
and never writes one.

## What somebody has to do

Most claws need nothing from a person. This release changes no groups and moves
no core. A claw that wants hold messages read by an orchestrator sets
`ORCHESTRATE_HOLD_NOTIFY` by hand.
