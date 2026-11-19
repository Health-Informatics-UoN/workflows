#!/usr/bin/env bash
# Saves the PR into .pr-review/ in the checkout. Claude reads these files:
#   pr.json  the title, description, author and branch names
#   pr.diff  the changes, for the exact commits that this run reviews
#
# This script gets the PR before Claude starts. Thus, the Claude step does not need a
# GitHub token. The script does not get the PR comments. Any person can post them, so
# they can contain injected instructions. (fetch-discussed.sh gets the trusted replies
# to earlier findings.)
#
# The diff is for BASE_SHA...HEAD_SHA. These are the commits in the event that started
# this run. The diff is not for the current state of the PR. The checkout and post.sh
# also use HEAD_SHA. Thus, these three items are the same commit: the code that Claude
# reads, the diff that its line numbers refer to, and the commit that gets the comments.
# This is true also if a person pushes during the review. (The three dots compare
# HEAD_SHA with the point where it branched from BASE_SHA. GitHub shows the same diff on
# the PR.)
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

# Do not include the list of changed files. That list is for the current state of the
# PR. Also, the diff shows the files.
gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json title,body,author,baseRefName,headRefName > .pr-review/pr.json

# The Accept header asks for a plain diff, not JSON.
gh api "repos/${REPO}/compare/${BASE_SHA}...${HEAD_SHA}" \
  -H "Accept: application/vnd.github.diff" > .pr-review/pr.diff
