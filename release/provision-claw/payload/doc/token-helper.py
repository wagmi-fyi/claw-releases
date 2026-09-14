#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""token-helper.py: approve a claw at an OAuth provider, from your own computer.

    uv run token-helper.py --metadata URL --vault VAULT --item ITEM
                           [--scope SCOPE]... [--resource URL]
                           [--client-id ID] [--port N]

WHAT IT DOES. It reads the provider's OAuth metadata. It registers a public
client when the provider offers registration and you gave no client id. It
opens your browser at the provider's approval page, with PKCE (S256). It
catches the redirect on your own computer's loopback address and exchanges the
code for the first tokens. It then writes the seed into the vault item the
claw's `token add` named, through your own password manager's command line.
On the claw, the seed door reads that item once and hands it to the token
service.

WHAT IT NEEDS. uv and Python 3.9 or later. A browser. Your password manager's
command line, `op`, signed in with write on the vault. Nothing else: this file
imports only the standard library.

WHAT IT DOES NOT DO. It prints no token and no secret, and it writes none to
disk except the manager's own template file, which it makes private and
removes. It sends nothing to the claw. It keeps no copy after it exits.

The claw's seed door runs this same file with --seed-to-fd on the tunnel path.
There the seed goes to the door through a pipe and never to a vault.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

# The field names the claw's token service reads from the item. `token status`
# on the claw lists the same names under seed_fields.
FIELDS_REQUIRED = ("client_id", "refresh_token")
FIELDS_OPTIONAL = ("client_secret", "access_token", "expires_at", "registration")
CLIENT_NAME = "claw token helper"


