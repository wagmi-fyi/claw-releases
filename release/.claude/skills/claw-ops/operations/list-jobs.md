# List Jobs

**Required role: `member`.** The readout reads only what its caller can already reach and holds no privilege of its own.

Answer what is scheduled on this claw.

## The list is derived

No file names this claw's jobs. A job is a timer under somebody's account and a definition in a project directory, and the readout reads both. A hand-kept list would be wrong the first time somebody scheduled something without updating it.

## Two readings

**Enabled.** The caller's own timers, with the next run, the last run, the last result and the owning handle. Only timers whose definition sits under `/srv/workspaces` are this claw's jobs.

**Declared.** Every `<name>.timer` under `/srv/workspaces` the caller can read, with the project directory holding it, and whether the caller's account has it linked. A declared job nobody here has linked is one another account runs, or one nobody runs yet.

## Where sight ends

A person's timers live in their service manager and their home, and no member can query another member's manager, so for every other account the readout reports whether they linger and whether a manager is running, and reports their timers as unreadable.

Unreadable and none are different answers. See `reference/authority-model.md`.

The same wall applies to the declared reading: a workspace closed to the caller is named rather than skipped.

## Execution

Run `scripts/list-jobs.sh --help`, then run it. It changes nothing.

## Reading the result

A job with no owning handle and no failure wiring was linked by hand rather than by `operations/schedule-job.md`. It runs, and a failure tells nobody. Re-run the schedule operation for it.

`failure_wired` false on a job somebody depends on is a finding. The rest are observations.
