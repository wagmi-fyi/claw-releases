- **Your machine can now keep itself current, and you can decide that it should
  not.** Until now every update here was applied by hand by whoever operates this
  machine. This release gives it the ability to fetch validated updates and apply
  them on its own. Whoever operates the machine turns that schedule on, so if you
  want to know whether it is running here, ask them. Once it is, anything that
  would interrupt a session you might be in the middle of waits for the quiet
  hours rather than landing on top of you.

  If you would rather decide each one yourself, one command switches it off and
  the machine will then tell you what is available and wait:

      sudo /opt/commonclaw/provision-claw/scripts/set-update-mode.sh --mode manual

  You can see where things stand at any time with `--show`, and apply a waiting
  update whenever suits you. Switching back to automatic is the same command.

- **Backups have been keeping old data instead of clearing it out, and that is
  fixed.** The backup runs were correctly forgetting old snapshots, but the step
  that actually reclaims the space was set to run at an hour the schedule never
  reached. It had therefore never run on any machine since backups were turned
  on. Storage use has been climbing quietly the whole time.

  The first run after this release does a larger clear-out than usual, because it
  is catching up on everything that was forgotten but never reclaimed. That is
  expected and it happens once. One consequence worth stating plainly: data from
  snapshots that had already aged out was still technically recoverable, and after
  this first clear-out it is not.

- **A failed update now tells you what went wrong.** Previously a run that broke
  part way through wrote no result at all, so there was nothing to read except the
  scrollback of whoever was watching. There is now a record of every run, whether
  it finished or not, naming the step it stopped at.

- **This file is now written by the machine.** Every entry above this release was
  typed by a person after the fact, and on more than one occasion nobody
  remembered, so changes landed on machines with nothing here to explain them.
  Updates now write their own entry as part of being applied, which means what you
  are reading is produced by the same run that made the change rather than by
  somebody's memory of it afterwards.

- **For anyone who runs the provisioning scripts themselves.** This is a breaking
  change and it is deliberate. `provision-claw.sh` now requires three further
  arguments, `--release-notes`, `--release-class` and `--revision`, and it refuses
  to start without them. That refusal is the point: it is what makes it impossible
  for a run to change a machine and leave no explanation behind. Existing commands
  and scripts will need those three added.
