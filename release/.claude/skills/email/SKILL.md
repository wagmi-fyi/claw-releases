---
name: email
description: "Run a firm's email as an agent. Receive the mail the routing table sends nowhere else, apply the firm's communication runbook to everything that goes out, keep the routing table, and hold the judgement about mail so no other session has to. Use when launching a firm's email orchestrator, when a bus message from the mail service arrives, when an agent wants to send mail as the firm, or when the routing table or the communication runbook changes."
---

# Email

The agent that holds a firm's judgement about mail.

A mail service moves the messages. This skill is the session behind it.

## What an email orchestrator is

One agent session per machine, and one per firm. Its job is the firm's mail. It
does four things.

- It receives every mail the routing table sends nowhere else.
- It applies the firm's communication runbook to every message that goes out.
- It keeps the routing table.
- It holds the judgement about mail, so no other session has to hold any.

Every other session on the machine writes a draft and hands it over. The desk
that wrote the draft never has to know what the firm's rules about mail are.

## What it is not

It never holds a key. The provider key belongs to the service and lives in the
service's memory.

It never reads mail the service did not route to it. There is no inbox it can
open and browse.

It never sends without the runbook. A message that the runbook does not cover
is a question for the person who approves runbook changes, and the message
waits.

## The words

A **desk** is a team or a role inside the firm that mail can be about. The
people who do the bookkeeping are a desk. A desk is a bus handle.

The **routing table** is the file the mail service reads to decide which desk a
message goes to. It maps a sender domain or one address to one or more handles,
and it names the handle that gets everything else. That last handle is the
email orchestrator.

A **thread** is one conversation at the provider. It carries an id. The service
remembers which desk started each thread and sends every later message in it
back to that desk.

A **release** is the moment the firm's named human lets an outbound message to
a person go. Mail to another agent needs no release. Mail to a person does not
leave until the release happens.

## The service

`reference/mail-service.md` documents the service. Read it before working on
anything the service owns: the shape of a bus message it puts out, the routing
table's fields, the send log, and the five things the service never does.

A machine that moves mail some other way documents its own service in the same
way, and the operations here read against that document.

The command is `email`. Run `email --help` for its verbs and `email status` to
see whether the service is connected.

## The firm's runbook

A firm's own rules about mail are in `communication-runbook.md`. Read it before
you act. Nothing in this skill overrides it.

Look in your own session's directory first, under that name. A session running
somewhere else on the machine reads the routing table: `email self` prints
`self.runbook`, the absolute path the launch recorded when it wrote the
document.

When neither reading finds a file, the firm has no email orchestrator yet. Run
`operations/launch.md`, which writes the runbook and records its path, and do
nothing else here until it exists.

## Activation

When invoked, work out which operation you are in.

1. **Launch.** A firm has no email orchestrator yet. Run `operations/launch.md`.
2. **A bus message from the service arrived.** Run `operations/route-inbound.md`.
3. **Something has to go out.** Run `operations/send.md`. Any session reads it,
   not only the email orchestrator.

## Operations

| Operation | File | Use when |
|---|---|---|
| Launch | `operations/launch.md` | A firm is standing up its email orchestrator for the first time |
| Route inbound | `operations/route-inbound.md` | A bus message from the mail service has arrived in your inbox |
| Send | `operations/send.md` | Anything has to leave the firm as mail |

## Reference

| Reference | File | Precondition |
|---|---|---|
| Mail service | `reference/mail-service.md` | Before reasoning about anything the service owns, and before a person wires the provider key or makes the firm's inbox |
| Runbook elicitation | `reference/runbook-elicitation.md` | During a launch, when filling the runbook template in with a firm's own answers |

## Templates

| Template | File | Instantiated by |
|---|---|---|
| Communication runbook | `templates/communication-runbook.md` | `operations/launch.md`, once per firm |
| Handoff to the email orchestrator | `templates/handoff-to-email-orchestrator.md` | `operations/send.md`, once per message |
