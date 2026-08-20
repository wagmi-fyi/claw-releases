# Who decides what runs on this claw

This claw runs code as root only when somebody who holds authority here has
signed for it. This file says who those people are, how they approve something,
and what an approval binds.

It is installed at `/etc/commonclaw/claw-authority.md` and everybody on the claw
can read it.

## Three tiers

| Tier | How many | What it holds |
|---|---|---|
| Owner | exactly one | everything an admin holds, and the roster |
| Admin | any number | approves a door, opens the claw's own operations |
| Staff | everybody | their own work, their own agents, no privilege |

Staff is the `claw-members` group. Being in it means you have a login here. It
grants nothing, and that has not changed.

To see who holds what on this claw:

```
claw-authority --list
```

Anybody can run that. It reads and records nothing.

## The owner

One person. The owner is never deleted, only transferred, and a transfer takes
the current owner's own signature. Nobody else can move it, including an admin
and including the vendor through any ordinary path.

The owner appoints and removes admins. That power does not delegate: an admin
cannot appoint an admin. A tier that could widen itself would be one tier
wearing two names, because the first admin appointed would choose the second and
the owner would not hear about it.

## Admins

The owner appoints them by signing for it. An admin approves a door, and runs
the claw's own operations: onboarding somebody, granting workspace access,
managing another person's keys, taking a workspace down.

An admin approving a door is one signature. Any one owner or admin is enough.

### The admins your claw already had

A claw that was running before it took this registry already has people in
`claw-admin`. The first run that lays the registry writes those people into it,
with the keys that already open their logins. Nothing is granted by that: they
held the group's doors the day before. What changes is that the registry now
names them, so the owner can take any of them out with one signed
`remove-admin`.

It happens once, on the run that lays the registry, and never again. After that
the registry decides who is in the group, not the reverse.

A person the run cannot write down is named in its output. That happens when
they have no login key of a type this claw accepts. They keep the group's doors
and no signature can remove them until the owner signs an `add-admin` for them,
so give them a key and do that.

## A door

A door is a script your firm wrote that runs as root, and that a group on this
claw may run through `sudo` without a password.

Your firm writes it. Somebody with authority approves it. Then it is installed
and granted, and every run of it is recorded.

### Drafting one

Write the script in a workspace. Then:

```
claw-authority --request grant-door \
    --name backup-now \
    --script /srv/workspaces/finance/tools/backup-now.sh \
    --group claw-members
```

That prints a short document naming the operation, this claw, the script's exact
content hash, and a deadline. It changes nothing. **An agent can do this much and
no more**, which is the point: composing a request reaches no privilege at all.

`--group` says who will be able to run the door. `claw-members` is everybody;
`claw-admin` is the owner and the admins. There is no default, because the widest
answer must never be the quiet one.

### Approving one

Send the document to the owner or to an admin. On **their own machine**, with the
private half of the key this claw holds for them:

```
ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n claw-authority@commonclaw request.txt
```

That writes `request.txt.sig` beside it. Nothing secret leaves their machine. A
signature is public, and the private key never moves.

**Read the script before signing.** The signature says you looked at those exact
bytes and want them running as root here. Nothing on the claw has an opinion
about whether the script is safe, and nothing can.

### Installing one

Both files come back, and a claw-admin applies them:

```
sudo /opt/commonclaw/provision-claw/scripts/manage-claw-authority.sh \
    --apply grant-door request.txt request.txt.sig \
    --script /srv/workspaces/finance/tools/backup-now.sh
```

Add `--dry-run` to check a signature and see the plan without acting. A dry run
does not consume the request.

The claw re-reads the script, hashes it, and refuses unless it matches what was
signed. Then it installs it and grants it.

### Running one

```
sudo /opt/commonclaw/tenant-doors/backup-now
```

Every run re-checks the approved hash and appends a row to
`/etc/commonclaw/admin-log.md`. If the installed bytes ever stop matching the
approval, the door stops instead of running.

### Taking one away

Same shape, and it takes a signature too:

```
claw-authority --request revoke-door --name backup-now
```

Revoking is not the cheaper act. If it were, every door on this claw would rest
on whoever could run a script rather than on whoever approved it.

## Changing the roster

All three take the owner's own signature.

```
claw-authority --request add-admin      --person bob   --key-file bob.pub
claw-authority --request remove-admin   --person bob
claw-authority --request transfer-owner --person carol --key-file carol.pub
```

`--key-file` takes the public half, the file ending in `.pub`. Never a private
key: the registry is world-readable.

A transfer hands over everything. The outgoing owner is left holding nothing. If
the firm wants them kept as an admin, the new owner signs an `add-admin`, which
is one act and is visible in the log.

## Two records, and they are not the same one

**Revoking somebody's login key does not revoke their authority here.** The keys
that open a login and the keys that approve an act are kept separately on
purpose.

An admin who loses a device needs both:

```
sudo .../manage-person-keys.sh --revoke-key bob SHA256:...   # the login
claw-authority --request remove-admin --person bob           # the authority
```

Removing an admin also does not end a session they already have. It shuts the
door and leaves whoever is inside where they are.

## What a request cannot be reused for

A signed request works once, on this claw, until its deadline. The claw records
every request it has applied and refuses a repeat, so a document somebody kept
cannot be replayed later to undo a decision made since.

If a request expires, draft it again and have it signed again.

## If the owner is gone

Nothing on this claw can appoint a new owner. That is deliberate: a recovery path
sitting on the box would be a second way into the registry, reachable by whatever
could reach the first one.

Recovery is a break-glass act. The firm asks WAGMI in writing, and WAGMI performs
it as the operator of the machine. Contact us; it is not something to work around
locally.
