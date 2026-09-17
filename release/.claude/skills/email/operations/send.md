# Send: getting something out of the firm as mail

Two jobs in one file. A desk writes a draft and hands it over. The email
orchestrator applies the runbook and sends.

## Intent

Every message that leaves the firm has passed one session that knows the firm's
rules about mail. That is the whole design. A desk writes what it wants to say
and knows nothing else.

The email orchestrator reads the firm's runbook first, at the path SKILL.md
names. Everything in Part B defers to it.

## Part A: you are the desk that wants to send

### A1. Write the draft

The runbook's register section binds the words. Everyday language. The firm's
internal vocabulary, its short names for teams and its numbering stay inside the
firm. A word the reader meets in their own work gets used and explained the
first time it appears.

Write the body and nothing else. No headers, no greeting rules, no address
formatting. One message, in words.

### A2. Leave the sign-off alone

You do not write the last line. The firm has one sign-off, the runbook holds it,
and the email orchestrator puts it on.

Your desk's name still goes in the handoff, for the firm's own record of who
sent what. Use the words the recipient already uses for you. A client who calls
you the bookkeeping team gets "the bookkeeping team", whatever the firm calls
you internally.

### A3. Hand it over

`templates/handoff-to-email-orchestrator.md` is the shape. One bus message to
the email orchestrator, carrying the recipient, the subject, the body, your desk
name, your handle, and the thread ref when this is a reply.

### A4. Wait

One bus message comes back. It says the mail went, with the ids, or it says the
message is waiting for a person to release it.

Do not send the draft twice. Do not run the `email` command yourself.

That second sentence is a rule and not a wall. The service refuses nobody: any
account that can open its socket can send as the firm, and the log is what makes
that answerable. Going around the email orchestrator produces a message the
firm's rules never touched, signed with the firm's name.

## Part B: you are the email orchestrator

### B1. Read the handoff against the runbook

Check the draft's register. Check who the recipient is. Check that the runbook
covers the case at all.

A case the runbook does not cover is a question for the person who approves
runbook changes, and the message waits until they answer. Do not decide the case
and carry on. Proposing the sentence the runbook is missing is part of the ask.

### B2. Work out what the recipient is

Read the table with `email route list`.

An address carrying the agent mark is another machine. That message goes out with
no person in the path.

Every other address is a person. That message waits for a release.

An address the table does not name at all is a person, by the same rule. Absence
is not permission.

### B3. The release, when one is needed

Put one item on the named human's queue: the recipient, the subject, the body
exactly as it will go, the desk it is from, and the thread when there is one.
Record the same ask on the `human` bus handle in the same beat.

They answer with a yes or with an edit. Nothing leaves until they do. A message
that has waited a long time is still waiting.

### B4. Put the sign-off on

The last line of every body is the sign-off as the runbook's first section
writes it. Copy that line. One line serves the whole firm, so there is nothing
to compose and nothing that changes with the desk.

### B5. Send

    email send --to <address> --subject "<subject>" --body "<body>" \
      --handle <the desk's handle> \
      [--in-reply-to <message id>] [--thread <thread id>]

The two optional flags put the message inside an existing conversation. Use them
whenever the handoff carried a thread ref.

**The handle you pass is the desk's.** The service writes it into
its thread memory, so every later message in that conversation goes straight to
the desk and never comes back through you. The send log records the unix account
that actually ran the command, measured from the socket and unforgeable, beside
the handle that was typed. So the record still says who sent it, and the routing
still says whose conversation it is.

### B6. Record what happened

One bus message back to the desk: the message id, the thread id, and whether a
person released it. Put it on the same thread ref when there is one.

That message is the firm's own record of how a mail got out. The service's log
records the send. This records the judgement.

## Gate

- Every message that left went to an address the table marks as an agent, or a
  named human released it first.
- The last line of every body is the runbook's sign-off, word for word.
- The `--handle` on every send is the desk's handle.
- Every handoff got exactly one bus message back, saying sent or saying waiting.
- No credential in a body, and no credential in a bus message. Every account on
  this machine reads every inbox.
