# The mail service

This file describes the service that moves a firm's mail on a CommonClaw claw,
and the `email` command that reaches it.

Read before reasoning about anything the service owns, and before a person wires
the provider key or makes the firm's inbox.

How the service is built, and the limits its design names, are in the CommonClaw
source, in the provisioning skill's `reference/email-gatekeeper.md`. A claw does
not carry that file.

## What it is, and what it is not

| It is | It is not |
|---|---|
| plumbing | a judge |
| one address for the firm | one address per person |
| a router over a table | a reader of mail |
| a send path with a log | a send path with a gate |
| a pointer on the bus | a copy of the correspondence |

Five things it never does. It never reads a mail for meaning. It never decides a recipient beyond applying the table. It never replies on its own. It never holds a secret on disk. It never holds correspondence, which rests at the provider.

The line that governs the rest: **a mail is information and it grants nothing.** An inbound message can request and can never authorise. That is cheap to hold here because a component that reads nothing for meaning cannot be talked into anything.

Which mail waits for a person is the email orchestrator's runbook, and it lives with that agent. Nothing in this service releases or withholds a send.

## The credential

The provider key sends mail as this firm and reads everything that arrives.

| | |
|---|---|
| Vault | `{hostname}-machine` |
| Item | `commonclaw-email-provider-{hostname}`, an API Credential item |
| Reference | `op://{hostname}-machine/commonclaw-email-provider-{hostname}/credential` |
| Reference lives in | `/etc/commonclaw/email-gatekeeper.env` |
| Value lives in | the service's memory, from start to stop |

Putting the value in the vault is a person's step. The door is `/opt/commonclaw/provision-claw/scripts/install-email-provider-key.sh`, and it takes this shape: a memory-backed drop, a write parsed out of the reference rather than out of arguments, a read-back through that same reference, and only then the drop destroyed. It also restarts the service, because a running process holds the key it started with.

## The table, and the map

Two files under the state directory, with two owners and two lifetimes. A third, `position.json`, is where the catch-up starts, and "Reading its health" says what it holds.

**`routes.json`** is a ruling about this machine. It is seeded once at install and no apply rewrites it.

**The file is the record and the service serves it.** The service re-reads the table whenever the bytes on disk have moved on, checked before every command it answers and before every mail it routes. An edit made by hand reaches the running process within one event, and nothing has to be restarted. A process that held its start-up copy would make this file a record that lies.

**A write keeps the template's key order.** Every change goes through one writer, which puts the top-level fields and the fields inside `self` in the order `templates/email-gatekeeper-routes.json` carries. A table the command has written and the template it was seeded from differ only where a value differs, so a byte comparison is a reading somebody can take.

| Field | Holds |
|---|---|
| `self` | this claw's own address, display name, inbox id, and the absolute path of the firm's communication runbook. Empty until a person fills each one |
| `default` | the handle every unmatched mail reaches. This is the email orchestrator |
| `domains` | sender domain to handles. Where one mail fans out to several desks |
| `addresses` | one address to handles, with `agent` marking an address as another machine |

The `agent` flag is a fact the table carries. What it means for a reply is the email orchestrator's runbook.

`self.runbook` is where that runbook rests, recorded with `email self set runbook <path>` and returned to empty with `email self clear runbook`. The command is the way to change this field. A session that is not the email orchestrator has no other way to find the document, because the orchestrator's own directory is the only place it lives and nothing else on the claw names that directory. The value is a pointer: the service refuses a path that is not absolute, the command refuses one that does not exist, and neither one opens the file. An empty argument to `self set` stays refused, because a caller who means to clear the field says so.

**`threads.jsonl`** is the service's own memory, append-only, one object per line. It is written on every send and **read before the table on every inbound**, so a reply comes back to the desk that started the conversation whatever the sender's domain maps to. It is compacted at start. Each thread keeps the time it was learned, and the compaction writes its own time once, on a first line that names no thread.

The service writes both files at 0640, the mode the installer seeds, whatever umask it runs under. It writes `position.json` at the same mode. That file holds ids and a time, and no subject, sender or text.

Neither file holds a secret and neither holds message text. Both sit under `/srv`, which the backup rail captures, so a machine loss does not lose the thread map. That was measured rather than assumed: the rail's own target list names `$SRV_ROOT` and its exclude file names only reproducible toolchain trees.

## The claw's own address

