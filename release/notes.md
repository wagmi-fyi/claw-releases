- **An update no longer fails on a claw that carries a skill of its own.**
  Release 1.4.4 shipped the fix that keeps your own machine-wide skills through
  an update. One of its own checks then failed on exactly the claws that have
  one.

  The check starts the persistent-session core and asks how many machine-wide
  skills it can see. It expected that number to be the count of skills the
  release ships. On a claw carrying a skill of your own the core sees yours as
  well, so the number came back higher and the check reported a failure.

  What that cost a claw on 1.4.4: the update applied its files and then reported
  a failed run, so the version the claw records was not advanced and no
  changelog entry was written. The next two scheduled updates failed the same
  way, because your skill was still there, and then the claw stopped retrying.
  Nothing on the box named your file as the cause.

  From 1.4.5 the check reads the machine-wide directory three times, once with
  no probe of its own in it, once with the probe misplaced and once with it in
  the right place. It passes when the probe raises the directory's own count by
  one, whatever that count started at. Its line now says how many skills the
  core can see there that the release did not install, and says those are yours.

  **What to do.** Nothing. A claw that met this on 1.4.4 takes 1.4.5 on its next
  update and records the version normally. Your own skills are untouched
  throughout, on 1.4.4 and on 1.4.5 both.

- **The line at the top of a ride says which pointer it read.** A ride is
  `commonclaw-update.sh --release <tag>`, and it finds the tag on a channel at or
  below the one this claw follows. On the first tier that channel is the claw's
  own. The line still said it had read a lower channel and had left this claw's
  pointer alone, naming one channel as both. From 1.4.5 it says the claw's own
  pointer carried the tag when that is what happened, and names the lower channel
  when a lower one carried it.

  **What to do.** Nothing. Only the wording changed. A ride resolves the same tag
  from the same channel it did before.

- **A fix to the tool that builds a release, which a member sees nothing of.**
  `assemble.sh` runs on the machine a release is cut from. It resolved the output
  directory once where the operator stood and a second time inside the source
  checkout, so a relative output path could unpack a whole payload into the source
  tree. It now makes every path argument absolute before it changes directory.

  **What to do.** Nothing. This tool ships with no release and runs on no claw.

## What somebody has to do

Nothing new. The two items 1.4.0 named still stand: put this claw's channel
webhook into its vault, and enrol this claw's dead-man check.

Nothing here moves either core for anybody, and no core floor changed.
