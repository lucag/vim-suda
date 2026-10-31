#!/bin/sh
# Append one line to the "## Decisions so far" section of a wayfinder map
# issue, after the section's last non-blank line. Leaves the rest of the body
# untouched; refuses if the heading is missing or appears more than once.
# Usage: scripts/map-append.sh <map-issue-number> '<line>'
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <map-issue-number> '<line>'" >&2; exit 2; }
map=$1 line=$2
case $map in *[!0-9]* | '') echo "$0: not an issue number: $map" >&2; exit 2 ;; esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gh issue view "$map" --json body --jq .body >"$tmp/old"

count=$(grep -c '^## Decisions so far[[:space:]]*$' "$tmp/old" || true)
[ "$count" = 1 ] || { echo "$0: #$map has $count '## Decisions so far' headings, expected 1" >&2; exit 1; }

LINE=$line awk '
  { body[NR] = $0 }
  /^## / { if (in_section) { in_section = 0; done = 1 } }
  /^## Decisions so far[[:space:]]*$/ { in_section = 1; last = NR; next }
  in_section && $0 !~ /^[[:space:]]*$/ { last = NR }
  END {
    for (i = 1; i <= NR; i++) {
      print body[i]
      if (i == last) print ENVIRON["LINE"]
    }
  }
' "$tmp/old" >"$tmp/new"

# Exactly one line added, nothing else changed.
[ "$(diff "$tmp/old" "$tmp/new" | grep -c '^[<>]')" = 1 ] || { echo "$0: refusing: edit would change more than one line" >&2; exit 1; }

gh issue edit "$map" --body-file "$tmp/new" >/dev/null
echo "appended to #$map Decisions so far"
