#!/usr/bin/env bash
# Saves the PR into .pr-review/ in the checkout. Claude reads these files:
#   pr.json  the title, description, author and branch names
#   pr.diff  the changes, for the exact commits that this run reviews
#
# The script gets the PR before Claude starts, so the Claude step needs no GitHub token.
# It does not get the PR comments: any person can post them, so they can contain
# injected instructions.
#
# The diff is for BASE_SHA...HEAD_SHA, the commits in the event that started this run,
# not the current state of the PR. The checkout and post.sh also use HEAD_SHA. Thus, the
# code that Claude reads, the diff that its line numbers refer to, and the commit that
# gets the comments are the same, also if a person pushes during the review. (The three
# dots compare HEAD_SHA with the point where it branched from BASE_SHA, as on the PR.)
#
# Environment (set by action.yml):
#   REPO        owner/name of the repository, for example org/repo
#   PR_NUMBER   the PR number
#   BASE_SHA    the base branch commit, from the event
#   HEAD_SHA    the PR commit that this run reviews, from the event
#   GH_TOKEN    the token that gh uses to read the PR
# The current directory is the checkout.
set -euo pipefail

# Start with an empty folder. The PR can contain a .pr-review folder.
rm -rf .pr-review
mkdir .pr-review

# No list of changed files: it is for the current PR state. The diff shows the files.
gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json title,body,author,baseRefName,headRefName > .pr-review/pr.json

# The Accept header asks for a plain diff, not JSON.
gh api "repos/${REPO}/compare/${BASE_SHA}...${HEAD_SHA}" \
  -H "Accept: application/vnd.github.diff" > .pr-review/pr.diff
