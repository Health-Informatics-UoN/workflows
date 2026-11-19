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
