# Filling the communication runbook in

The questions a launch asks, one per value the runbook template leaves in angle
brackets, in the order the template names them.

Read this beside `templates/communication-runbook.md`. Every question below
points at a value in that file, gives what the template ships as its default,
and says what a different answer changes.

## How to use it

Ask in small batches and in the firm's own words. Say where your confidence sits
as you go, and stop when the answers stop changing the file.

Every value ships with a default, so a firm that wants to rule none of them
still ends with a finished document. Write the default out as the firm's own
answer. A bracket left standing is an unfinished runbook, and the launch's gate
counts them.

Where a firm cannot rule a value today, mark the sentence `[draft]` and put the
question on the named human's queue.

All eleven values below are questions. A launch asks every one of them.

## 1. Which address does the firm's mail leave from?

Value: `<inbox>`, section 1.

Default: the address the mail provider gives the firm when the service is set
up. On this claw a person makes it with the service's inbox command, and the
routing table then holds it.

An answer here is the firm's public identity. It appears in every message a
recipient ever gets. A second address is refused by the service, so a change
later means telling everybody who has the first one. Ask whether the firm has a
second choice ready, since the first username may be taken.

The routing table is what records the address. The runbook quotes it, so write
the date it was read beside it. A firm with no address yet writes that, and the
line is corrected when somebody makes one.

## 2. What name sits beside that address?

Value: `<display name>`, section 1.

Default: the firm's name followed by "email agent".

An answer here is what a recipient's mail client shows them before they open
anything. A firm that wants recipients to know they are writing to an agent
keeps the word in the name. A firm that does not want that has to say so, and
should know that hiding it is the choice.

## 3. What is the firm called?

Value: `<firm>`, section 1.

Default: the firm's own name, as its clients write it.

The answer goes in the display name and in the first half of every sign-off, so
it is the word a recipient sees twice per message. Take the outward name, never
an internal short form.

## 4. What does the sign-off say after "on behalf of"?

Value: `<sign-off phrase>`, section 1.

Default: a phrase the firm uses for itself when it speaks to somebody outside.

The line is fixed, and every message ends with it whatever desk wrote the draft.
Take a phrase the recipient already understands, and keep the firm's internal
word for a desk out of it.

A firm can have the wording change per desk instead. That is one more thing to
keep correct on every send, and it earns its place once a client can tell the
firm's desks apart. Ask whether one line is enough for now.

## 5. Who releases mail addressed to a person?

Value: `<the named human>`, section 2.

Default: the person who owns the firm's client relationships.

This is the only gate on the firm's outbound mail, so the answer decides how
fast the firm can answer anybody. One person is the shape the runbook is written
for. A firm that names a role instead of a person has to say who is on duty and
what happens when nobody is.

Also ask how that person is reached, because a release nobody sees is a message
that never goes.

## 6. Where does a desk put what it keeps from a mail?

Value: `<filing rule>`, section 3.

Default: the desk files under the project the message is about, and files
nothing outside that project.

An answer that names one place gives the firm one searchable record and one
thing to keep clean. An answer that leaves it to each desk gives every desk its
own habits, which is fine while the desks are few. The runbook can also name no
place at all, which makes filing entirely the receiving desk's call.

Whatever the answer, none of it is a copy of the correspondence. That rests at
the provider.

## 7. When is a sender known?

Value: `<what counts as known>`, section 4.

Default: their address is in the routing table.

Everything an unknown sender writes is held for the named human, and the agent
sends no reply of its own. So a narrow answer means more items on one person's
queue. A wide answer means mail from people nobody has vetted reaches desks
directly.

A firm that wants to widen it has options: a whole domain rather than one
address, or anybody already in the firm's own client records. Both are wider
than the default and both are defensible.

## 8. Is any mail handled out of order?

Value: `<urgency rule>`, section 5.

Default: none. Every message is handled in the order it arrives.

An answer here has to say two things: which senders or subjects it covers, and
what changes for them. "Faster" is not an answer, because nothing in the path
runs on a timer. What can change is the order of the queue and whether an item
raises an alert.

Most firms should take the default at first. An urgency rule is a thing to add
once the ordinary flow is understood.

## 9. Anything else about the words?

Value: `<register additions>`, section 6.

Default: nothing beyond the everyday-words paragraphs the section already
carries.

The section already says that a client reads everyday words, that the firm's
internal vocabulary stays inside, and that a term the reader meets in their own
work gets used and explained at first use.

Additions worth asking about: a language other than the firm's default, a
signature block the firm's lawyers require, a subject-line convention, anything
the firm is required to say by its industry.

## 10. Who approves a change to this document?

Value: `<approver>`, section 7.

Default: the named human from section 2.

The runbook is what stands between a draft and the firm's name on a message, so
whoever approves a change to it holds the firm's outbound mail. Naming somebody
other than the release person splits that. Ask why, and write the reason down.

## 11. Where do the routing table and the thread record rest?

Value: `<service directory>`, section 8.

Default: the directory the mail service is installed into.

Most firms take the default, because the service owns both files and reads them
on every message. The answer matters for one reason: those two files are what a
firm would lose if the machine went. Ask whether that directory is inside what
the firm's backups capture, and write the answer down rather than assuming it.

Neither file holds a secret and neither holds message text.