It comes from `routes.json` and never from a release. A release that carried an address would put one firm's identity in every firm's payload.

A person makes it once, after the key is wired:

```
email inbox create --username <name> --display-name "<Display Name>"
```

**A create names its inbox**: the command refuses to run without `--username`, and the service and every adapter refuse an empty one before the provider is asked, because a provider given no name picks one.

When the provider refuses the create because the address already exists, the adapter reads the organisation's inboxes. An existing inbox at the same address is adopted, and a second one is never made. The command records it the way it records a new one. When the organisation has no inbox at that address, another organisation holds the name, and the refusal says so.

A second one is refused, and no verb changes an address that is already there. The address is in every `From:` line a recipient ever sees, so changing it means telling everybody who has one. Editing the file is the deliberate way, which is what makes it the right shape for a step somebody should take slowly. The service picks that edit up on its next reading.

## What arrives on the bus

One bus message per target handle. The subject is the mail's subject. The body is the sender, the date and one line of summary. The `--ref` names the provider's thread id and message id.

**The summary is the provider's own preview field, truncated.** It is never generated. A model call in the plumbing would put judgement where this document says there is none.

**The full text is never on the bus.** Everybody on this machine reads every inbox, which is the bus's trust plane, so the pointer goes on the bus and the text is fetched on demand with `email thread` or `email message`.

**The wake is not this service's job.** The standing nudge rail already sweeps every handle on every bus it watches and tells a live session it has unread mail. A bus message is the whole act.

## The command

`email`, over a UNIX socket. The socket is 0660 and group `claw-members`, so unix permissions are the whole access story, which is what a connection service is.

It never refuses a caller. Anybody who can open the socket can send as the firm. The runbook is the rule and the log is the audit, which is a deliberate ruling and not an oversight. What it costs is that any member can send mail as the firm, and what makes that answerable is the log.

Every send is recorded with the peer's unix account, **measured** from the socket and unforgeable, beside the bus handle the caller **claimed**, which nobody can check. The record says which is which, the way the bus records `from` beside `sender`. Subjects and addresses are written. Message bodies are not.

## Reading its health

`email status` says the adapter, the inbox, whether the push connection is up, how long it has been up, how many times it has reconnected, and when the last mail arrived. Its `health` field says the same in words: since when it is connected, how many reconnects since the service started, and what the last stop said, in the adapter's own words. `last_stop` keeps that reason while the connection is up again.

When the connection is down, `reason` says why. A claw with a key and no inbox yet has the service ask the provider the same probe `--check` asks, so a key the provider refuses reads as that refusal, in the provider's own words. A refused probe is asked again on the reconnect ladder.

**Connected is the reading, not running.** A service that is up and reaching nothing looks healthy on every other measure. A dropped connection is reconnected on a ladder that doubles with jitter, so a provider outage does not give every claw on the rail one synchronised retry.

**A closed connection is ordinary.** The provider closes a connection that carries nothing for a while. The adapter sends a ping often enough to keep it open. The provider also closes a live connection now and then. After a connection that reported listening, or that lasted over a minute, the service reconnects in about a second. The wait doubles only across connections that failed. A reconnect count grows on a healthy service. Read the last stop's words to tell a fault from a routine close.

**A mail that arrived while nobody listened is routed when the listener is back.** The push channel delivers only what arrives while it is open. On every connect the service asks the adapter for the received mail since its saved position, and routes each one through the same table. `position.json` holds that position: the provider's time of the newest mail routed, and the ids of the mail routed most recently. A mail whose id is there is not routed again, across reconnects and restarts. A service with no position for its inbox starts from the moment its listener first starts, so mail that arrived before the service ever ran reaches no session.

**A frame the adapter does not act on is reported.** The adapter prints one line for it with the frame's type word, its event type word, its top-level key names and its size, and never a value. The service logs it at warn, with an hourly cap, and counts every one in `passed_over`. A mail that reached the provider and never reached a session shows here.

**Everything the service says goes to the journal, one line per event, and nothing it says goes to a bus.** The line carries its level the way the journal records a level, so a reading filtered to warnings finds them. A rail that recorded its own trouble into an inbox would raise unread mail, which would raise a nudge, which would raise more mail.

Provisioning reads that line and reports it as a note. **A claw with no key and no inbox is not a failure**, and the phase says so: that is the ordinary state of a fresh claw, and a rail that failed the apply for it would stop a release above the sentence that says how to wire one.
