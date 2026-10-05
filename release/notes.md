- **A held orchestrator now reaches a person.** When the continuity rail cannot
  resume one orchestrator, for example because its folder is not trusted, the
  claw's alert channel gets one line about it. The line names the orchestrator,
  the reason and the step that fixes it. A retry that fails again sends nothing
  new. A hold that clears and comes back later sends again.
- **A hold can also go to one address by mail.** Set `HOLD_ALERT_TO` in
  `/etc/commonclaw/email-gatekeeper.conf` to one address, and each hold sends one
  mail there through the claw's mail service. It ships empty, and empty means
  the channel only. It is apart from `MAIL_ALERT_TO`, so a hold need not reach
  everybody the mail alarm reaches.

## Changes with no visible effect

A new root timer, `commonclaw-hold-check.timer`, runs every ten minutes. It
reads each account's holds and sends nothing when there is none. A signed-out
account sends nothing new from it, because the hourly sign-in alarm already
covers that case. The alert channel has a new message class, `continuity-hold`.
A provisioning run appends `HOLD_ALERT_TO`, empty, to a mail service conf that
lacks it, and keeps the value where a claw sets one. The rail's hold now
records an id, a reason class and the orchestrator's folder, and a hold an
earlier release wrote is still read.

## What somebody has to do

Nothing, on most claws. A claw that wants holds by mail sets `HOLD_ALERT_TO` by
hand. The channel line needs the alert channel to be wired, as every other
alarm does.
