#!/usr/bin/env bash
# Gets the review threads of the PR one time, for this script and for post.sh. Then
# writes .pr-review/discussed.json. This file contains the findings from earlier reviews
# of this PR that have replies, and the replies. Thus, Claude does not show a finding
# again after a person disagrees with it.
#
# Writes two files:
#   $RUNNER_TEMP/threads.json  the full answer from GitHub. post.sh uses it for the
#                              earlier findings. It is outside the checkout on purpose:
#                              it contains comments from any person. Claude must not
#                              read these comments.
#   .pr-review/discussed.json  the filtered list below, in the checkout for Claude.
#
# This file includes only replies from persons with access to the repository (owners,
# organisation members and collaborators). Any person can comment on a public PR, so
# other replies can contain injected instructions. For the same reason, a thread is an
# earlier finding only if a bot account posted its first comment. The marker alone is
# not sufficient, because any person can copy the marker into a comment.
#
# Environment (set by action.yml):
#   REPO         owner/name of the repository, for example org/repo
#   PR_NUMBER    the PR number
#   GH_TOKEN     the token that gh uses to read the PR
#   RUNNER_TEMP  a temporary folder outside the checkout
# The current directory is the checkout. .pr-review/ exists already.
#
# Example discussed.json:
#   [{"path": "app.py", "line": 2, "resolved": true,
#     "finding": "Use a constant here.",
#     "replies": [{"author": "alice", "body": "No, this is deliberate."}]}]
set -euo pipefail

threads="$RUNNER_TEMP/threads.json"

# The hidden marker that post.sh adds to each finding that it posts.
marker="<!-- claude-review-finding -->"

# Review threads are available only through the GraphQL API, not the REST API.
# post.sh uses the thread id and isResolved to resolve or mark old findings, and the
# comment databaseId to edit them. "line" is null if the code changed after the
# comment (the thread is outdated). Then "originalLine" is the line of the first post.
# The first 100 threads are sufficient for almost all PRs.
# REPO is "owner/name": ${REPO%/*} is the owner and ${REPO#*/} is the name.
# The $ names in the query are GraphQL variables, not shell variables. Thus, the
# single quotes are on purpose.
# shellcheck disable=SC2016
gh api graphql \
  -f owner="${REPO%/*}" -f name="${REPO#*/}" -F number="$PR_NUMBER" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              id isResolved path line originalLine
              comments(first: 20) {
                totalCount
                nodes { databaseId body authorAssociation author { __typename login } }
              }
            }
          }
        }
      }
    }' > "$threads"

jq --arg marker "$marker" '
  .data.repository.pullRequest.reviewThreads.nodes
  # Keep only the threads that a bot account started with the marker.
  | map(select(.comments.nodes[0].body | contains($marker))
      | select(.comments.nodes[0].author.__typename == "Bot")
      | {
          path,
          # If the thread is outdated, use the original line.
          line: (.line // .originalLine),
          resolved: .isResolved,
          # The finding text, without the marker.
          finding: (.comments.nodes[0].body | split("\n\n" + $marker)[0]),
          # The comments after the first, only from trusted persons.
          replies: [.comments.nodes[1:][]
            | select(.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR"))
            | {author: .author.login, body}]
        }
      # Remove findings that have no trusted replies. Claude needs no data about them.
      | select(.replies | length > 0))
' "$threads" > .pr-review/discussed.json
