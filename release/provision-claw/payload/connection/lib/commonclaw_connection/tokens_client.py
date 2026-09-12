"""The session side of the token service: one socket client, standard library only.

NEW, for the token service. A session never holds a refresh token or a client
secret. It asks the service for the current credential with `get`, and when a
provider refuses one it reports the refusal with `rejected` and takes the
answer. The two adapters beside this module, `http_auth` and `mcp_storage`,
are built on it, and so are the `token` command and the seed door.

HOW A SESSION'S PYTHON FINDS THIS. The installer lays the package under
/opt/commonclaw/lib/python, readable by everybody on the claw. A session puts
that directory on its path, with PYTHONPATH or a line of its own, and imports
`commonclaw_connection.tokens_client`. The package's other modules import only
the standard library at load, so importing this one costs nothing a session
does not already have.

    from commonclaw_connection.tokens_client import TokensClient
    cred = TokensClient().get("provider/account")

A credential this returns stays inside the process that asked for it. Nothing
here prints one, logs one or writes one to disk.
"""

import hashlib
import json
import os
import socket

SOCKET = "/run/commonclaw-conn-tokens/sock"


def fingerprint(value):
    """The first 16 hex characters of a value's SHA-256. The service speaks in these."""
    if not value:
        return ""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


class TokensError(Exception):
    """The service refused, or could not be reached. The message names no value."""


class TokensClient:
    def __init__(self, socket_path=None, timeout=60):
        self.socket_path = socket_path or os.environ.get("COMMONCLAW_TOKENS_SOCKET", SOCKET)
        self.timeout = timeout

    def call(self, req):
        """One request and one answer. Raises TokensError when the service cannot be reached."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(self.timeout)
            try:
                s.connect(self.socket_path)
            except OSError as exc:
                raise TokensError("the token service is not answering at %s: %s. "
                                  "systemctl status commonclaw-conn-tokens says why"
                                  % (self.socket_path, exc))
            s.sendall((json.dumps(req) + "\n").encode("utf-8"))
            data = b""
            while b"\n" not in data:
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            raise TokensError("the token service did not answer within %d seconds" % self.timeout)
        finally:
            s.close()
        try:
            resp = json.loads(data.decode("utf-8", "replace").strip() or "{}")
        except ValueError:
            raise TokensError("the token service answered something that is not JSON")
        if not isinstance(resp, dict):
            raise TokensError("the token service answered something that is not an object")
        return resp

    def _ok(self, resp):
        if not resp.get("ok"):
            raise TokensError(resp.get("reason") or "the token service refused without a reason")
        return resp

    def get(self, row):
        """The current credential for a row, as the service answers it.

        An oauth row answers access_token, token_type, expires_at, fingerprint
        and client, the public registration. A key row answers key and
        fingerprint.
        """
        return self._ok(self.call({"verb": "get", "row": row}))

    def rejected(self, row, token_or_fingerprint):
        """Report that the provider refused a credential, and take the one to use now.

        Pass the refused token or its fingerprint. Only the fingerprint leaves
        this process.
        """
        told = token_or_fingerprint or ""
        if len(told) != 16 or any(c not in "0123456789abcdef" for c in told):
            told = fingerprint(told)
        return self._ok(self.call({"verb": "rejected", "row": row, "fingerprint": told}))

    def status(self, row=None, seeded_by=None):
        req = {"verb": "status"}
        if row:
            req["row"] = row
        if seeded_by:
            req["seeded_by"] = seeded_by
        return self._ok(self.call(req))
