# claw-releases

Validated CommonClaw releases. Every claw pulls from here.

## Why this repository has a remote

Local git is the default for this fleet. A repository earns a remote by hitting one of five
triggers, and the trigger must be named in the repository itself, so a later reader knows why
this one has a remote when the others do not.

**The trigger here is the fourth: the fleet itself pulls from it.** Ruled 2026-08-11.

That is the whole purpose of this repository. It is the surface a claw fetches from on a timer.

## What is in a release

A release is the tree a provisioning run consumes, plus the notes a member reads.

| Path | Holds |
|---|---|
| `release/` | the payload: the provisioning plane, the fleet skill trees, the fleet skills manifest |
| `release/notes.md` | member-facing notes for this release, in plain terms |
| `release/release.json` | the version, the class, the declared core floors, the disruption class |
| `channels/` | which release each tier currently takes |

A release is a **tag** on this repository. The tree under `release/` at that tag is the payload.
History is therefore the release history, and two releases can be compared with a diff.

## What is deliberately not here

- **No secret of any kind.** Configuration carries manager references, never values.
- **No name of any firm, ever.** A claw reads this repository. A roster sitting in it would tell
  each firm the names of the others. Channel names are tiers rather than firms.
- **No build repository content.** Ledgers, workpapers and orchestration artifacts stay out.

## Channels

A channel names the release its tier currently takes. Promotion is a commit that moves a channel
pointer forward, which is the judgment at each hop rather than a pipeline.

```
staging  ->  wagmi  ->  tenants
```

Each claw declares its channel. A claw takes a release only when the channel names a version
above what the claw already carries, so a pointer moved backwards rolls nobody back.

**Rollback is a forward publish.** To undo a release, publish a newer one that restores the older
content. That is the consequence of a claw never moving backwards, and it is deliberate.

## How a claw consumes this

1. Read the channel pointer for its tier.
2. Compare the named version against the version it carries. At or above is a skip.
3. Fetch the payload at the named tag, and compute its digest.
4. Refuse when the digest differs from the one the pointer records.
5. Apply through the claw's own provisioning plane, and write its changelog entry.

**What the digest check does and does not do.** It catches a truncated fetch, a corrupted fetch,
the wrong tag, and tampering with the payload alone. It does not prove authorship: whoever can
write here can change the payload and the pointer in one commit. The control for that today is
that write access is held by the people who can already reach every claw by another route.
