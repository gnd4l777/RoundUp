#!/bin/bash
# Commits staged changes — but refuses outright if the current branch is
# protected. Mirrors safe-push.sh: this doesn't trust the calling agent's
# judgment about which branch it's on, it checks for itself.

set -euo pipefail

BRANCH=$(git rev-parse --abbrev-ref HEAD)
PROTECTED=("main" "master" "production" "release")

for p in "${PROTECTED[@]}"; do
  if [ "$BRANCH" == "$p" ]; then
    echo "REFUSED: cannot commit directly on protected branch '$BRANCH'. Create a feature branch first: git checkout -b agent/short-task-name" >&2
    exit 1
  fi
done

if [ -z "${1:-}" ]; then
  echo "REFUSED: a commit message is required. Usage: bash scripts/safe-commit.sh \"message\"" >&2
  exit 1
fi

git commit -m "$1"
echo "Committed on branch: $BRANCH"
