#!/usr/bin/env bash
# Gets the review threads of the PR one time, for this script and for post.sh. Then
# writes .pr-review/discussed.json. This file contains the findings from earlier reviews
# of this PR that have replies, and the replies. Thus, Claude does not show a finding
# again after a person disagrees with it.
#
# Writes two files:
#   $RUNNER_TEMP/threads.json  all the review threads of the PR, as one JSON list.
#                              post.sh uses it for the earlier findings. It is outside
#                              the checkout on purpose: it contains comments from any
#                              person. Claude must not read these comments.
#   .pr-review/discussed.json  the filtered list below, in the checkout for Claude.
#
# Only replies from persons with access to the repository (owners, organisation members
# and collaborators) are included. Any person can comment on a public PR, so other
# replies can contain injected instructions. For the same reason, a thread is an earlier
# finding only if a bot posted its first comment. Any person can copy the marker.
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

# The hidden markers that post.sh adds: to each finding that it posts, and to the note
# at the top of an earlier finding that it marks as superseded.
marker="<!-- claude-review-finding -->"
superseded_marker="<!-- claude-review-superseded -->"

# Review threads are available only through the GraphQL API, not the REST API.
# post.sh uses the thread id and isResolved to resolve or mark old findings, and the
# comment databaseId to edit them. "line" is null if the thread is outdated (the code
# changed). Then "originalLine" is the line of the first post.
# With --paginate, gh gets all the pages of 100 threads: it gives $endCursor to the next
# request until hasNextPage is false. jq -s joins the threads of all pages in one list.
# The query gets a maximum of 20 comments for each thread. totalCount is always the
# full number, so the check for "no replies" in post.sh is always correct.
# REPO is "owner/name": ${REPO%/*} is the owner and ${REPO#*/} is the name.
# The $ names in the query are GraphQL variables, so the single quotes are on purpose.
# shellcheck disable=SC2016
gh api graphql --paginate \
  -f owner="${REPO%/*}" -f name="${REPO#*/}" -F number="$PR_NUMBER" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $endCursor) {
            pageInfo { hasNextPage endCursor }
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
    }' \
  | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]]' > "$threads"

jq --arg marker "$marker" --arg superseded "$superseded_marker" '
  # Keep only the threads that a bot account started with the marker.
  map(select((.comments.nodes[0].body // "") | contains($marker))
      | select(.comments.nodes[0].author.__typename == "Bot")
      | {
          path,
          # If the thread is outdated, use the original line.
          line: (.line // .originalLine),
          resolved: .isResolved,
          # The finding text, without the marker and without a superseded note.
          finding: (.comments.nodes[0].body
            | split($superseded + "\n\n") | last
            | split("\n\n" + $marker)[0]),
          # The comments after the first, only from trusted persons.
          replies: [.comments.nodes[1:][]
            | select(.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR"))
            | {author: .author.login, body}]
        }
      # Remove findings that have no trusted replies. Claude needs no data about them.
      | select(.replies | length > 0))
' "$threads" > .pr-review/discussed.json