def say(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def fail(msg, code=1):
    say("token-helper: " + msg)
    sys.exit(code)


def fingerprint(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16] if value else ""


def request_json(url, data=None, json_body=None):
    headers = {"Accept": "application/json", "User-Agent": "claw-token-helper"}
    body = None
    if json_body is not None:
        body = json.dumps(json_body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif data is not None:
        body = urllib.parse.urlencode(data).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=body, headers=headers, method="POST" if body else "GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
    except (urllib.error.URLError, OSError) as exc:
        fail("%s did not answer: %s" % (url, getattr(exc, "reason", exc)))
    try:
        obj = json.loads(raw.decode("utf-8", "replace") or "{}")
    except ValueError:
        obj = {}
    return status, obj if isinstance(obj, dict) else {}


def url_ok(url):
    u = urllib.parse.urlparse(url)
    return (u.scheme == "https" and bool(u.hostname)) or \
        (u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost", "::1"))


class Catcher(http.server.BaseHTTPRequestHandler):
    """One redirect, on the loopback address, and nothing else."""
    result = {}
    done = threading.Event()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path != "/callback":
            self.send_response(404)
            self.end_headers()
            return
        q = dict(urllib.parse.parse_qsl(u.query))
        Catcher.result.update(q)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"<p>The approval reached your computer. You can close this tab.</p>")
        Catcher.done.set()

    def log_message(self, *a):
        pass


def approve(args):
    """The approval, the redirect and the exchange. Returns the seed as a dict."""
    for label, url in (("metadata", args.metadata), ("resource", args.resource)):
        if url and not url_ok(url):
            fail("the %s %s is not an https URL" % (label, url), 2)
    status, meta = request_json(args.metadata)
    for k in ("authorization_endpoint", "token_endpoint"):
        if status != 200 or not meta.get(k):
            fail("the metadata at %s names no %s, so this provider does not approve in a "
                 "browser. Seed it by paste" % (args.metadata, k.replace("_", " ")))
    methods = meta.get("code_challenge_methods_supported") or []
    if methods and "S256" not in methods:
        fail("the provider does not offer PKCE with S256, which this helper requires")

    server = http.server.HTTPServer(("127.0.0.1", args.port), Catcher)
    port = server.server_address[1]
    redirect = "http://127.0.0.1:%d/callback" % port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        client_id = args.client_id
        registration = {}
        client_secret = ""
        if not client_id:
            if not meta.get("registration_endpoint"):
                fail("the provider offers no registration, so pass the client id it gave you "
                     "with --client-id", 2)
            ask = {"client_name": CLIENT_NAME, "redirect_uris": [redirect],
                   "grant_types": ["authorization_code", "refresh_token"],
                   "response_types": ["code"], "token_endpoint_auth_method": "none"}
            if args.scope:
                ask["scope"] = " ".join(args.scope)
            status, reg = request_json(meta["registration_endpoint"], json_body=ask)
            if status not in (200, 201) or not reg.get("client_id"):
                fail("the provider did not register a client: it answered %d" % status)
            client_id = reg["client_id"]
            client_secret = reg.pop("client_secret", "") or ""
            reg.pop("registration_access_token", None)
            registration = reg
            say("registered a public client with the provider: %s" % client_id)

        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
        state = secrets.token_urlsafe(24)
        q = {"response_type": "code", "client_id": client_id, "redirect_uri": redirect,
             "code_challenge": challenge, "code_challenge_method": "S256", "state": state}
        if args.scope:
            q["scope"] = " ".join(args.scope)
        if args.resource:
            q["resource"] = args.resource
        sep = "&" if "?" in meta["authorization_endpoint"] else "?"
        link = meta["authorization_endpoint"] + sep + urllib.parse.urlencode(q)
        say("")
        say("Approve the claw at the provider. The link:")
        say("  " + link)
        say("")
        if not args.no_browser:
            try:
                webbrowser.open(link)
            except Exception:
                pass
        if not Catcher.done.wait(args.timeout):
            fail("no approval arrived within %d seconds" % args.timeout)
        res = dict(Catcher.result)
    finally:
        server.shutdown()
        server.server_close()
    if res.get("error"):
        fail("the provider answered the approval with %s" % res["error"][:64])
    if res.get("state") != state:
        fail("the redirect carried another state, so it was not this approval. Nothing was kept")
    code = res.get("code") or ""
    if not code:
        fail("the redirect carried no code")

    form = {"grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": client_id, "code_verifier": verifier}
    if args.resource:
        form["resource"] = args.resource
    if client_secret:
        form["client_secret"] = client_secret
    status, tok = request_json(meta["token_endpoint"], data=form)
    form = None
    if status != 200 or not tok.get("access_token"):
        fail("the provider did not exchange the code: it answered %d %s"
             % (status, str(tok.get("error", ""))[:64]))
    if not tok.get("refresh_token"):
        fail("the provider returned no refresh token, so the claw could not renew the access. "
             "Its documentation names the scope that grants offline access")
    seed = {"client_id": client_id, "refresh_token": tok["refresh_token"],
            "access_token": tok["access_token"]}
    if tok.get("expires_in"):
        try:
            seed["expires_at"] = str(int(time.time()) + int(tok["expires_in"]))
        except (TypeError, ValueError):
            pass
    if client_secret:
        seed["client_secret"] = client_secret
    if registration:
        seed["registration"] = json.dumps(registration, sort_keys=True)
    tok = None
    say("the provider approved: access %s, refresh %s (fingerprints)"
        % (fingerprint(seed["access_token"]), fingerprint(seed["refresh_token"])))
    return seed


def write_vault(args, seed):
    """The seed into the item, through the person's own manager command line."""
    op = shutil.which(args.op) or args.op
    fields = []
    for k in FIELDS_REQUIRED + FIELDS_OPTIONAL:
        if k in seed:
            fields.append({"id": k, "label": k, "value": seed[k],
                           "type": "STRING" if k in ("client_id", "expires_at", "registration")
                           else "CONCEALED"})
    template = {"title": args.item, "category": "API_CREDENTIAL", "fields": fields}
    seed.clear()
    # THE VALUES REACH THE MANAGER THROUGH A TEMPLATE FILE, never an argument. The
    # file sits in a directory only this account opens, and it is removed on
    # every path out.
    d = tempfile.mkdtemp(prefix="token-helper-")
    os.chmod(d, 0o700)
    path = os.path.join(d, "item.json")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(template, fh)
        template = None
        fields = None
        exists = subprocess.run([op, "item", "get", args.item, "--vault", args.vault,
                                 "--format", "json"], stdin=subprocess.DEVNULL,
                                capture_output=True).returncode == 0
        verb = ["item", "edit", args.item] if exists else ["item", "create"]
        p = subprocess.run([op] + verb + ["--vault", args.vault, "--template", path],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, text=True)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    if p.returncode != 0:
        fail("the password manager did not take the seed (exit %d): %s"
             % (p.returncode, (p.stderr or "").strip()[:300]))
    say("the seed is in %s in the vault %s (%s)" % (args.item, args.vault,
                                                    "edited" if exists else "created"))


def main():
    ap = argparse.ArgumentParser(prog="token-helper.py", description=__doc__.splitlines()[0])
    ap.add_argument("--metadata", required=True, help="the provider's OAuth metadata URL")
    ap.add_argument("--vault", default="", help="the claw's vault, as token add printed it")
    ap.add_argument("--item", default="", help="the seed item, as token add printed it")
    ap.add_argument("--scope", action="append", default=[])
    ap.add_argument("--resource", default="")
    ap.add_argument("--client-id", dest="client_id", default="",
                    help="a client the provider gave you, where it offers no registration")
    ap.add_argument("--port", type=int, default=8765, help="the loopback port for the redirect")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--op", default="op", help="the password manager's command line")
    ap.add_argument("--no-browser", dest="no_browser", action="store_true",
                    help="print the link and open nothing")
    ap.add_argument("--seed-to-fd", dest="seed_fd", type=int, default=-1,
                    help="the seed door's pipe; the seed goes there and to no vault")
    args = ap.parse_args()
    if args.seed_fd < 0 and not (args.vault and args.item):
        fail("--vault and --item name where the seed goes. token add on the claw printed both", 2)
    seed = approve(args)
    if args.seed_fd >= 0:
        with os.fdopen(args.seed_fd, "w") as fh:
            json.dump(seed, fh)
        seed.clear()
        say("the seed went to the door through its pipe")
        return 0
    write_vault(args, seed)
    say("Next, on the claw, a claw-admin runs the seed door for this row.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
