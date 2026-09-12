#!/bin/bash
#
# install-provider-seed.sh: hand one row's seed to this claw's token service.
#
# AGENT-INVOKED. One JSON line to stdout, progress to stderr.
#
# USAGE
#   sudo ./install-provider-seed.sh <provider>/<account>
#   sudo ./install-provider-seed.sh <provider>/<account> --reseed
#   sudo ./install-provider-seed.sh <provider>/<account> --authorize [--port N] [--client-id ID]
#   sudo ./install-provider-seed.sh <provider>/<account> --dry-run
#
# WHAT A SEED IS. What the token service cannot make for itself: a client
# registration and the first refresh token, or a static key. Getting one is a
# person's act. `token add` wrote the row and printed where the seed goes: an
# item in this claw's machine vault, which the person fills through their own
# password-manager app, by paste or with the laptop helper.
#
# WHAT THIS DOOR DOES. It asks the service which item and which fields the row
# names. It reads each field once through this claw's machine credential, the
# way the mail provider-key door reads it, and hands the seed to the service
# with `seed`. The service takes that verb from root alone. On success the last
# line of progress is the one word "seeded", and the JSON carries the expiry and
# the fingerprint. No value is printed.
#
# --authorize IS THE TUNNEL PATH, for a provider whose redirect has to reach the
# claw. The person opens `ssh -L PORT:127.0.0.1:PORT` to this claw and runs the
# door there. The door runs the laptop helper's own code on this claw: it
# registers a client, prints the approval link, catches the redirect through the
# tunnel and exchanges the code here. The seed goes straight to the service
# through a pipe. THE VAULT THEN HOLDS NO COPY OF IT, because this claw writes no
# vault, so on a rebuilt claw a person walks this path again.
#
# WHAT IT NEVER DOES. It writes no vault and deletes nothing: not the vault item,
# not a file it did not make. The value never appears on a command line, in
# output, in a log line, or on disk: it moves from the manager's stdout into this
# door's memory and onto the socket.
#
# EXIT CODES. 0 the row is seeded. 1 the service or the vault refused. 2 usage,
# or a claw that is not ready.
#
# THE OVERRIDES BELOW EXIST FOR CONTROLS. COMMONCLAW_CONN_LIB, TOKENS_SOCKET,
# CRED_FILE, OP_BIN, ADMIN_LOG, SEED_HELPER and DOOR_PATH_FIRST point this door
# at fixtures. Nothing on a claw sets them, and sudo passes none of them.
set -euo pipefail

# The caller's environment decides nothing. A member could export a token of
# their own, and a read that used it would read somebody else's vault.
unset OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_ACCOUNT || true
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ -z "${DOOR_PATH_FIRST:-}" ] || PATH="${DOOR_PATH_FIRST}:${PATH}"
export PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SEED_DOOR_LIB="${COMMONCLAW_CONN_LIB:-/opt/commonclaw/lib/python}"
export SEED_DOOR_SOCKET="${TOKENS_SOCKET:-/run/commonclaw-conn-tokens/sock}"
export SEED_DOOR_CRED_FILE="${CRED_FILE:-/etc/commonclaw/credentials/op-service-account.cred}"
export SEED_DOOR_OP="${OP_BIN:-op}"
export SEED_DOOR_ADMIN_LOG="${ADMIN_LOG:-/etc/commonclaw/admin-log.md}"
# THE HELPER IS THE LAPTOP HELPER'S OWN FILE, so the tunnel path and the helper
# path share one approval. From a stage it sits in the payload beside this
# script. On a claw the installed plane carries no payload, and the helper is
# read where members fetch it.
if [ -n "${SEED_HELPER:-}" ]; then
  export SEED_DOOR_HELPER="$SEED_HELPER"
elif [ -r "${HERE}/../payload/doc/token-helper.py" ]; then
  export SEED_DOOR_HELPER="${HERE}/../payload/doc/token-helper.py"
else
  export SEED_DOOR_HELPER="/opt/commonclaw/doc/token-helper.py"
fi

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0" >&2
  exit 2
}
case "${1:-}" in ""|-h|--help) usage ;; esac

[ "$(id -u)" -eq 0 ] || { printf 'run this as root: the token service takes a seed from root alone\n' >&2; exit 2; }

# THE ACCOUNT THE SEED IS RECORDED FOR, from what sudo recorded, never from the
# environment a caller could set. Root by hand is recorded as root.
BY="${SUDO_USER:-root}"
case "$BY" in [a-z_]*) : ;; *) BY="root" ;; esac
case "$BY" in *[!a-z0-9_-]*) BY="root" ;; esac
export SEED_DOOR_BY="$BY"

exec python3 -B - "$@" <<'PY'
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.environ["SEED_DOOR_LIB"])
try:
    from commonclaw_connection.tokens_client import TokensClient, TokensError, fingerprint
except ImportError:
    sys.stderr.write("no token service library at %s. Run provisioning first\n" % os.environ["SEED_DOOR_LIB"])
    sys.exit(2)

OUT = {"script": "install-provider-seed", "ok": False, "row": "", "path": "", "action": "none",
       "result": "", "seeded_for": os.environ["SEED_DOOR_BY"], "expires": "", "fingerprint": ""}


