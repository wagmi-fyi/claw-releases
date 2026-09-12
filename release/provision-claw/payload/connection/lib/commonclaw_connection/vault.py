"""The read of the claw's machine vault, for a service whose manifest says it reads one.

Lifted from payload/email-gatekeeper/email-gatekeeper, `resolve_key`, made
generic: the reference is named by its key in /etc/commonclaw/conn-{name}.env
rather than hard-coded.

THE VALUE NEVER TOUCHES DISK AND NEVER TOUCHES A COMMAND LINE. /proc/PID/cmdline
is world-readable on a claw, so the manager's token reaches `op` through that
child's environment alone.

Only a unit rendered with the machine credential can resolve anything. The
installer hands the credential to the unit only when the manifest says
READS_VAULT=yes, so a service that does not read a vault finds no token here
and is told so.
"""

import os
import subprocess

MACHINE_CRED_FILE = "/etc/commonclaw/credentials/op-service-account.cred"
MACHINE_CRED_NAME = "op-service-account"


def machine_token():
    """The machine credential, read from a file at the moment of use.

    Under the unit, systemd has decrypted it into the credentials directory.
    Run by hand as root there is no unit, and root decrypts the claw's own
    credential itself. An inherited variable is never a source.
    """
    tok = ""
    cdir = os.environ.get("CREDENTIALS_DIRECTORY", "")
    cpath = os.path.join(cdir, MACHINE_CRED_NAME) if cdir else ""
    if cpath and os.access(cpath, os.R_OK):
        with open(cpath, "r", encoding="utf-8") as fh:
            tok = fh.read().strip()
    elif os.access(MACHINE_CRED_FILE, os.R_OK):
        try:
            tok = subprocess.run(
                ["systemd-creds", "decrypt", "--name=" + MACHINE_CRED_NAME, MACHINE_CRED_FILE, "-"],
                capture_output=True, text=True, timeout=30,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            tok = ""
    return tok


def reference(settings, key):
    for line in _lines(settings.env_path):
        line = line.strip()
        if line.startswith(key + "=op://"):
            return line.split("=", 1)[1].strip()
    return ""


def _lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.readlines()
    except OSError:
        return []


def resolve_reference(settings, key):
    """The value behind one reference in the env file. Raises with a reason that names no value."""
    ref = reference(settings, key)
    if not ref:
        raise RuntimeError("%s carries no %s op:// reference" % (settings.env_path, key))
    tok = machine_token()
    if not tok:
        raise RuntimeError("no machine credential reached this process, so %s in %s could not "
                           "be resolved. The unit carries it only when the manifest says "
                           "READS_VAULT=yes" % (key, settings.env_path))
    env = dict(os.environ)
    env["OP_SERVICE_ACCOUNT_TOKEN"] = tok
    try:
        p = subprocess.run(["op", "read", ref], capture_output=True, text=True,
                           env=env, timeout=60)
    except OSError:
        raise RuntimeError("the manager CLI is not installed, so %s cannot be resolved" % key)
    value = (p.stdout or "").strip()
    if p.returncode != 0 or not value:
        raise RuntimeError("the manager returned no value for %s in %s" % (key, settings.env_path))
    return value
