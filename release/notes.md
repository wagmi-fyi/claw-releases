- **The continuity rail follows a moved conversation that has no title.** When
  the desktop app moves an orchestrator's conversation that nobody has named,
  the rail now wakes the newest session, as it already did for a named one.
  Before this release it resumed nothing for that handle and told a person the
  conversation had no title.
- **The checkpoint prompt now comes close to compaction.** The continuity rail
  tells a live orchestrator to write its workpaper when its last turn passes 90%
  of the automatic compaction window. Before this release it did so at half.
  At a window of 650,000 tokens the prompt comes at 585,000.
- **The automatic compaction window is now 650,000 tokens.** A person with no
  window set gets 650,000. A person at the old default of 600,000 moves to
  650,000 with the rest of their settings kept. Any other number a person set
  stays as it is. The setting is `autoCompactWindow` in
  `~/.claude/settings.json`.

## Changes with no visible effect

The rail links a moved conversation by the message ids the move copied.
`session-continuity --check` names each link `ids`, or `title and ids` where
the conversation carries a title. A named conversation whose move does not
start with its name is refused, and the reason says so. The fraction the
checkpoint prompt fires at is one number in the rail, and `--check` shows the
threshold it gives for each window.

## What somebody has to do

Most claws need nothing from a person. This release changes no groups and moves
no core.
