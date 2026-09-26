# Continuity

**Required role: `member`.** It reads this account's own state.

Answer what the continuity rail has done for this account's orchestrators. The rail
runs outside every session and keeps an orchestrator reachable whether or not its
process exists; its own `--help` is the description of record.

## How it works

A handle registered with the orchestrator role is enrolled; nothing is set up per
handle. Each pass reads the bus. A handle with mail and a live session gets the wake
rail's nudge. One whose session has gone is resumed in the background under its
owner, with a fixed sentence telling it to invoke orchestrate's resume operation. A
session it resumed is stopped after fifteen quiet minutes, and the conversation is
kept. A resume that fails writes a hold, and no handle of the account is resumed
until it is cleared. After a compaction it sends a live orchestrator the resume
phrase, which the claw's resume hook turns into the skill's front page. A gone one
is resumed the same way as for mail, with the phrase as its first turn.

## The readings

One row per orchestrator handle this account holds: the last wake and its outcome,
the last resume and its outcome, any session the rail resumed and has not stopped,
and any hold. Then the account's own state: whether the rail is enabled here, what
its timer did, and whether the harness is signed in. A hold is the sign-out case,
so those two go together.

The rail's own board of handles is the board this readout uses. A second reading of
the bus here would be a second opinion about which handles are orchestrators, and
the rail's is the one that acts.

## Where sight ends

The rail keeps state under each owner's home, so another person's rows are
unreadable rather than absent. See `reference/authority-model.md`.

## Execution

Run `scripts/continuity.sh --help`, then run it. It changes nothing.

## Reading the result

A hold is the finding that matters: no handle of this account is resumed until it
is cleared, and a signed-out harness is usually why. A handle whose last wake was
delivered and whose inbox is still unread got the nudge and did not act.
