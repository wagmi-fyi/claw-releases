"""Where a connection's settings come from.

Lifted from payload/email-gatekeeper/email-gatekeeper, class `Settings`: the
environment, then the machine conf, then the shipped default. First match wins,
and nothing is merged.

THE SHIPPED DEFAULTS LIVE HERE AND NOWHERE ELSE. The installer seeds a claw's
conf by asking this module for its text (`conf_text`), so the conf a claw
carries and the defaults the service falls back to are one list. The
gatekeeper keeps two, a template and a dict, and they can drift.

THE PATHS ARE THE SCAFFOLD'S. STATE_DIR, STORE_DIR, LOG_DIR and SOCKET follow
from the connection's name, and the unit the installer renders lets the process
write under /srv/connections/{name}/ alone. So those four are not written into
a claw's conf. The environment can still move them, which is how a control
drives a service against a scratch directory.
"""

import os
import re

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ENV_PREFIX = "COMMONCLAW_CONN_"


def connection_name(explicit=None):
    """The connection this process serves. The unit sets it; a control may too."""
    name = explicit or os.environ.get("COMMONCLAW_CONN_NAME", "")
    if not name:
        raise RuntimeError(
            "COMMONCLAW_CONN_NAME is not set. This program runs under its unit, "
            "which sets it, or by hand with it set to the connection's name")
    if not NAME_RE.match(name):
        raise RuntimeError("'%s' is not a connection name: lowercase letters, digits "
                           "and hyphens only" % name)
    return name


def scaffold_paths(name):
    home = "/srv/connections/%s" % name
    return {
        "STATE_DIR": home + "/state",
        "STORE_DIR": home + "/state/tokens",
        "LOG_DIR": home + "/log",
        "SOCKET": "/run/commonclaw-conn-%s/sock" % name,
    }


# The keys a firm may rule on, in the order the conf carries them, each with the
# sentence the seeded conf prints above it.
TUNABLE = (
    ("ENABLED", "yes",
     "yes runs the service. no keeps it running and answers every request with "
     "a refusal that says the service is switched off here."),
    ("SOCKET_GROUP", "claw-members",
     "the group whose members may open the socket. Unix permissions on the "
     "socket are the first wall. The installer writes this value into the "
     "socket unit, so a change here reaches the socket at the next apply."),
    ("MEMBER_ONLY", "yes",
     "yes refuses a caller whose account is not a person on this claw, unless "
     "DOOR_EXCEPTIONS names it. The person test is scripts/person.sh."),
    ("DOOR_EXCEPTIONS", "root",
     "accounts the door lets through although they are not people, separated "
     "by spaces. root is here so the claw's own doors can reach the service. A "
     "service placed in front of this one is named here."),
    ("REQUEST_MAX_BYTES", "65536",
     "the largest request the door reads. A larger one is refused."),
    ("STORE_BACKEND", "encrypted-local",
     "where sealed records are kept. encrypted-local is the one built. "
     "manager-write-back is a named seam with nothing behind it yet."),
)

SHARED_DEFAULTS = dict((k, v) for k, v, _ in TUNABLE)
SHARED_DEFAULTS.update({
    # The reconnect ladder, for a service that holds a connection to a
    # provider. One second doubling to a minute, with jitter.
    "RECONNECT_MIN_SECS": "1",
    "RECONNECT_MAX_SECS": "60",
})


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.readlines()
    except OSError:
        return []


def to_int(v, fallback):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return fallback


class Settings:
    """One connection's settings. `defaults` adds the program's own keys."""

    def __init__(self, name=None, defaults=None):
        self.name = connection_name(name)
        self.conf_path = os.environ.get("COMMONCLAW_CONN_CONF",
                                        "/etc/commonclaw/conn-%s.conf" % self.name)
        self.env_path = os.environ.get("COMMONCLAW_CONN_ENV",
                                       "/etc/commonclaw/conn-%s.env" % self.name)
        self.values = dict(SHARED_DEFAULTS)
        self.values.update(scaffold_paths(self.name))
        self.values.update(defaults or {})
        self.origin = dict((k, "shipped default") for k in self.values)
        for line in read_lines(self.conf_path):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            k = k.strip()
            if k in self.values:
                self.values[k] = v.strip().strip('"').strip("'")
                self.origin[k] = self.conf_path
        for k in list(self.values):
            env = os.environ.get(ENV_PREFIX + k)
            if env is not None:
                self.values[k] = env
                self.origin[k] = "environment"

    def get(self, key):
        return self.values[key]

    def __getattr__(self, name):
        key = name.upper()
        values = self.__dict__.get("values", {})
        if key in values:
            return values[key]
        raise AttributeError(name)

    def enabled(self):
        return self.values["ENABLED"].strip().lower() in ("yes", "true", "1", "on")

    def member_only(self):
        return self.values["MEMBER_ONLY"].strip().lower() in ("yes", "true", "1", "on")

    def exceptions(self):
        return [a for a in re.split(r"[\s,]+", self.values["DOOR_EXCEPTIONS"]) if a]

    def request_max(self):
        return max(1024, to_int(self.values["REQUEST_MAX_BYTES"], 65536))

    def reconnect_bounds(self):
        lo = max(1, to_int(self.values["RECONNECT_MIN_SECS"], 1))
        hi = max(lo, to_int(self.values["RECONNECT_MAX_SECS"], 60))
        return lo, hi


def conf_text(name, socket_group=None):
    """The conf a claw is seeded with, and the list the installer adopts against.

    A key this text gains in a later release is appended to a conf that
    already exists, with its shipped default. No key already there is
    rewritten.
    """
    name = connection_name(name)
    out = [
        "# /etc/commonclaw/conn-%s.conf: this claw's ruling for the %s connection." % (name, name),
        "#",
        "# Every setting resolves in one order: the environment (COMMONCLAW_CONN_<KEY>),",
        "# then this file, then the shipped default. First match wins.",
        "#",
        "# NO SECRET HERE. A credential this service reads from a vault is a reference",
        "# in /etc/commonclaw/conn-%s.env, and a reference is not a value." % name,
        "#",
        "# The directories and the socket follow from the connection's name and are",
        "# not settings: the unit lets the service write under /srv/connections/%s/" % name,
        "# alone.",
        "",
    ]
    for key, default, what in TUNABLE:
        value = socket_group if (key == "SOCKET_GROUP" and socket_group) else default
        words = what.split()
        line = "# %s " % key
        for w in words:
            if len(line) + len(w) + 1 > 79:
                out.append(line.rstrip())
                line = "#   "
            line += w + " "
        out.append(line.rstrip())
        out.append('%s="%s"' % (key, value))
        out.append("")
    return "\n".join(out)
