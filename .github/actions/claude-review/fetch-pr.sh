#!/usr/bin/env bash
# Saves the PR into .pr-review/ in the checkout, for Claude to read:
#   pr.json  title, description, author and branch names
#   pr.diff  the changes, for the exact commits this run is reviewing
#
# Fetched here, before Claude runs, so the Claude step needs no GitHub token. PR
# comments aren't fetched: anyone can post them, so they could carry injected
# instructions (fetch-discussed.sh fetches the trusted replies to earlier findings).
#
# The diff is for BASE_SHA...HEAD_SHA, the commits in the event that started this run,
# not for "the PR as it is now". The checkout and post.sh use HEAD_SHA too, so the code
# Claude reads, the diff its line numbers refer to, and the commit the comments are
# attached to all match, even if someone pushes while the review is running. (The
# three dots compare HEAD_SHA with where it branched from BASE_SHA, which is the same
# diff GitHub shows on the PR.)
#
# Environment (set by action.yml):
#   REPO        owner/name of the repository, for example org/repo
#   PR_NUMBER   the PR number
#   BASE_SHA    the base branch commit, from the event
#   HEAD_SHA    the PR commit being reviewed, from the event
#   GH_TOKEN    token gh uses to read the PR
# The current directory is the checkout.
set -euo pipefail  # Stop on any error, unset variable or failed command in a pipe.

# Start clean, in case the PR itself contains a .pr-review folder.
rm -rf .pr-review
mkdir .pr-review

# The PR's description and metadata. The list of changed files isn't included: it
# would be for the PR as it is now, and the diff below already lists the files.
gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json title,body,author,baseRefName,headRefName > .pr-review/pr.json

# The diff, from GitHub's compare API. The Accept header asks for a plain diff rather
# than JSON.
gh api "repos/${REPO}/compare/${BASE_SHA}...${HEAD_SHA}" \
  -H "Accept: application/vnd.github.diff" > .pr-review/pr.diff
