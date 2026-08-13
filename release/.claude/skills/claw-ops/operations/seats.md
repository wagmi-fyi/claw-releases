# Seats

**Required role: `member` to read the roster, `claw-admin` to retire a seat.** Reading it changes nothing and every member can; retiring one is a decision about what this claw expects, so it sits with the people responsible for that.

A seat is one person's login to one core. The roster is the claw's record of which seats it **expects** — not which ones exist, and not which ones are healthy.

## Why the claw declares its seats

Both cores are installed for everybody, so a claw that reads expectation off what is installed cannot tell a seat somebody deliberately does not use from one that has lapsed. It warns about the first every morning forever, and a warning that fires on a healthy claw every day is a warning nobody reads by the time it matters.

The roster answers the question directly. A declared seat that is missing or close to expiry is a finding. A core nobody has seated and nobody declared is quiet, and staying quiet is the point.

## How a seat gets on the roster, and how it comes off

**On, by itself.** The claw's own seat check adds a row the first time it sees a live login. The person logging in is the bookkeeping, so nothing waits on somebody remembering to declare a seat.

**Off, by decision.** Nothing is removed automatically. A seat somebody retired and a seat that was destroyed look identical from the machine, so removing on absence would recreate exactly the blindness the check exists to prevent. Retiring is the operation below, it records who decided and why, and the row stays in the file with its reason.

**Retire a seat that has gone, not one that is running.** A live login is observed again on the next check and re-opens its own row. That is deliberate: a seat somebody is still using is a seat this claw expects, and leaving it undeclared is the failure that costs the most.

## Reading the roster

Run `scripts/seats.sh --help`, then run it. It writes JSON on stdout and changes nothing.

It reports what the claw declares, and the seat check's own recent verdicts where the caller can read the journal. It does **not** take a fresh reading of anybody's seat: another person's seat state lives in their home, and the caller's own is in `operations/claw-status.md`.

Two answers that look alike and are not: a claw with **no roster** is inferring expectation the old way, which is legitimate and is reported as such. A roster the check **refuses to read** is a damaged file, and until it is repaired the check is refusing to check anything.

## Retiring a seat

Run `scripts/seats-retire.sh --help`, then run it. It names the person, the core, and a reason. The reason is not decoration: it is what a reader six months later has instead of asking.

The claw's own root-owned script does the work behind the sudo door, the same way a workspace is scaffolded. There is no second implementation here, and a re-run converges rather than adding a second row.

**Never edit the roster file by hand.** Its grammar has one reader on this claw. A line written past that grammar makes the seat check refuse to check anything at all, which is loud, and is meant to be.

## When the door is closed

Two answers, and the script distinguishes them:

- The caller is not in `claw-admin`. The claw's own admin runs this, or grants the role first.
- The grant is absent. The claw was provisioned before the grant covered this operation. It is repaired from the provisioning plane, not from here.

Neither is worked around. Report which one it is.
