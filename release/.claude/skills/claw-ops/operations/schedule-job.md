# Schedule a Job

**Required role: `member`.** A person schedules under their own account, so this calls no sudo and opens no door.

Put one project's job on a timer. It runs under that person's own account, on the claw's own service manager, with nobody logged in and no harness involved.

## What a job is

Two unit files in the project directory whose work they do, named for the job: `<job>.service` and `<job>.timer`. They are the definition. The workspace repository tracks them and the backup rail carries them, beside the code they run.

The service is `Type=oneshot`. It runs, it ends, and the timer starts it again.

The definition and the output live in the tree, so removing an account loses no work. Of the job, only the link and the drop-in live in the home, and the adopt operation remakes them.

## What the operation adds

The link into the account, and the failure wiring. A drop-in records the owning bus handle and points the service at one shared failure unit. A failure sends one line to that handle naming the unit and how to read the error. The error stays in the journal.

The handle is an argument rather than a line in the tracked unit file, so a job changes hands without its definition changing.

## Execution

Run `scripts/schedule-job.sh --help`, then run it. Its checks are the result.

## The refusals

Each one is a state that would ship a fault.

**Not `Type=oneshot`.** A unit that stays running holds the timer's next elapse against a job that never finished.

**A path outside the tree.** A home, `/tmp` or `/run` in either unit file. The system prefixes an interpreter is reached by are allowed, and `ExecStart` must still name something under `/srv/workspaces`.

**A credential shape.** A job names an `op://` reference and the value is read inside the one process at run time. A value at rest in a unit file is a value in the backup.

**Linger off.** Without it the account's service manager stops when the last session ends, and the timer with it. Provisioning turns linger on at onboarding. On an older claw, the claw's own admin turns it on.

A refusal installs nothing.

## After the first run

Read the journal once: `journalctl --user -u <job>.service`. A job that installs correctly and fails on its first run is the common case. After that the failure line tells its owner.
