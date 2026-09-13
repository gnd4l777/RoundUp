#!/bin/bash
# Checks whether another session (scheduled or live) is already working this
# repo. If clear, claims the lock. Locks older than 3 hours are treated as
# stale (a crashed session) and cleared automatically rather than blocking
# forever.

set -euo pipefail
LOCK_FILE=".claude-session.lock"
MAX_AGE_SECONDS=$((3 * 60 * 60))

if [ -f "$LOCK_FILE" ]; then
  LOCK_TIME=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$((NOW - LOCK_TIME))
  if [ "$AGE" -lt "$MAX_AGE_SECONDS" ]; then
    echo "locked"
    exit 0
  else
    echo "Stale lock found (${AGE}s old) — clearing it." >&2
  fi
fi

date +%s > "$LOCK_FILE"
echo "clear"
