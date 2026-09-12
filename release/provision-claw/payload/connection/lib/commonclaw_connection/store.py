"""The sealed store: what a connection keeps between restarts, encrypted at rest.

NEW, with no gatekeeper original: the gatekeeper holds nothing on disk.

THE KEY. One 32-byte data key per connection. The installer mints it once and
seals it with `systemd-creds encrypt` under the host key, into
/etc/commonclaw/credentials/conn-{name}-key.cred. The unit hands it to the
service through LoadCredentialEncrypted, so the clear key exists only in the
unit's own credentials directory, which systemd keeps in memory and shows to
the unit's account alone.

THE RECORDS. One file per record under the store directory, sealed with
AES-256-GCM from python3-cryptography. The connection's name and the record's
name are bound into the seal as associated data, so a file copied to another
record's name, or into another connection's store, does not open. A write goes
to a temporary file in the same directory, is flushed to disk, and is renamed
over the old one, so a crash leaves the old record or the new one and never
half of either. A provider that invalidates the old refresh token at each
refresh makes that property the difference between a claw that keeps working
and one a person has to approve again.

A RECORD WHOSE SEAL FAILS IS REPORTED AND LEFT AS IT IS. Nothing here deletes
or rewrites a record it cannot open.

THE BACKENDS. `encrypted-local` is the one built, and it is the service's
truth. `manager-write-back` is a named seam: the store calls a second writer
after each local write, and nothing is built behind it in this release.
"""

import json
import os
import re
import subprocess
import tempfile
import threading

from .log import log

MAGIC = b"CCS1"
NONCE_LEN = 12
TAG_LEN = 16
KEY_LEN = 32
SUFFIX = ".seal"
TEMP_PREFIX = ".tmp-"
AAD_PREFIX = b"commonclaw-conn-record/1\x00"

# A record name is one or more segments joined by "/", as `provider/account`.
# "+" cannot appear in a segment, so the file name the store derives from a
# record name, with "/" written as "+", names one record and only one.
RECORD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$")

# The fields whose values the store check searches the disk for. A service
# passes its own list where it keeps a secret under another name.
DEFAULT_SECRET_FIELDS = ("access_token", "refresh_token", "id_token", "client_secret",
                         "key", "api_key", "secret", "password")

# A value shorter than this is not searched for. Random ciphertext matches a
# short string often enough to make the count noise, and no credential this
# store holds is that short.
MIN_SEARCH_LEN = 8


class SealError(Exception):
    """A record that does not open. The message names the record and no value."""


class NotBuilt(Exception):
    """A backend that is a seam in this release."""


def key_cred_name(connection):
    return "conn-%s-key" % connection


def key_cred_file(connection):
    return "/etc/commonclaw/credentials/conn-%s-key.cred" % connection


def read_data_key(connection):
    """The data key, from the unit's credentials directory, or decrypted by root.

    Two paths, the same two the machine credential has: the directory systemd
    fills for the unit, and root decrypting the sealed file by hand. The key
    is never read from the environment and never passed on a command line.
    """
    name = key_cred_name(connection)
    key = b""
    cdir = os.environ.get("CREDENTIALS_DIRECTORY", "")
    cpath = os.path.join(cdir, name) if cdir else ""
    if cpath and os.access(cpath, os.R_OK):
        with open(cpath, "rb") as fh:
            key = fh.read()
    elif os.access(key_cred_file(connection), os.R_OK):
        try:
            key = subprocess.run(
                ["systemd-creds", "decrypt", "--name=" + name, key_cred_file(connection), "-"],
                capture_output=True, timeout=30).stdout
        except (OSError, subprocess.SubprocessError):
            key = b""
    if not key:
        raise RuntimeError("no data key reached this process: the unit loads %s, and root can "
                           "decrypt %s" % (name, key_cred_file(connection)))
    if len(key) != KEY_LEN:
        raise RuntimeError("the data key %s is %d bytes and a key is %d" % (name, len(key), KEY_LEN))
    return key


def _aead(key):
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError:
        raise RuntimeError("python3-cryptography is not installed. The installer adds it from "
                           "the distribution's archive")
    return AESGCM(key)


