#!/usr/bin/env bash
# Decides whether the PR is small enough to review, and tells the later steps.
#
# Sets the step output `too-large` to "true" or "false"; the other steps in action.yml
# only run when it's "false". Large PRs cost more to review and get worse reviews, so
# they're skipped. When a PR is skipped, it gets one comment saying why; a hidden
# marker in that comment stops it being posted again on every push.
#
# Environment (set by action.yml):
#   ADDITIONS, DELETIONS  lines added and removed by the PR, from the GitHub event
#   MAX_LINES             the limit, from the max-lines input
#   PR_URL                the PR, for gh
#   REPO, PR_NUMBER       the repository (owner/name) and PR number, for the API
#   GH_TOKEN              token gh uses to read and post comments
#   GITHUB_OUTPUT         file GitHub Actions reads step outputs from
set -euo pipefail  # Stop on any error, unset variable or failed command in a pipe.

# Changed lines = additions + deletions, as GitHub counts them.
lines=$((ADDITIONS + DELETIONS))

if [ "$lines" -le "$MAX_LINES" ]; then
  echo "too-large=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "too-large=true" >> "$GITHUB_OUTPUT"

# The marker is an HTML comment, so it's invisible on GitHub but still in the
# comment's text, where the next run can find it.
marker="<!-- claude-review-too-large -->"

# Get the text of every comment on the PR that a bot account posted. Only those count:
# anyone could copy the marker into a comment of their own to stop the notice being
# posted. --paginate reads every page of comments.
comments=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq '.[] | select(.user.type == "Bot") | .body')

# If an earlier run already said the PR is too large, don't say it again.
if grep -qF "$marker" <<< "$comments"; then
  echo "Too-large comment already posted; skipping review."
  exit 0
fi

gh pr comment "$PR_URL" --body "$marker
PR too large for automated review (${lines} lines changed, limit ${MAX_LINES}). Consider splitting it up."
