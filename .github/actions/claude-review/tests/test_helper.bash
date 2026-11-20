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
