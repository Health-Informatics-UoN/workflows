#!/usr/bin/env bats
# Tests for check-size.sh.

load test_helper

setup() {
  common_setup
  export PR_URL="https://github.com/org/repo/pull/7" MAX_LINES=100
}

@test "a PR under the limit is reviewed, with no comment" {
  ADDITIONS=60 DELETIONS=30 run bash "$ACTION_DIR/check-size.sh"
  [ "$status" -eq 0 ]
  grep -qx "too-large=false" "$GITHUB_OUTPUT"
  [ -z "$(ls "$GH_CALLS")" ]
}

@test "a PR exactly at the limit is reviewed" {
  ADDITIONS=50 DELETIONS=50 run bash "$ACTION_DIR/check-size.sh"
  [ "$status" -eq 0 ]
  grep -qx "too-large=false" "$GITHUB_OUTPUT"
}

@test "a PR over the limit is skipped and gets one comment" {
  ADDITIONS=80 DELETIONS=30 run bash "$ACTION_DIR/check-size.sh"
  [ "$status" -eq 0 ]
  grep -qx "too-large=true" "$GITHUB_OUTPUT"
  [ "$(calls_with_arg comment | grep -c .)" -eq 1 ]
  file=$(calls_with_arg comment)
  grep -qF "<!-- claude-review-too-large -->" "$file"
  grep -qF "110 lines changed, limit 100" "$file"
}

@test "a PR over the limit that already has the comment gets no second one" {
  export GH_PR_JSON='{"comments":[{"body":"<!-- claude-review-too-large -->\nPR too large"}]}'
  ADDITIONS=80 DELETIONS=30 run bash "$ACTION_DIR/check-size.sh"
  [ "$status" -eq 0 ]
  grep -qx "too-large=true" "$GITHUB_OUTPUT"
  [ -z "$(calls_with_arg comment)" ]
}
