#!/usr/bin/env bats
# These are the tests for review.sh.

load test_helper

setup() {
  common_setup
  # review.sh runs $GITHUB_ACTION_PATH/node_modules/.bin/claude. It reads the prompt,
  # the standards and the schema from $GITHUB_ACTION_PATH/prompt.
  export GITHUB_ACTION_PATH="$BATS_TEST_TMPDIR/action"
  mkdir -p "$GITHUB_ACTION_PATH/node_modules/.bin"
  ln -s "$ACTION_DIR/prompt" "$GITHUB_ACTION_PATH/prompt"
  ln -s "$BATS_TEST_DIRNAME/bin/claude" "$GITHUB_ACTION_PATH/node_modules/.bin/claude"
  export CLAUDE_ARGS="$BATS_TEST_TMPDIR/claude-args"
  export MODEL="claude-test-model" MAX_TURNS="7" EFFORT="low" ANTHROPIC_API_KEY="test-key"
  export CLAUDE_OUTPUT='{"is_error":false,"num_turns":3,"structured_output":{"findings":[],"summary":"No findings."}}'
}

# Returns true if the fake claude got argument $1, followed by argument $2.
has_arg_pair() {
  awk -v a="$1" -v b="$2" 'prev == a && $0 == b { found = 1 } { prev = $0 } END { exit !found }' "$CLAUDE_ARGS"
}

@test "an empty API key fails with a clear message, without running Claude" {
  export ANTHROPIC_API_KEY=""
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ANTHROPIC_API_KEY is empty"* ]]
  [ ! -e "$CLAUDE_ARGS" ]
}

@test "a missing API key fails with a clear message" {
  unset ANTHROPIC_API_KEY
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ANTHROPIC_API_KEY is empty"* ]]
}

@test "a completed review passes and keeps Claude's output" {
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.structured_output.summary' "$RUNNER_TEMP/review.json")" = "No findings." ]
}

@test "the model, turn limit and effort are passed to Claude" {
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 0 ]
  has_arg_pair --model claude-test-model
  has_arg_pair --max-turns 7
  has_arg_pair --effort low
}

@test "the prompt includes the review standards" {
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 0 ]
  grep -qF "# Review standards" "$CLAUDE_ARGS"
}

# All the protections in review.sh are command-line flags. If someone removes a flag,
# these tests fail. Thus, a protection cannot disappear without notice.
@test "Claude has only the Read, Grep and Glob tools" {
  run bash "$ACTION_DIR/scripts/review.sh"
  has_arg_pair --tools "Read,Grep,Glob"
}

@test "the repository's own Claude settings and MCP servers are ignored" {
  run bash "$ACTION_DIR/scripts/review.sh"
  has_arg_pair --setting-sources user
  grep -qx -- "--strict-mcp-config" "$CLAUDE_ARGS"
}

@test "reading is allowed only inside the checkout, with secret locations denied" {
  run bash "$ACTION_DIR/scripts/review.sh"
  has_arg_pair --allowedTools "Read(./**),Grep(./**),Glob(./**)"
  denied=$(grep -A1 -x -- "--disallowedTools" "$CLAUDE_ARGS" | tail -n 1)
  for tool in Read Grep Glob; do
    for path in "//proc/**" "//sys/**" "//etc/**" "//root/**" "//tmp/**" "//run/**" \
      "//var/**" "~/.*/**" "/$RUNNER_TEMP/**"; do
      [[ ",$denied," == *",$tool($path),"* ]]
    done
  done
}

@test "the output must match the findings schema" {
  run bash "$ACTION_DIR/scripts/review.sh"
  has_arg_pair --json-schema "$(jq -c . "$ACTION_DIR/prompt/schema.json")"
}

@test "an error from Claude fails the review" {
  export CLAUDE_OUTPUT='{"is_error":true,"result":"Something went wrong"}' CLAUDE_EXIT=1
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude review did not complete"* ]]
  [[ "$output" == *"Something went wrong"* ]]
}

@test "a result without findings (for example, the turn limit was reached) fails the review" {
  export CLAUDE_OUTPUT='{"is_error":false,"subtype":"error_max_turns","result":""}'
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude review did not complete"* ]]
}

@test "output that isn't JSON fails the review with a clear message" {
  export CLAUDE_OUTPUT='Credit balance is too low' CLAUDE_EXIT=1
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude review did not complete"* ]]
  [[ "$output" == *"Credit balance is too low"* ]]
}

@test "no output at all fails the review" {
  export CLAUDE_OUTPUT='' CLAUDE_EXIT=1
  run bash "$ACTION_DIR/scripts/review.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude review did not complete"* ]]
}
