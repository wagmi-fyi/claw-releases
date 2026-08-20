# The claw's shared language runtimes

A language runtime on this claw is installed once, at machine level, and every
member reaches the same copy. Node, Python, whatever a project needs. You do not
install one into your home, and you do not install one into a workspace.

The copies live under `/opt/commonclaw/runtimes`, one directory per major
version, root-owned. `/opt/commonclaw/runtimes/bin` is on your PATH, so typing
`node` runs the machine's copy.

## Declare what your workspace needs

Add the runtime to your workspace's manifest, `.workspace.yaml`:

```yaml
runtimes: [node-22]
```

The name is `<runtime>-<major>`. The next provisioning ride reads every
workspace's manifest and converges this claw to the union of them.

**A declaration is not an install.** A ride can only converge a runtime this claw
has already been given once, because what it installs from is the record of that
first install. Declaring something new tells nobody where to get it. The first
one of a kind needs a claw-admin to supply a source, once:

```
sudo /opt/commonclaw/provision-claw/scripts/manage-runtimes.sh \
  --install node-22 --url <link> --sha256 <hash>
```

`--list` shows what is installed, what each workspace declares, and which
declarations no ride can satisfy yet. It changes nothing.

## The URL and the hash go together, always

The door refuses an install that does not carry both. It downloads the bytes,
hashes them, and compares them to the hash you gave it before anything lands on
the machine. A mismatch is a refusal and the bytes are deleted.

**The door checks the bytes; you vouch for them.** It has no way to know that a
hash is the vendor's, so take the hash from the vendor's own published checksums,
not from beside the download. Both values go into `/etc/commonclaw/admin-log.md`
with your name against them, and they stay there. That row is what says who
decided this machine runs these bytes.

It is also how the claw rebuilds itself. The runtime trees are not backed up:
they are vendor bytes with no recovery value. The row is, so a restored claw
carries the pins and a ride puts the binaries back.

## Your dependencies are yours

**The runtime is shared. Nothing else is.** `node_modules`, a virtual
environment, a lock file, a `.tooling` directory: all of it stays inside the
project that owns it. Those change on your project's clock and they are nobody
else's business. The runtime changes on the machine's.

This is also why they are not in the backups. A dependency tree reproduces from
a lock file, so the rail excludes the whole class rather than paying to store a
copy of the internet.

## When a major is not enough

The shared copy answers "which line does this machine run". A lock file answers
"which build does this project run". Where a project needs a version tighter
than the major, pin it project-side with your own tooling and use that. That is
a deliberate exception and not a gap.

Both majors can be installed at once. Every program also gets a versioned name,
so `node-22` and `node-24` are both on PATH and both mean exactly one thing. The
bare `node` is the newest major installed. **Installing a newer major therefore
moves what `node` means for everybody on this claw**, which is a good reason to
say so on the bus before you do it.

## What a shell already open does not get

PATH comes from a `/etc/profile.d` drop-in, and a shell reads that when it
starts. A runtime installed while you are logged in reaches you at your next
login.

Anything unattended — a systemd unit, a cron entry, a non-login
`ssh host command` — never reads that file at all. Name the full path there:
`/opt/commonclaw/runtimes/bin/<program>`.

## When you need one that is not here

Ask a claw-admin. Nothing here needs an install into a home directory, and a
runtime that lands in one is a copy per person that nobody else can use.