class EncryptedLocal:
    kind = "encrypted-local"

    def __init__(self, directory, key, connection, create=True):
        if len(key) != KEY_LEN:
            raise RuntimeError("a data key is %d bytes and this one is %d" % (KEY_LEN, len(key)))
        self.dir = os.path.abspath(directory)
        self.connection = connection
        self.aead = _aead(key)
        self.lock = threading.Lock()
        # A HOOK FOR THE CRASH CONTROL. Called after the temporary file is on
        # disk and before the rename. Nothing on a claw sets it.
        self.before_replace = None
        if create and not os.path.isdir(self.dir):
            os.makedirs(self.dir, exist_ok=True)
            os.chmod(self.dir, 0o700)

    # -- names ------------------------------------------------------------
    def path_for(self, name):
        if not isinstance(name, str) or not RECORD_RE.match(name):
            raise ValueError("'%s' is not a record name: segments of letters, digits, dots, "
                             "underscores and hyphens, joined by /" % name)
        path = os.path.join(self.dir, name.replace("/", "+") + SUFFIX)
        # A WRITE OUTSIDE THE STORE DIRECTORY IS REFUSED. The name rule already
        # keeps one out; this is the second wall, measured on the path itself.
        if os.path.dirname(os.path.abspath(path)) != self.dir:
            raise ValueError("'%s' would land outside %s" % (name, self.dir))
        return path

    def aad(self, name):
        return AAD_PREFIX + self.connection.encode() + b"\x00" + name.encode()

    def names(self):
        out = []
        try:
            entries = sorted(os.listdir(self.dir))
        except OSError:
            return out
        for f in entries:
            if f.startswith(".") or not f.endswith(SUFFIX):
                continue
            name = f[:-len(SUFFIX)].replace("+", "/")
            if RECORD_RE.match(name):
                out.append(name)
        return out

    def temps(self):
        try:
            return sorted(f for f in os.listdir(self.dir) if f.startswith(TEMP_PREFIX))
        except OSError:
            return []

    def foreign(self):
        """Files in the store directory that are neither a record nor a write in flight."""
        records = set(n.replace("/", "+") + SUFFIX for n in self.names())
        try:
            entries = sorted(os.listdir(self.dir))
        except OSError:
            return []
        return [f for f in entries if f not in records and not f.startswith(TEMP_PREFIX)]

    def sweep_temps(self):
        """Temporary files a crash left behind. Called once, when the service opens its store.

        One process writes this directory, and at open nothing is in flight, so
        a temporary file here is a write that never reached its rename. The
        record it was replacing is still whole.
        """
        n = 0
        for f in self.temps():
            try:
                os.unlink(os.path.join(self.dir, f))
                n += 1
            except OSError:
                pass
        return n

    # -- the seal ---------------------------------------------------------
    def seal(self, name, plaintext):
        nonce = os.urandom(NONCE_LEN)
        return MAGIC + nonce + self.aead.encrypt(nonce, plaintext, self.aad(name))

    def unseal(self, name, blob):
        if len(blob) < len(MAGIC) + NONCE_LEN + TAG_LEN or not blob.startswith(MAGIC):
            raise SealError("%s is not a sealed record. It was left as it is" % name)
        nonce = blob[len(MAGIC):len(MAGIC) + NONCE_LEN]
        body = blob[len(MAGIC) + NONCE_LEN:]
        try:
            return self.aead.decrypt(nonce, body, self.aad(name))
        except Exception:
            raise SealError("the seal on %s does not open: the file was changed, carries "
                            "another record's name, or was sealed under another key. It was "
                            "left as it is" % name)

    # -- the acts ---------------------------------------------------------
    def write(self, name, obj):
        path = self.path_for(name)
        blob = self.seal(name, json.dumps(obj, sort_keys=True).encode("utf-8"))
        with self.lock:
            fd, tmp = tempfile.mkstemp(prefix=TEMP_PREFIX, dir=self.dir)
            try:
                view = memoryview(blob)
                while view:
                    n = os.write(fd, view)
                    view = view[n:]
                os.fsync(fd)
            finally:
                os.close(fd)
            try:
                if self.before_replace is not None:
                    self.before_replace()
                os.replace(tmp, path)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
            dfd = os.open(self.dir, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)

    def read(self, name):
        path = self.path_for(name)
        with open(path, "rb") as fh:
            blob = fh.read()
        return json.loads(self.unseal(name, blob).decode("utf-8"))

    def delete(self, name):
        os.unlink(self.path_for(name))


