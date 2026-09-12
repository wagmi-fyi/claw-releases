"""The health line: one JSON object a program's `--check` prints.

Lifted from payload/email-gatekeeper/email-gatekeeper, `cmd_check`, reduced to
the four readings provisioning reports for every connection: installed,
running, ready, and a reason when it is not ready.

NOT READY IS NOT A FAILURE. A connection nobody has wired yet reads not-ready,
and provisioning prints the line as a note and passes. The mail service
follows the same rule.
"""

import json
import os
import subprocess

from .store import read_data_key


def unit_name(connection):
    return "commonclaw-conn-%s.service" % connection


def health_line(settings, ready=None):
    """The line, as a dict. `ready()` is the program's own reading: (bool, reason)."""
    unit_dir = os.environ.get("COMMONCLAW_CONN_UNIT_DIR", "/etc/systemd/system")
    unit = unit_name(settings.name)
    out = {"connection": settings.name, "installed": False, "running": False,
           "ready": False, "reason": ""}
    missing = [p for p in (settings.conf_path, os.path.join(unit_dir, unit))
               if not os.path.isfile(p)]
    out["installed"] = not missing
    try:
        p = subprocess.run(["systemctl", "is-active", "--quiet", unit],
                           capture_output=True, timeout=20)
        out["running"] = (p.returncode == 0)
    except (OSError, subprocess.SubprocessError):
        out["running"] = False
    if missing:
        out["reason"] = "not installed: %s is missing" % missing[0]
        return out
    if not settings.enabled():
        out["reason"] = "ENABLED is not yes in %s" % settings.conf_path
        return out
    if not out["running"]:
        out["reason"] = "%s is not running" % unit
        return out
    try:
        read_data_key(settings.name)
    except Exception as exc:
        out["reason"] = str(exc)[:300]
        return out
    if ready is not None:
        try:
            ok, why = ready()
        except Exception as exc:
            ok, why = False, str(exc)[:300]
        if not ok:
            out["reason"] = why or "the service says it is not ready"
            return out
    out["ready"] = True
    return out


def print_health(settings, ready=None):
    """Print the line and return the exit a `--check` gives: 0 ready, 3 not."""
    line = health_line(settings, ready)
    print(json.dumps(line, sort_keys=True))
    return 0 if line["ready"] else 3
