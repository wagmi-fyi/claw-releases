"""python3 -m commonclaw_connection <verb>

  conf --name NAME [--socket-group GROUP]
      print the conf a claw is seeded with. The installer reads this, so the
      seeded conf and the shipped defaults are one list.

  store-check [--name NAME] [--stdin]
      open every sealed record, then search every byte under the state and log
      directories for the values they hold, inside this process. Prints counts
      and file names, never a value. With --stdin, each line read is one more
      value to search for, so a value reaches the check through a pipe and
      never through an argument. Exit 0 clean, 1 not clean, 2 usage or no key.
"""

import argparse
import json
import sys

from .settings import Settings, conf_text
from .store import store_check


def main(argv=None):
    ap = argparse.ArgumentParser(prog="commonclaw_connection", add_help=True)
    sub = ap.add_subparsers(dest="verb")
    c = sub.add_parser("conf")
    c.add_argument("--name", required=True)
    c.add_argument("--socket-group", default="")
    s = sub.add_parser("store-check")
    s.add_argument("--name", default=None)
    s.add_argument("--stdin", action="store_true")
    a = ap.parse_args(argv)
    if a.verb == "conf":
        try:
            sys.stdout.write(conf_text(a.name, a.socket_group or None))
        except RuntimeError as exc:
            sys.stderr.write("%s\n" % exc)
            return 2
        return 0
    if a.verb == "store-check":
        values = []
        if a.stdin:
            values = [ln.rstrip("\n") for ln in sys.stdin if ln.strip()]
        try:
            report = store_check(Settings(a.name), values=values)
        except RuntimeError as exc:
            sys.stderr.write("%s\n" % exc)
            return 2
        values = None
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0 if report["clean"] else 1
    ap.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
