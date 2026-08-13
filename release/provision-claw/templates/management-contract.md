> **For the operator.** This block does not travel. Everything below the rule is the
> claw's copy: render the placeholders, write it to `/etc/commonclaw/management-contract.md`,
> and leave it world-readable — a firm's own agents are the readers it exists for. One
> copy per claw the vendor operates on somebody else's behalf. A claw the firm hosts
> itself has no retained access to describe and needs no copy.
>
> Placeholders: `{{VENDOR}}` the company operating the claw · `{{FIRM}}` the company whose
> work is on it · `{{HOSTNAME}}` the claw · `{{CONTACT}}` how the firm reaches the vendor ·
> `{{DATE}}` the day this copy was written.
>
> Filled, the opening reads like this — an illustration, not a real firm:
>
> > # How Acme Systems works on northgate-claw
> >
> > Acme Systems built this machine and keeps it running for Northgate Dental. That means
> > Acme holds root on it. This file says what that access is for, what it never touches,
> > and what happens when an exception comes up. It is here rather than in an email
> > because the people it concerns are you and your own agents, and this is where you both
> > read.
>
> The Entries table at the bottom starts empty and is appended to, never rewritten.

---

# How {{VENDOR}} works on {{HOSTNAME}}

{{VENDOR}} built this machine and keeps it running for {{FIRM}}. That means {{VENDOR}}
holds root on it. This file says what that access is for, what it never touches, and what
happens when an exception comes up. It is here rather than in an email because the people
it concerns are you and your own agents, and this is where you both read.

## What the access is for

Five things, and nothing else.

| | |
|---|---|
| The base system | packages, the firewall, the intrusion blocker, unattended security updates, the machine staying reachable |
| The backup rail | the schedule, the retention policy, and proving a restore still works |
| The seat check | the job that warns before a login lapses |
| The skill plane | the shared skills every session on this claw can reach |
| Updates | riding a new revision of the provisioning skill onto the machine |

Every one of those is machinery. None of them is your work.

## What it never touches

- **Your workspaces.** Everything under `/srv/workspaces` is {{FIRM}}'s. {{VENDOR}} does
  not read it, edit it, move it, or copy it off the machine.
- **Your home directories.** That includes session transcripts, which are a record of what
  your people and their agents decided.
- **Your credentials.** {{VENDOR}} holds no seat in {{FIRM}}'s password manager. What sits
  on this claw is a set of references into your manager; the values resolve at the moment
  they are used and rest nowhere.

## When an exception comes up

Sometimes the machinery and your work meet: a backup that will not read a directory, a
permission that is wrong, a file a person cannot open.

{{VENDOR}} enters a workspace or a home **only when {{FIRM}} asks**, for the thing
{{FIRM}} asked about, and **writes the entry into the table at the bottom of this file**.
No standing permission, no quiet look, no exception that only one side remembers.

If you find an entry there you did not ask for, that is a broken agreement and worth
raising as one.

## What this file is, and what it is not

It is a promise plus a record. It is not a wall.

Root can read anything on a machine. Nobody can hand you a technical guarantee that a
party holding root did not look, and a document claiming otherwise would be worth less
than this one. What you get instead is a narrow, stated purpose, a list of what is out of
bounds, and an entry table where every exception has to be written down and stays written
down.

## The way out is always open

{{FIRM}} can take this machine over completely: mint your own keys, prove them, remove
{{VENDOR}}'s access from the machine and from the hosting account, and run it yourselves.
The provisioning skill is published, the machine converges when you re-run it with your
own parameters, and nothing about the claw depends on {{VENDOR}} continuing to exist.

That is the standing backstop under everything above. It needs no negotiation, and taking
it does not break the machine.

Reach {{VENDOR}} at {{CONTACT}}.

## Entries

Every time {{VENDOR}} entered a workspace or a home. Appended, never rewritten.

| Date | Who asked | What was entered | Why | What was done |
|---|---|---|---|---|

*This copy written {{DATE}}.*