def say(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def finish(code, reason=""):
    if reason:
        OUT["reason"] = reason
        say("  FAIL  " + reason)
    print(json.dumps(OUT, sort_keys=True))
    sys.exit(code)


ap = argparse.ArgumentParser(prog="install-provider-seed.sh")
ap.add_argument("row")
ap.add_argument("--reseed", action="store_true")
ap.add_argument("--authorize", action="store_true")
ap.add_argument("--port", type=int, default=8765)
ap.add_argument("--client-id", dest="client_id", default="")
ap.add_argument("--dry-run", dest="dry_run", action="store_true")
a = ap.parse_args(sys.argv[1:])
OUT["row"] = a.row

client = TokensClient(socket_path=os.environ["SEED_DOOR_SOCKET"], timeout=120)
try:
    st = client.status(row=a.row)
except TokensError as exc:
    finish(2, str(exc))
rows = [r for r in st.get("rows", []) if r.get("row") == a.row]
if not rows:
    finish(2, "this claw has no row %s. token add writes it first" % a.row)
row = rows[0]
OUT["path"] = "tunnel" if a.authorize else row.get("path", "")
fields = row.get("seed_fields") or {}
say("")
say("=== seed %s on %s ===" % (a.row, st.get("host", "this claw")))
say("  kind:      %s" % row.get("kind"))
say("  seed path: %s" % OUT["path"])
say("  seed item: %s" % row.get("seed", ""))
say("  for:       %s" % OUT["seeded_for"])
if row.get("state") != "unseeded" and not a.reseed:
    finish(1, "%s is already seeded (%s). A second seed takes --reseed" % (a.row, row.get("state")))

if a.dry_run:
    OUT["ok"] = True
    OUT["action"] = "would-seed"
    say("  would read %s from %s and hand them to the service" % (
        ", ".join(fields.get("required", []) + fields.get("optional", [])), row.get("seed", "")))
    finish(0)

seed = {}
if a.authorize:
    if row.get("kind") != "oauth" or not row.get("metadata"):
        finish(2, "--authorize makes an oauth approval, and %s is not an oauth row with a metadata URL" % a.row)
    helper = os.environ["SEED_DOOR_HELPER"]
    if not os.path.isfile(helper):
        finish(2, "no helper at %s, so the tunnel path cannot run here" % helper)
    say("")
    say("The tunnel path. From your own computer, keep this open while you approve:")
    say("  ssh -L %d:127.0.0.1:%d %s" % (a.port, a.port, st.get("host", "this-claw")))
    rfd, wfd = os.pipe()
    argv = [sys.executable, "-B", helper, "--metadata", row["metadata"], "--no-browser",
            "--port", str(a.port), "--seed-to-fd", str(wfd)]
    for s in row.get("scopes") or []:
        argv += ["--scope", s]
    if row.get("resource"):
        argv += ["--resource", row["resource"]]
    if a.client_id:
        argv += ["--client-id", a.client_id]
    p = subprocess.Popen(argv, pass_fds=(wfd,), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    os.close(wfd)
    with os.fdopen(rfd, "r") as fh:
        raw = fh.read()
    rc = p.wait()
    if rc != 0 or not raw.strip():
        finish(1, "the approval did not complete (the helper exited %d). Nothing was seeded" % rc)
    try:
        seed = json.loads(raw)
    except ValueError:
        finish(1, "the helper handed over something that is not a seed")
    raw = None
    OUT["action"] = "authorized"
    say("  the approval completed on this claw. The vault holds no copy of this seed")
else:
    # THE MACHINE CREDENTIAL, decrypted inside this process and handed to the
    # manager in that one child's environment.
    cred = os.environ["SEED_DOOR_CRED_FILE"]
    if not os.access(cred, os.R_OK):
        finish(2, "no machine credential at %s: this claw cannot read its own vault" % cred)
    try:
        tok = subprocess.run(["systemd-creds", "decrypt", "--name=op-service-account", cred, "-"],
                             capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        tok = ""
    if not tok:
        finish(1, "the machine credential at %s does not decrypt on this box" % cred)
    ref = row.get("seed", "")
    if not ref.startswith("op://") or ref.count("/") != 3:
        finish(2, "the row's seed reference %s is not op://vault/item" % ref)
    env = dict(os.environ)
    env["OP_SERVICE_ACCOUNT_TOKEN"] = tok
    missing = []
    for f in fields.get("required", []) + fields.get("optional", []):
        try:
            r = subprocess.run([os.environ["SEED_DOOR_OP"], "read", "%s/%s" % (ref, f)],
                               capture_output=True, text=True, env=env, timeout=60,
                               stdin=subprocess.DEVNULL)
        except OSError:
            tok = ""
            finish(2, "this claw has no manager command line, so it cannot read its vault")
        v = (r.stdout or "").strip()
        if r.returncode == 0 and v:
            seed[f] = v
        elif f in fields.get("required", []):
            missing.append(f)
        v = None
    tok = ""
    env = None
    if missing:
        seed = {}
        finish(1, "%s has no %s field, or the vault did not answer for it. The person fills "
               "it in their password manager app: token status %s names the fields"
               % (ref, ", ".join(missing), a.row))
    OUT["action"] = "read-vault"
    say("  read %d field(s) from %s" % (len(seed), ref))

try:
    resp = client.call({"verb": "seed", "row": a.row, "seed": seed, "for": OUT["seeded_for"],
                        "reseed": bool(a.reseed)})
except TokensError as exc:
    seed = {}
    finish(1, str(exc))
seed = {}
if not resp.get("ok"):
    finish(1, resp.get("reason", "the service refused the seed"))
OUT["ok"] = True
OUT["result"] = "seeded"
OUT["expires"] = resp.get("expires", "")
OUT["fingerprint"] = resp.get("fingerprint", "")
log = os.environ["SEED_DOOR_ADMIN_LOG"]
if os.path.isfile(log):
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("| %s | %s | seeded the token row %s%s | %s |\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), OUT["seeded_for"], a.row,
            " again" if a.reseed else "", row.get("seed", "") if not a.authorize else "tunnel, no vault copy"))
say("  expires %s, fingerprint %s" % (OUT["expires"] or "-", OUT["fingerprint"] or "-"))
say("seeded")
finish(0)
PY
