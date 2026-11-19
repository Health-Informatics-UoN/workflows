# This file has the shared setup for the Claude review action tests. Each test runs in
# a different temporary directory. The tests use the fake gh and claude from tests/bin.

# shellcheck disable=SC2034 # the .bats files use this variable
ACTION_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

common_setup() {
  export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
  export GH_CALLS="$BATS_TEST_TMPDIR/gh-calls"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  export REPO="org/repo" PR_NUMBER="7" HEAD_SHA="abcdef1234567"
  mkdir -p "$GH_CALLS" "$RUNNER_TEMP" "$BATS_TEST_TMPDIR/workspace"
  : > "$GITHUB_OUTPUT"
  cd "$BATS_TEST_TMPDIR/workspace" || return 1
}

# Shows the gh calls that have $1 in their arguments, in call order.
calls_with() {
  grep -lF -- "$1" "$GH_CALLS"/*.args 2>/dev/null || true
}

count_calls() {
  calls_with "$1" | grep -c . || true
}

# Shows the gh calls that have an argument that is exactly $1. For example, "comment"
# finds "gh pr comment", but not "repos/org/repo/issues/7/comments".
calls_with_arg() {
  grep -lxF -- "$1" "$GH_CALLS"/*.args 2>/dev/null || true
}

# Shows the stdin text of the first gh call that has $1 in its arguments.
stdin_of() {
  local file
  file=$(calls_with "$1" | head -n 1)
  cat "${file%.args}.stdin"
}

# Writes the output of Claude to $RUNNER_TEMP/review.json, as review.sh does.
# $1: the findings, as a JSON array. $2: the summary.
write_review() {
  jq -n --argjson findings "$1" --arg summary "${2:-Summary text.}" \
    '{is_error: false, structured_output: {findings: $findings, summary: $summary}}' \
    > "$RUNNER_TEMP/review.json"
}

# --- Review threads, in the format of the GitHub GraphQL API -------------------------

# Makes one review thread, as JSON.
#   $1  the text of the first comment
#   $2  the replies, as a JSON array of comment nodes (see reply); default: no replies
#   $3  the status of the thread: true (resolved) or false (open); default true
#   $4  the author type of the first comment: "Bot" or "User"; default "Bot"
#   $5  the thread id; default T_1
# The id (databaseId) of the first comment is always 901.
thread() {
  jq -n --arg first "$1" --argjson replies "${2:-[]}" --argjson resolved "${3:-true}" \
    --arg type "${4:-Bot}" --arg id "${5:-T_1}" '{
    id: $id, isResolved: $resolved, path: "app.py", line: 2, originalLine: 2,
    comments: {
      totalCount: (1 + ($replies | length)),
      nodes: ([{databaseId: 901, body: $first, authorAssociation: "NONE",
        author: {__typename: $type, login: "github-actions"}}] + $replies)
    }
  }'
}

# Makes one reply, as a JSON comment node. $1: login, $2: authorAssociation, $3: text.
reply() {
  jq -n --arg login "$1" --arg association "$2" --arg body "$3" \
    '{body: $body, authorAssociation: $association, author: {__typename: "User", login: $login}}'
}

# Shows one page of review threads, as the GitHub GraphQL API gives it. The arguments
# are threads (see thread). The page is the last page.
threads_page() {
  jq -s '{data: {repository: {pullRequest: {reviewThreads: {
    pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}}' <<< "$*"
}

# Sets the review threads of the PR (see thread). With no arguments, the PR has no
# threads. It writes the threads to GH_THREADS_JSON (the answer of the fake gh, for
# fetch-discussed.sh) and to $RUNNER_TEMP/threads.json (the list that
# fetch-discussed.sh saves and post.sh reads).
set_threads() {
  GH_THREADS_JSON=$(threads_page "$@")
  export GH_THREADS_JSON
  jq -s '.' <<< "$*" > "$RUNNER_TEMP/threads.json"
}

# Shows the text of a finding as this action posts it, with the hidden marker.
# $1: the finding.
as_finding() {
  printf '%s\n\n<!-- claude-review-finding -->' "$1"
}
