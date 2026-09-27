- **The resume hook now comes from the orchestrate skill.** Where the claw's
  shared skills include orchestrate, the update registers that skill's own
  hook. It removes the claw's older copy in the same step. Where they do not,
  the claw has no resume hook, and the update says so. The hook writes to the
  journal under `orchestrate-resume-hook`.

- **The rail asks for the standing-rules write once per crossing.** The
  continuity rail asks a long-running orchestrator to write its standing rules
  down when its conversation passes half the compaction window. It asks once
  for each crossing in each conversation. A turn the harness writes on its own
  does not make it ask again.

- **A blocked update names what blocks it.** When an update meets another one in
  progress, its message names the process that holds the lock at that moment.

- **Each changelog entry is one section.** The headings inside an entry now sit
  one level below the entry's date. The changelog's outline shows one line per
  update.

## Changes with no visible effect

The continuity rail reads its resume phrase from the orchestrate skill and keeps
no copy of its own.

## What somebody has to do

Most claws need nothing from a person. This release changes no groups and moves
no core.

Where the update says the claw has no orchestrate skill, the continuity rail
resumes no orchestrator until that skill is added to the claw's shared skills.
