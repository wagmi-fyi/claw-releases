- **A claw can be provisioned more than once again.** A run checks that the group
  every member belongs to does not quietly own things around the box, because a
  group everybody is in carries whatever it reaches to all of them. That check
  used to insist the group owned exactly one file. The same release then creates
  the shared session bus, which the group owns on purpose, so the first run on a
  claw passed and every run after it failed on the bus the run before had left.

  The check now compares against what the release says the group may own: the
  claw briefing, and the session bus with everything inside it. Anything else
  carrying that group is still a failure, and it is still a failure inside the
  same directory tree the bus lives in. Nothing was excluded from the search.

  If your claw took 1.2.0 or 1.3.0 and a later update reported a failure naming
  `/var/lib/commonclaw/bus`, this is that failure and this release ends it. A
  claw stuck on it takes this release normally: a newer release is always
  accepted, which is what makes a newer release the way out.

Nothing here moves either core for anybody, and no core floor changed.
