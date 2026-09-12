"""The audit log: one JSON line per act, the measured caller beside the claim.

Lifted from payload/email-gatekeeper/email-gatekeeper, `record_send` and
`append_json`. `peer_uid` and `peer_user` are measured from the socket and a
caller cannot choose them. What a caller typed about itself goes under
`claimed`, which nobody can check. The line says which is which, the way the
bus records `from` beside `sender`.

NO VALUE IS EVER WRITTEN HERE. A field whose name reads like a credential is
refused before the line is written, unless the name says it is a fingerprint.
The log sits under /srv, which the backup rail captures, so a value written
once is in every snapshot inside the retention window.
"""

import json
import os
import re
import threading
import time

SECRET_NAME = re.compile(r"(token|secret|password|passwd|credential|key)", re.I)
FINGERPRINT_NAME = re.compile(r"(_fp|fingerprint)$", re.I)


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())


def refuse_secret_names(obj, where=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            name = str(k)
            if SECRET_NAME.search(name) and not FINGERPRINT_NAME.search(name):
                raise ValueError("the audit log refuses a field named '%s%s': it reads like a "
                                 "credential. Record a fingerprint under a name ending in _fp"
                                 % (where, name))
            refuse_secret_names(v, where + name + ".")
    elif isinstance(obj, list):
        for v in obj:
            refuse_secret_names(v, where)


class AuditLog:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def record(self, peer, event, claimed=None, **fields):
        refuse_secret_names(fields)
        refuse_secret_names(claimed or {}, "claimed.")
        line = {
            "ts": iso_now(),
            "event": event,
            "peer_uid": peer.get("uid"),
            "peer_user": peer.get("user"),
            "claimed": claimed or {},
        }
        for k, v in fields.items():
            if k not in line:
                line[k] = v
        text = json.dumps(line, sort_keys=True) + "\n"
        with self.lock:
            os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(text)
        return line
