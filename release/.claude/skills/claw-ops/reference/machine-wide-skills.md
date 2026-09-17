# Machine-wide Skills

This file says what a release run does to a skill somebody installed for everybody, and how to keep that install in place.

The install itself is generic. The published skills repository describes it under "Installing for everyone on a machine": https://github.com/wagmi-fyi/skills#installing-for-everyone-on-a-machine. It is root work. This skill has no door for it, so a person with root on the claw runs it.

## The tier a release manages

A provisioning run given a skills manifest puts one copy of each named skill under the claw's canonical root and links it into the machine-wide skills directory of both cores. A run given no manifest leaves the tier as it is.

At the end of the run it writes `/etc/commonclaw/skills.yaml`. That file names the canonical root, the two machine-wide directories, and under `skills:` each skill the run installed. It is the ledger: the record of what a release put on this claw. A claw with no such file takes the manifest being applied as its ledger.

## How a run treats each name

| The name is | What the run does |
|---|---|
| in the manifest | installs the skill and links it, replacing a link already at that name |
| in the manifest, absent from the ledger, and already present on the claw | leaves the claw's entry in place and installs nothing under that name. It says so on every run |
| in the ledger and absent from the manifest | treats it as retired. It removes the canonical copy, and each link that points into the canonical root |
| in the ledger, absent from the manifest, and linked somewhere outside the canonical root | removes the canonical copy and leaves that link in place, with a note |
| in neither | leaves the entry exactly as it is, copy or link, with a note |

The phase is `phase_14_skill_plane` in the provisioner.

## Keeping a plugin install in place

Keep the skill's name out of the ledger. A link made by hand never enters it, because the run writes the ledger from the manifest alone.

When the ledger already names the skill, a release installed it earlier. Run provisioning once with the release's own manifest, which names only the release skills. That run removes the release's copy and its links, and writes a ledger without the name. Make the plugin links after that run.

Read the run's tier line afterwards. Each plugin link shows up as left alone, and the removed count covers only what the release had installed.
