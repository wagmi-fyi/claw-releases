- **The resume hook says when it cannot load the skill.** The hook loads the
  orchestrate skill's front page only where the claw carries that page at 9,500
  characters or fewer. A claw whose skills lag behind can carry a longer one.
  There, the session gets one line in place of the page. The line names the
  page and its size, and says to run the resume operation by hand. The same
  line goes to the journal under `claw-resume-hook`.

- **New projects follow the claw's filing rules.** When the orchestrate skill
  starts a project, it reads your rules at `~/.config/project-conventions.md`.
  The update links that path to the claw's file if nothing is there yet. For
  rules of your own, write a file at that path. The claw never touches it
  again.

- **Old bus handles are cleared once a day.** A handle is a session's name on
  the shared bus. Each day the claw retires your handles whose mail is all read
  and which have been idle 14 days. A handle with unread mail stays. Nobody
  else's handles are touched, and every message stays in the bus log.

- **Your settings file becomes private when the update writes to it.** Where
  the update adds the compaction window to `~/.claude/settings.json`, it sets
  that file to mode 0600, readable by you alone. A file that already carries
  the setting keeps its mode.

## Changes with no visible effect

The hourly update check no longer reads failed when it meets an update somebody
is applying by hand. It stops, and the next hour's check reads again.

## What somebody has to do

Most claws need nothing from a person. This release changes no groups and moves
no core.

On a claw where the resume hook reports a page over the limit, update the
orchestrate skill to the published one. Its front page is 4,716 characters.
