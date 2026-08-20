# Managed by provision-claw.sh. Do not edit on the claw.
#
# The claw's shared language runtimes, on every member's PATH.
#
# PREPENDED, not appended. The point of a shared runtime is that a project
# pinning a version gets that version rather than whatever the distro packages,
# and an appended entry would be shadowed by the older copy in /usr/bin. Only
# runtime programs are in this directory, so the shadowing is bounded to the
# names a runtime installs.
#
# ADDED ONCE. A login shell inside a login shell would otherwise stack the entry
# up, and a PATH that grows every time somebody types `bash -l` is a PATH nobody
# can read.
#
# SOURCED BY LOGIN SHELLS ONLY, which is the whole of what this file can do. A
# systemd unit, a cron entry and a non-login `ssh host command` never read it,
# so anything unattended names /opt/commonclaw/runtimes/bin/<program> in full.

if [ -d /opt/commonclaw/runtimes/bin ]; then
  case ":${PATH}:" in
    *:/opt/commonclaw/runtimes/bin:*) : ;;
    *) PATH="/opt/commonclaw/runtimes/bin:${PATH}"; export PATH ;;
  esac
fi
