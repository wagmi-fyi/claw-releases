- **This machine now asks the authoritative source what updates exist.** It was
  reading a cached listing that could be several minutes out of date, and
  different machines were being given different answers at the same moment. It
  could therefore report that nothing was available when something was. It now
  asks the source directly.

  This matters most when somebody here has just been told a release exists and
  applies it by hand, because being told there is nothing available reads as
  broken rather than as slow.
