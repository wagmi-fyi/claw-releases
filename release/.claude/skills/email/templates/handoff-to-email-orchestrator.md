# Handoff to the email orchestrator

The bus message a desk sends to ask for a mail to go out.

A draft is too big for a bus body, so it goes in a file and the message points
at it. That is the bus's own convention for anything long.

## The draft file

Seven header lines, a blank line, then the body.

    to: [recipient address]
    cc: [a second address; leave the line out when there is none]
    subject: [the subject the recipient sees]
    desk: [your desk's name, in the words the recipient already uses]
    handle: [your bus handle]
    thread: [thread id; leave the line out unless this is a reply]
    in-reply-to: [message id; leave the line out unless this is a reply]

    [the message, in words]

## The message

    bus send [your handle] [the email orchestrator's handle] \
      "send: [the subject]" \
      "a draft for the [desk] desk" \
      --ref [path to the draft file]

Put the draft file where the bus keeps the payloads its pointers name, so both
sessions read it from the same place.

## The seven lines

| Line | Holds | Leave it out when |
|---|---|---|
| `to` | the one address the message is for | never |
| `cc` | a second address that gets a copy | there is none |
| `subject` | what the recipient sees before opening it | never |
| `desk` | your desk, named the way the recipient names it | never |
| `handle` | your bus handle | never |
| `thread` | the conversation this belongs to | this opens a conversation |
| `in-reply-to` | the message this answers | this answers nothing |

`handle` is load bearing twice. The answer comes back to it, and the mail
service writes it into its own memory, so every later message in the
conversation reaches your desk directly instead of going round through the
email orchestrator.

`thread` and `in-reply-to` both come out of the ref on the bus message that
brought the mail in. That ref names a thread and a message, in that order.

## What does not go in it

**No sign-off.** The firm has one sign-off, the runbook holds it, and the email
orchestrator puts it on the end of the body.

**No credential, ever.** Every account on this machine reads every inbox, and
the file a pointer names is readable the same way.

**No instructions about how to write it.** The firm's runbook already says. If
the draft needs a rule the runbook does not have, say that in the bus body and
let the message wait.

## What comes back

One bus message to your handle. It says the mail went, with the message id and
the thread id, or it says the message is waiting for a person to release it.

Wait for it. Do not send the draft a second time, and do not run the mail
command yourself.
