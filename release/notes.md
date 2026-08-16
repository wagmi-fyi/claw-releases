- **The morning check no longer starts a program inside your home directory.**
  Every day this machine checks whether your core logins are close to expiring. To
  find out about one of the two cores it used to start that core as you, in your
  own home, which left files and timestamps behind and did it for everybody,
  including people who had never signed into that core at all. It now reads the
  same answer out of a file, as root, and nothing runs in anybody's home.

- **A provisioning run no longer opens a login shell as you.** To read which
  version of the persistent-session core you have, a run used to start a shell as
  you and load your profile. Every person, every run, including runs where nothing
  needed doing. It now reads the version from the installer's own symlink without
  starting anything.

- **This machine's name, its clock and its backup destination can no longer be
  changed by a re-run.** These are decided when the machine is built. A later run
  that is handed a different value now stops and says so instead of applying it.
  A wrong clock moves the backup schedule, the daily check and the storage
  reclaim together, and a wrong destination sends backups somewhere nobody is
  watching, so this is refused rather than obeyed.

- **If automatic updates are switched on, a broken release now stops instead of
  retrying forever.** A release that fails to apply is retried three times and
  then held, and the machine records what failed and how many times. A newer
  release is always accepted, because that is the way out. Before this, a release
  that could not apply was downloaded and attempted every hour indefinitely.

- **The copy of the last working release is kept properly.** The machine keeps
  the previous release so a bad one can be undone by converging back to it. That
  copy could previously be replaced by a release that had itself failed, which
  left nothing to go back to. A release now has to have applied successfully
  before it can become the copy you fall back to.

Nothing here changes what either core does, and no core is moved by this release.
