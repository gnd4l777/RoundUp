#!/bin/bash
# Extracts inline JavaScript from index.html and checks it for syntax errors.
# This mirrors the manual check already used when building this app: it
# catches typos and broken syntax, NOT logic bugs. A file that passes this
# can still behave wrong — always look at what actually changed too.
#
# Requires Node.js to be installed (just for `node --check` — nothing else
# in this project needs it, since the app has no build step).

set -euo pipefail

FILE="index.html"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT

if ! command -v node &> /dev/null; then
  echo "Node.js isn't installed. Install it from https://nodejs.org (just the syntax checker needs it — the app itself has no build step)." >&2
  exit 1
fi

# Pull out inline <script>...</script> blocks, skipping any tag that loads an
# external file (e.g. the Supabase CDN <script src="...">, which has nothing
# to check locally).
awk '
  /<script([ >])/ {
    if ($0 ~ /src=/) { skip_this_tag = 1 } else { skip_this_tag = 0; in_script = 1 }
    next
  }
  /<\/script>/ { in_script = 0; next }
  in_script { print }
' "$FILE" > "$TMP"

if [ ! -s "$TMP" ]; then
  echo "No inline script content found — check that index.html still has the expected <script> structure." >&2
  exit 1
fi

node --check "$TMP"
echo "Syntax check passed."
