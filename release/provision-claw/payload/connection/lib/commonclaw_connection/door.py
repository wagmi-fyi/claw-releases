"""The socket door: who is calling, whether they may, and one answer.

Lifted from payload/email-gatekeeper/email-gatekeeper, `serve_socket` and
`serve_one`. One JSON request and one JSON answer per connection, over a UNIX
socket. What changes from the gatekeeper:

  - THE DOOR REFUSES. The gatekeeper never refuses a caller who can open its
    socket. A connection service holds a credential, so in member-only mode,
    the default, the door refuses an account that is not a person on this
    claw unless the conf names it.
  - A REQUEST HAS A SIZE CAP, read from the conf, and a request over it is
    answered with a refusal. The gatekeeper stopped reading at 8 MiB and then
    parsed what it had.
  - THE SOCKET COMES FROM SYSTEMD. The socket unit the installer renders makes
    the socket with the conf's group, so the service account never has to be
    a member of that group. The door binds a socket of its own only when no
    socket was handed to it, which is a control or a hand run.
"""

import json
import os
import pwd
import socket
import struct
import subprocess
import threading
import time

from .log import log

# The first descriptor systemd hands a socket-activated service.
SD_LISTEN_FDS_START = 3

# A request field the caller types about itself. The door records it under
# `claimed`, beside the account the kernel measured, and never trusts it.
CLAIM_FIELDS = ("handle",)


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())


def peer_of(conn):
    """The caller, as the kernel measured it. A caller cannot choose SO_PEERCRED."""
    peer = {"uid": None, "gid": None, "pid": None, "user": "?"}
    try:
        raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        pid, uid, gid = struct.unpack("3i", raw)
        peer.update({"uid": uid, "gid": gid, "pid": pid})
        try:
            peer["user"] = pwd.getpwuid(uid).pw_name
        except KeyError:
            peer["user"] = str(uid)
    except OSError:
        pass
    return peer


def person_test_path():
    return os.environ.get("COMMONCLAW_CONN_PERSON_SH",
                          os.path.join(os.path.dirname(os.path.abspath(__file__)), "person.sh"))


def person_test(user):
    """cc_is_person from scripts/person.sh: 0 a person, 1 not, 2 no such account.

    THE TEST IS person.sh ITSELF, run through bash, and never a copy written in
    Python. The installer lays the file beside this package from the same
    source the provisioning run reads, and checks the two digests agree. A
    second implementation would drift, and the answer it would drift on is who
    receives a credential.

    Anything else fails closed: a missing file or a test that did not run is
    answered as "not a person".
    """
    path = person_test_path()
    if not os.path.isfile(path):
        return 1, "the person test is not installed at %s" % path
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    try:
        p = subprocess.run(
            ["bash", "-c", '. "$1" && cc_is_person "$2"', "person-test", path, user],
            env=env, capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, "the person test did not run: %s" % str(exc)[:120]
    if p.returncode in (0, 1, 2):
        return p.returncode, ""
    return 1, "the person test answered %d" % p.returncode


class Door:
    """One door per service. `handler(request, peer)` returns the answer dict."""

    def __init__(self, settings, handler, audit=None):
        self.settings = settings
        self.handler = handler
        self.audit = audit
        self.stop = threading.Event()

    # -- the decision -----------------------------------------------------
    def admit(self, peer):
        """(True, "") to let the caller in, or (False, the sentence it is told)."""
        user = peer.get("user") or "?"
        if not self.settings.member_only():
            return True, ""
        if user in self.settings.exceptions():
            peer["exception"] = True
            return True, ""
        code, why = person_test(user)
        peer["person"] = (code == 0)
        if code == 0:
            return True, ""
        if why:
            return False, "this door lets people through and %s" % why
        return False, ("%s is not a person on this claw, and %s names no exception for it"
                       % (user, self.settings.conf_path))

    def answer(self, data, overflow, peer):
        """The whole door for one request, with no socket in it. Returns the answer."""
        verb = ""
        claimed = {}
        if overflow:
            resp = {"ok": False, "reason": "the request is over %d bytes, the most this door reads"
                    % self.settings.request_max()}
            self.record(peer, verb, claimed, False, resp["reason"])
            return resp
        try:
            req = json.loads(data.decode("utf-8", "replace").strip() or "{}")
        except ValueError:
            resp = {"ok": False, "reason": "the request is not one JSON object"}
            self.record(peer, verb, claimed, False, resp["reason"])
            return resp
        if not isinstance(req, dict):
            resp = {"ok": False, "reason": "the request is not one JSON object"}
            self.record(peer, verb, claimed, False, resp["reason"])
            return resp
        verb = str(req.get("verb", ""))[:64]
        claimed = dict((k, str(req[k])[:128]) for k in CLAIM_FIELDS if k in req)
        admitted, why = self.admit(peer)
        if not admitted:
            self.record(peer, verb, claimed, False, why)
            return {"ok": False, "reason": why}
        if not self.settings.enabled():
            why = ("ENABLED is not yes in %s, so this service is deliberately off"
                   % self.settings.conf_path)
            self.record(peer, verb, claimed, False, why)
            return {"ok": False, "reason": why}
        self.record(peer, verb, claimed, True, "")
        try:
            resp = self.handler(req, peer)
        except Exception as exc:
            resp = {"ok": False, "reason": str(exc)[:400]}
        if not isinstance(resp, dict):
            resp = {"ok": False, "reason": "the service answered something that is not an object"}
        return resp

    def record(self, peer, verb, claimed, admitted, reason):
        log("info" if admitted else "warn",
            "%s from %s (uid %s)%s" % (verb or "a request", peer.get("user"), peer.get("uid"),
                                       "" if admitted else ": refused, " + reason))
        if self.audit is not None:
            try:
                self.audit.record(peer, "door", claimed=claimed, verb=verb,
                                  admitted=admitted, reason=reason)
            except Exception as exc:
                log("err", "the door could not write its audit line: %s" % str(exc)[:200])

    # -- the socket -------------------------------------------------------
    def listening_socket(self):
        """The socket systemd handed over, or one bound here when there is none."""
        if (os.environ.get("LISTEN_PID") == str(os.getpid())
                and os.environ.get("LISTEN_FDS") == "1"):
            return socket.socket(fileno=SD_LISTEN_FDS_START)
        path = self.settings.socket
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        try:
            import grp
            os.chown(path, -1, grp.getgrnam(self.settings.socket_group).gr_gid)
        except (KeyError, OSError) as exc:
            log("warn", "this process bound its own socket and could not give it the group %s: %s"
                % (self.settings.socket_group, exc))
        os.chmod(path, 0o660)
        srv.listen(16)
        return srv

    def serve_forever(self):
        srv = self.listening_socket()
        srv.settimeout(1.0)
        log("info", "the door is open on %s" % (srv.getsockname() or self.settings.socket))
        while not self.stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                continue
            threading.Thread(target=self.serve_one, args=(conn,), daemon=True).start()

    def serve_one(self, conn):
        peer = peer_of(conn)
        cap = self.settings.request_max()
        try:
            conn.settimeout(30)
            data = b""
            overflow = False
            while b"\n" not in data:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
                if len(data) > cap:
                    overflow = True
                    break
            resp = self.answer(data, overflow, peer)
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        except Exception as exc:
            log("warn", "a socket request failed: %s" % str(exc)[:200])
        finally:
            try:
                conn.close()
            except OSError:
                pass