class ManagerWriteBack:
    """The second writer after each local write. A seam: nothing is built behind it."""

    kind = "manager-write-back"
    SENTENCE = ("STORE_BACKEND=manager-write-back names a seam, and nothing is built behind "
                "it in this release. It is built when a firm asks for it, and it then writes "
                "to a vault of its own through a writing account of its own. Set STORE_BACKEND "
                "to encrypted-local")

    def __init__(self, settings=None):
        raise NotBuilt(self.SENTENCE)

    def after_write(self, name, obj):
        raise NotBuilt(self.SENTENCE)


BACKENDS = ("encrypted-local", "manager-write-back")


class Store:
    """The store a service opens once at start. Local first, and local is the truth."""

    def __init__(self, settings, key=None):
        backend = settings.store_backend
        if backend not in BACKENDS:
            raise RuntimeError("STORE_BACKEND=%s in %s names no backend. The one built is "
                               "encrypted-local" % (backend, settings.conf_path))
        self.local = EncryptedLocal(settings.store_dir,
                                    key if key is not None else read_data_key(settings.name),
                                    settings.name)
        self.write_back = ManagerWriteBack(settings) if backend == "manager-write-back" else None
        self.write_back_error = ""
        self.swept = self.local.sweep_temps()
        if self.swept:
            log("warn", "%d write(s) a crash left before their rename were swept from %s; "
                "the records they were replacing are whole" % (self.swept, self.local.dir))

    def put(self, name, obj):
        self.local.write(name, obj)
        if self.write_back is not None:
            # A WRITE-BACK THAT FAILS NEVER BLOCKS A SESSION. It shows in the
            # health line, and the local record stays the truth.
            try:
                self.write_back.after_write(name, obj)
                self.write_back_error = ""
            except Exception as exc:
                self.write_back_error = str(exc)[:300]
                log("warn", "the write-back after %s did not land: %s" % (name, self.write_back_error))

    def get(self, name):
        return self.local.read(name)

    def remove(self, name):
        self.local.delete(name)

    def names(self):
        return self.local.names()


def secret_values(obj, fields):
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in fields and isinstance(v, str):
                out.append(v)
            else:
                out.extend(secret_values(v, fields))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(secret_values(v, fields))
    return out


def _walk(root):
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for f in filenames:
            p = os.path.join(dirpath, f)
            if os.path.isfile(p) and not os.path.islink(p):
                yield p


def store_check(settings, key=None, values=(), secret_fields=DEFAULT_SECRET_FIELDS):
    """Open every record, then search every byte on disk for the values they hold.

    Inside this process and nowhere else: the values are read from the records
    and from `values`, searched for, and never printed, logged or returned. The
    answer is counts and file names. It writes nothing, so a temporary file a
    crash left is counted rather than swept.

    Clean means every record opened, the store directory holds nothing that is
    not a record, and no value was found in clear anywhere under the state and
    log directories.
    """
    local = EncryptedLocal(settings.store_dir,
                           key if key is not None else read_data_key(settings.name),
                           settings.name, create=False)
    report = {"connection": settings.name, "store_dir": local.dir, "records": 0,
              "sealed": 0, "seal_failed": [], "foreign": local.foreign(),
              "temps": len(local.temps())}
    found = set(v for v in values if v)
    for name in local.names():
        report["records"] += 1
        try:
            obj = local.read(name)
        except (SealError, ValueError, OSError):
            report["seal_failed"].append(name)
            continue
        report["sealed"] += 1
        found.update(secret_values(obj, set(secret_fields)))
    search = [v.encode("utf-8") for v in found if len(v.encode("utf-8")) >= MIN_SEARCH_LEN]
    report["values"] = len(search)
    report["values_too_short"] = len(found) - len(search)
    files = 0
    hits = 0
    hit_files = []
    for root in (settings.state_dir, settings.log_dir):
        for p in _walk(root):
            files += 1
            try:
                with open(p, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            n = sum(data.count(v) for v in search)
            if n:
                hits += n
                hit_files.append(p)
    search = None
    found = None
    report["files_searched"] = files
    report["hits"] = hits
    report["hit_files"] = hit_files
    report["clean"] = (not report["seal_failed"] and not report["foreign"] and hits == 0)
    return report
