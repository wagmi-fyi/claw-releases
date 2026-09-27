- **The continuity rail follows a conversation the app has moved.** When the
  desktop app moves an orchestrator's conversation to a new session, the rail
  wakes the newest session. When it cannot tell which session is newest, it
  resumes nothing for that handle, and `session-continuity --check` names the
  reason. Re-register the handle from the app's conversation, and the rail
  resumes it again.

## Changes with no visible effect

`session-continuity --check` shows, for each conversation the app started, the
session the handle records, the newest session the rail links it to, what
linked them, and the verdict.

## What somebody has to do

Most claws need nothing from a person. This release changes no groups and moves
no core.
