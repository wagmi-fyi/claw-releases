- **The mail service's journal now holds one line per event.** Each line went
  in twice, and the second copy was recorded as ordinary information. The
  service now writes each line once, at its own level.

- **The mail check says who would be told.** Run it with `--state` or
  `--dry-run` and one line names the address an alert goes to, or `none`. A
  value that is not one address is reported and never printed. Both modes send
  nothing.

- **An update names any setting it adds to `/etc/orchestrate.conf`.** Before,
  it said the file was left as it is and then rewrote it.

- **Two help texts no longer print backticks.** A backtick in a line somebody
  pastes into a shell runs whatever sits between the two. The provider-seed
  door and the wake rail installer now name a command in single quotes.

- **The rest changes only how a release is cut and installed, and our own test
  suites.**

## What somebody has to do

Nothing. The mail service restarts on its new program during the update, and
lines already in your journal stay.

This release changes nobody's groups, so nobody has to end a process or reopen
the app. No core moves and no core floor changed.

Whoever applies this release by hand passes `--now` on a claw pinned to manual
updates. A claw that updates on its own takes it on its next scheduled run.
