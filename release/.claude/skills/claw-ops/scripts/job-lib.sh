#!/bin/bash
#
# job-lib.sh: the one reading of a scheduled job's timestamps.
#
# SOURCED, never executed. Two scripts read it:
#
#   schedule-job.sh  prints the next run after it enables a timer
#   list-jobs.sh     prints the next run and the last one for every job
#
# It is one file for the reason unit-groups.sh is one file. systemd prints a
# timer's timestamps as a formatted string on this release and as microseconds
# since the epoch on older ones, so the reading has two branches. A second copy
# would drift, and the answer it would drift on is when a job next runs.

# job_timestamp_utc <value>
#   Prints the value as UTC in the claw's stamp form, or nothing.
#   A timer that has never fired, and one with no calendar schedule, both
#   answer with a word rather than a time, and both print nothing here.
job_timestamp_utc() {
  local v="${1:-}"
  case "$v" in
    ''|0|'n/a'|'infinity'|'-') printf '' ; return 0 ;;
  esac
  case "$v" in
    *[!0-9]*) date -u -d "$v" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '' ;;
    *)        date -u -d "@$(( v / 1000000 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '' ;;
  esac
}
