#!/usr/bin/env bash
# Writes .pr-review/discussed.json: findings from earlier reviews of this PR that people
# have replied to, with their replies, so Claude doesn't raise a finding again after
# someone has disagreed with it.
#
# Only replies from people with access to the repository (owners, organisation members
# and collaborators) are included. Anyone can comment on a public PR, so other replies
# could carry injected instructions. For the same reason, a thread only counts as an
# earlier finding if its first comment was posted by a bot account, not just if it
# contains the marker: anyone could copy the marker into a comment of their own.
#
# Environment (set by action.yml):
#   REPO       owner/name of the repository, for example org/repo
#   PR_NUMBER  the PR number
#   GH_TOKEN   token gh uses to read the PR
# The current directory is the checkout; .pr-review/ already exists.
#
# Example output:
#   [{"path": "app.py", "line": 2, "resolved": true,
#     "finding": "Use a constant here.",
#     "replies": [{"author": "alice", "body": "No, this is deliberate."}]}]
set -euo pipefail  # Stop on any error, unset variable or failed command in a pipe.

# The hidden marker post.sh adds to each finding it posts.
marker="<!-- claude-review-finding -->"

# Review threads are only available through the GraphQL API, not the REST API.
# For each thread the query gets: whether it's resolved, its file and line, and up to
# 20 comments with their text, author (and whether the author is a user or a bot) and
# the author's relationship to the repository
# (authorAssociation: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR, NONE and so on).
# "line" is null when the code has changed since the comment (the thread is outdated);
# "originalLine" is then the line it was first posted on.
# REPO is "owner/name": ${REPO%/*} is the owner and ${REPO#*/} the name.
#
# The $ names in the query are GraphQL variables, not shell ones, so they're in single
# quotes on purpose (shellcheck would otherwise warn about it).
# shellcheck disable=SC2016
gh api graphql \
  -f owner="${REPO%/*}" -f name="${REPO#*/}" -F number="$PR_NUMBER" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              isResolved path line originalLine
              comments(first: 20) {
                nodes { body authorAssociation author { __typename login } }
              }
            }
          }
        }
      }
    }' \
  | jq --arg marker "$marker" '
      .data.repository.pullRequest.reviewThreads.nodes
      # Keep threads that start with a finding from this action: the first comment has
      # the marker and was posted by a bot account. A user can copy the marker, but
      # cannot post as a bot. Then reshape each one.
      | map(select(.comments.nodes[0].body | contains($marker))
          | select(.comments.nodes[0].author.__typename == "Bot")
          | {
              path,
              # The current line, or the original one if the thread is outdated.
              line: (.line // .originalLine),
              resolved: .isResolved,
              # The finding text, without the marker.
              finding: (.comments.nodes[0].body | split("\n\n" + $marker)[0]),
              # The replies (every comment after the first), from trusted people only.
              replies: [.comments.nodes[1:][]
                | select(.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR"))
                | {author: .author.login, body}]
            }
          # Drop findings with no trusted replies: there is nothing to tell Claude.
          | select(.replies | length > 0))
    ' > .pr-review/discussed.json
