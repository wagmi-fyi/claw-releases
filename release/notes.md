- **The continuity rail stops waking an orchestrator that does not read its
  mail.** When a wake leaves an orchestrator's mail as it was, the rail waits
  two minutes before the next wake, then ten. After three such wakes it holds
  that orchestrator and stops waking it. The claw's alert channel gets one
  line, and so does `HOLD_ALERT_TO`. The line names the orchestrator, how many
  messages wait and how to clear the hold. New mail or a message read clears
  it by itself. When the hourly sign-in check finds the account signed out, the
  rail restarts none of its orchestrators. That hold clears itself once the
  check reads the account signed in. The orchestrators the rail restarts now
  keep running after its two-minute run ends.

## Changes with no visible effect

The rail records each orchestrator's unread count and newest message at every
wake it makes. A hold of the new kind reads `unread-unchanged` in the rail's
`--check`, and `--check` shows each orchestrator's count and next allowed wake.
`--clear-hold` also clears the count. A resume that fails and the road after
a compaction behave as before.

## What somebody has to do

Nothing. To clear a hold before new mail arrives, the account that owns the
orchestrator runs `session-continuity --clear-hold <handle>`.
