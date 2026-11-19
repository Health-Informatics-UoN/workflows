#!/usr/bin/env bash
# Finds if the PR is small enough to review, and gives the result to the later steps.
#
# Sets the step output `too-large` to "true" or "false". The other steps in action.yml
# run only if it is "false". Large PRs cost more to review and get worse reviews, so
# this action does not review them. It posts one comment that gives the reason. A hidden
# marker in that comment stops the action from posting it again on each push.
#
# Environment (set by action.yml):
#   ADDITIONS, DELETIONS  the lines that the PR adds and removes, from the GitHub event
#   MAX_LINES             the limit, from the max-lines input
#   PR_URL                the PR, for gh
#   REPO, PR_NUMBER       the repository (owner/name) and the PR number, for the API
#   GH_TOKEN              the token that gh uses to read and post comments
#   GITHUB_OUTPUT         the file from which GitHub Actions reads the step outputs
set -euo pipefail

lines=$((ADDITIONS + DELETIONS))

if [ "$lines" -le "$MAX_LINES" ]; then
  echo "too-large=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "too-large=true" >> "$GITHUB_OUTPUT"

# GitHub does not show an HTML comment, but the next run finds it in the comment text.
marker="<!-- claude-review-too-large -->"

# Only bot comments count. If not, a person can copy the marker and stop the notice.
comments=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq '.[] | select(.user.type == "Bot") | .body')

if grep -qF "$marker" <<< "$comments"; then
  echo "Too-large comment already posted; skipping review."
  exit 0
fi

gh pr comment "$PR_URL" --body "$marker
PR too large for automated review (${lines} lines changed, limit ${MAX_LINES}). Consider splitting it up."
