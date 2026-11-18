#!/usr/bin/env bash
# Sets the too-large output. For PRs over MAX_LINES changed lines (additions +
# deletions), comments once per PR, using a hidden marker to avoid repeats.
set -euo pipefail

lines=$((ADDITIONS + DELETIONS))
if [ "$lines" -le "$MAX_LINES" ]; then
  echo "too-large=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "too-large=true" >> "$GITHUB_OUTPUT"

marker="<!-- claude-review-too-large -->"
comments=$(gh pr view "$PR_URL" --json comments -q '.comments[].body')
if grep -qF "$marker" <<< "$comments"; then
  echo "Too-large comment already posted; skipping review."
  exit 0
fi
gh pr comment "$PR_URL" --body "$marker
PR too large for automated review (${lines} lines changed, limit ${MAX_LINES}). Consider splitting it up."
