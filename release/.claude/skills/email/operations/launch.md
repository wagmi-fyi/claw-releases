# Launch: a firm's email orchestrator

Stand up the session that holds a firm's judgement about mail, with the runbook
it reads and the routing table that reaches it.

## Intent

A firm that has a mail service still has nobody deciding anything. This
operation makes the deciding session, writes down the rules it follows in the
firm's own words, and connects the two so mail actually arrives.

It runs once per firm. After it, the other two operations are the daily work.

## 0. Before you start

Three things have to be true. Check each and stop on the first that is not.

**The service answers.** Run `email status`. It names the adapter and says
whether the connection is up. A command that does not answer means the service
is not installed or not running. Fixing that is a machine job. Stop here and
say so.

**The firm has an inbox.** `email route list` shows the table's `self` block. An
empty block means the firm has no address yet.

Making the address is the named human's step and not yours. It is the address in
every `From:` line a recipient will ever see, a second one is refused, and
changing it later means telling everybody who has the first. Put it on the
human's queue with the command and the two values it needs, and wait:

    email inbox create --username <name> --display-name "<Display Name>"

Making the address changes the runbook. Its first section quotes the routing
table's `self` entry as of a date, so a new address means correcting that line,
under the approval the runbook's change section names.

**The firm has said who releases mail to people.** If it has not, that is
question 5 of the elicitation below, and §3 answers it before §5 can run.

## 1. Launch the project under orchestrate

An email orchestrator is an orchestrator, so it is launched the way every
orchestrator is. Run the orchestrate skill's launch operation for it first. That
gives the session a project directory, a workpaper, and a row in its parent's
index. In the workpaper's skills-in-use block, record this skill as the one guiding
the run, with `operations/route-inbound.md` as the operation it runs between beats.

Launched under this skill alone, the session holds no workpaper, so nothing brings
it back after a gap.

## 2. Write the runbook where it rests, then record where that is

SKILL.md says where a firm's runbook rests: `communication-runbook.md`, in the
email orchestrator's own directory, the one its session runs in. Copy
`templates/communication-runbook.md` there under that name.

Nowhere else. Every operation here looks for the file at that path, so a copy
filed somewhere else reads as a firm that has no email orchestrator yet.

Then put the path in the routing table, which is the reading a session running
anywhere else on the machine takes:

    email self set runbook <absolute path to the copy you just made>

The verb wants an absolute path to a file that is already there, so it runs
after the copy. Read both back before you go on. The file sits at the path
SKILL.md names, and `email self` prints that same path.

The copy is the live document from that moment on, and the template is never
edited for one firm.

## 3. Fill the runbook in

Walk every value written in angle brackets, in the order the template names
them. `reference/runbook-elicitation.md` holds the question for each one, what
it ships as a default, and what a different answer changes.

Interview the way the skill-building runbook's elicit operation does it. Small
batches. The firm's own words. Say where your confidence sits as you go. Stop
when the answers stop changing the file.

Every value ships with a default, so a firm that wants to think about none of
them still ends with a finished document. Write the default out as the firm's
answer rather than leaving the bracket standing.

Where a firm cannot rule a value today, mark the sentence it belongs to
`[draft]` and put the question on the named human's queue. A `[draft]` is an
open question, and the gate counts them.

## 4. Register the handle

The email orchestrator registers a bus handle from inside its own session.
Registering from anywhere else records the wrong session, and every wake aimed
at the handle lands somewhere nobody is reading.

The name is not free. The routing table's `default` field holds the handle every
unmatched mail goes to. Read it with `email route list` and register that exact
name. A handle that differs by one character gets no mail, and nothing anywhere
reports a fault.

When this session is gone, the claw's mail alarm tells the firm's named person
that its mail is waiting unread.

## 5. The first routing-table entries

An entry that carries the agent mark is what lets a message leave the firm with
no person in the path. So an edit to the table is a change to the runbook, and
it takes the approval the runbook's own section on changes names.

Start with an empty table where nothing is ruled. Empty is safe: everything
reaches the email orchestrator and the runbook decides.

Add what the named human has approved, and nothing else:

    email route add <domain or address> <handle> [--agent]

The `--agent` mark says the address is another machine. Leave it off and the
address is a person, whose mail waits for a release.

## 6. Say what the firm now has

Tell the firm three things in plain words: the address mail comes from, what
goes out on its own, and what waits for a person. They are the three sentences
somebody will ask about first, and they are all in the runbook already.

## Gate

- The project has a workpaper from orchestrate's launch, and its skills-in-use
  block names this skill.
- `email status` answers, and names an adapter and an inbox.
- The runbook sits at the path SKILL.md names, and holds no angle bracket.
- `email self` prints `runbook`, and it is the file this launch wrote.
- Every `[draft]` left in the runbook is one item on the named human's queue,
  or there are none.
- `bus handles` shows the handle, and it is character for character the table's
  `default`.
- The table holds the entries the named human approved and no others, read back
  with `email route list`.

Report the runbook's path as the file system holds it and as `email self`
records it, the handle, the table's entries, and every `[draft]` that is still
open.
