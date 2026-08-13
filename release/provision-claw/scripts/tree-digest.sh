#!/bin/bash
#
# tree-digest.sh — the one content digest for a directory tree.
#
# SOURCED, never executed. Two callers digest a tree and they both read this
# file: provision-claw.sh answers whether a skill is already installed, and
# commonclaw-update.sh answers whether a fetched release is the one the channel
# pointer named. A second copy would drift, and the verdict it would drift on is
# whether a claw accepts a payload that is not what it asked for.

# ---------------------------------------------------------------- digests

# A content digest over a whole tree: every path, every file's content, and
# every symlink's target. Two trees with the same digest hold the same bytes in
# the same places, which is what makes "already installed" answerable without
# comparing timestamps. Timestamps change on every copy and would report drift
# on a claw that has none.
tree_digest() {
  local d="$1" p
  ( cd -- "$d" 2>/dev/null || exit 1
    find . \( -type f -o -type l \) -print0 2>/dev/null | LC_ALL=C sort -z |
    while IFS= read -r -d '' p; do
      if [ -L "$p" ]; then printf '%s L %s\n' "$p" "$(readlink -- "$p")"
      else printf '%s F %s\n' "$p" "$(sha256sum -- "$p" | awk '{print $1}')"
      fi
    done
  ) | sha256sum | awk '{print $1}'
}
