# Claw Status

**Required role: `member`.** The readout reads only what its caller can already reach, and it holds no privilege of its own.

Answer what exists on this claw, who reaches it, and whether the things that run unattended are still running.

## What it reports

| Subject | Source |
|---|---|
| the caller and the roles they hold | group membership |
| workspaces, and whether each is declared | the workspace root and each manifest |
| who reaches a workspace | the workspace group's roster |
| the backup rail's last run, its result, and its next one | the timer and service unit state |
| the caller's own core seats | the caller's own home |

## The reporting rules

**Unreadable is not missing.** A workspace closed to the caller reports as unreadable, and a directory the caller can enter that carries no manifest reports as missing. Only the second is a finding. See `reference/authority-model.md`.

**Seats are the caller's own.** Another person's seat state lives in their home and stays there. The claw's own seat check covers everybody and reports to the journal on its own schedule; this readout does not stand in for it.

**Findings are data, and the exit code is about the readout.** The script exits non-zero when it could not produce a readout, never because it found something. A status that goes red on any warning saturates: an accepted condition pins it red, and a real one then changes nothing. Read the findings.

## Execution

Run `scripts/claw-status.sh --help`, then run it. It writes JSON on stdout and changes nothing.

## Reading the result

A workspace with no manifest is unfinished work rather than a workspace. Inside the workspace root, a manifest governs; a directory without one gets reported rather than used.

A rail that has never run and a rail that ran and failed are different states, and both are findings. The rail's own reference material on the provisioning plane holds what to do about a failing one; from here, report it.

A seat warns before it lapses so somebody can log in again. Only the person holding the seat can fix it, and the fix is a login on their own account.
