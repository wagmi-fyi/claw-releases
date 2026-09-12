"""The journal line every piece of this package writes.

Lifted from payload/email-gatekeeper/email-gatekeeper, function `log`.
Everything a service says goes to the journal and never to a bus: a rail that
recorded its own trouble into an inbox would raise unread mail, which would
raise a nudge, which would raise more mail.
"""

import sys
import syslog

_OPENED = []


def log(level, msg):
    if not _OPENED:
        try:
            import os
            syslog.openlog("commonclaw-conn-%s" % os.environ.get("COMMONCLAW_CONN_NAME", "?"),
                           syslog.LOG_PID, syslog.LOG_DAEMON)
        except Exception:
            pass
        _OPENED.append(True)
    try:
        syslog.syslog(
            {"err": syslog.LOG_ERR, "warn": syslog.LOG_WARNING}.get(level, syslog.LOG_INFO),
            msg,
        )
    except Exception:
        pass
    sys.stderr.write("%s %s\n" % (level, msg))
    sys.stderr.flush()
