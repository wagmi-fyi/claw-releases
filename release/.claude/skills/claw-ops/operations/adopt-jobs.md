# Adopt Jobs

**Required role: `member`.** It runs from the adopting account and schedules work under that account, so it calls no sudo and opens no door.

Take over the jobs of somebody who has gone.

## Why it is its own operation

A job's definition is in the project directory, so nothing of it is lost when an account goes. What is lost is the link. Relinking is the schedule operation, and the one thing that operation cannot know is whether the departed account still runs the same job. Two copies of one job on one claw is the failure this prevents.

## What is measured, and it is not their timers

No member may read another account's service manager, so the departed account's timers cannot be listed from here. What can be read is whether that account can run a timer at all: whether it still exists, whether it lingers, and whether its service manager is active.

Any of those refuses the adoption. Say what was measured rather than claiming their timers are gone.

## Ending the departed side

Either the departed person disables their own timers, or the claw's own admin turns their linger off and ends their service manager. Then the adoption runs.

An account that has been removed refuses nothing: there is no manager left to run anything.

## Execution

Run `scripts/adopt-jobs.sh --help`, then run it.

The install is `operations/schedule-job.md`'s, run once per job, so every refusal it makes is made here too.

## The handle

The owning handle is an argument. The departed account's drop-in sits in their home where nothing here can read it, and a job changing hands usually changes owner as well.
