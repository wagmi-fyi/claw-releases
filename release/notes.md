- **Somebody on this machine who has never signed into a core now gets one,
  instead of the update stopping on them.** This machine holds every person to a
  minimum version of each core. To decide what to do for you it reads the version
  you have. When somebody had no core at all there was no version to read, and
  the machine treated that the same way it treats a core that is installed and
  will not say what it is: it left it alone and reported a failure. So a person
  who had simply never logged in would stop the whole update for everybody.

  It now asks the question directly. If you have no core, it installs the minimum
  version for you, the same way it does for somebody whose core is out of date.
  If you do have one and it cannot say what it is, it still leaves it alone and
  tells you, because installing over a core nobody can read could move you
  backwards to an older one. When a run finishes it says how many cores it moved
  and how many it installed fresh, separately, because those are not the same
  event.

  One more thing was found beside it and is fixed here too. If a core had been
  removed and the shortcut that starts it was left behind, the machine read a
  version out of the shortcut's name and reported that person as up to date. They
  had no core they could start. The shortcut now has to lead to a real program
  before its name counts as an answer.

- **Why this machine goes from 1.1.1 to 1.1.3, with no 1.1.2.** Release 1.1.2 was
  published and then refused by every machine that was offered it. It was built
  from two different snapshots of our own source, and the halves disagreed about
  which files a release carries, so it stopped before changing anything. Nothing
  was applied anywhere and nothing needed undoing. 1.1.3 carries the same fix,
  built from one snapshot, and it was checked against its own contents before it
  was offered to anybody.

Nothing here changes what either core does, and no core is moved for anybody who
already has one.
