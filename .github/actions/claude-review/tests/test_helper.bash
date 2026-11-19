# Shared setup for the Claude review action tests. Each test runs in its own
# temporary directory, with the fake gh and claude from tests/bin.

# shellcheck disable=SC2034 # used by the .bats files
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

# The gh calls whose arguments contain $1, in call order.
calls_with() {
  grep -lF -- "$1" "$GH_CALLS"/*.args 2>/dev/null || true
}

count_calls() {
  calls_with "$1" | grep -c . || true
}

# The gh calls with an argument exactly equal to $1, for example "comment" in
# "gh pr comment" but not "comments" in "gh pr view --json comments".
calls_with_arg() {
  grep -lxF -- "$1" "$GH_CALLS"/*.args 2>/dev/null || true
}

# What the first gh call whose arguments contain $1 read from stdin.
stdin_of() {
  local file
  file=$(calls_with "$1" | head -n 1)
  cat "${file%.args}.stdin"
}

# Writes Claude's output to $RUNNER_TEMP/review.json, as review.sh does.
# $1: findings as a JSON array. $2: summary.
write_review() {
  jq -n --argjson findings "$1" --arg summary "${2:-Summary text.}" \
    '{is_error: false, structured_output: {findings: $findings, summary: $summary}}' \
    > "$RUNNER_TEMP/review.json"
}

# --- Review threads, as GitHub's GraphQL API returns them -----------------------------

# One review thread, as JSON.
#   $1  the first comment's text
#   $2  replies, as a JSON array of comment nodes (see reply); default none
#   $3  whether the thread is resolved: true or false; default true
#   $4  the first comment's author type: "Bot" (as for this action's own findings) or
#       "User"; default "Bot"
#   $5  the thread id; default T_1
# The first comment's id (databaseId) is always 901.
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

# One reply, as a JSON comment node. $1: login, $2: authorAssociation, $3: text.
reply() {
  jq -n --arg login "$1" --arg association "$2" --arg body "$3" \
    '{body: $body, authorAssociation: $association, author: {__typename: "User", login: $login}}'
}

# Sets the PR's review threads, from threads given as arguments (see thread), in both
# places the scripts get them: the fake gh's answer (GH_THREADS_JSON, used by
# fetch-discussed.sh) and $RUNNER_TEMP/threads.json (the file fetch-discussed.sh saves
# and post.sh reads). With no arguments, the PR has no threads.
set_threads() {
  GH_THREADS_JSON=$(jq -s '{data: {repository: {pullRequest: {reviewThreads: {nodes: .}}}}}' <<< "$*")
  export GH_THREADS_JSON
  printf '%s' "$GH_THREADS_JSON" > "$RUNNER_TEMP/threads.json"
}

# A finding's text as this action posts it, with the hidden marker. $1: the finding.
as_finding() {
  printf '%s\n\n<!-- claude-review-finding -->' "$1"
}
