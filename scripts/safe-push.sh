#!/bin/bash
# Pushes the current branch to origin — but refuses outright if the current
# branch is a protected one. This is called BY Builder, but it doesn't trust
# Builder's judgment about which branch it's on — it checks itself.

set -euo pipefail

BRANCH=$(git rev-parse --abbrev-ref HEAD)
PROTECTED=("main" "master" "production" "release")

for p in "${PROTECTED[@]}"; do
  if [ "$BRANCH" == "$p" ]; then
    echo "REFUSED: '$BRANCH' is a protected branch. Create a feature branch first (e.g. git checkout -b agent/short-task-name) before pushing." >&2
    exit 1
  fi
done

git push -u origin "$BRANCH"
echo "Pushed branch: $BRANCH"
