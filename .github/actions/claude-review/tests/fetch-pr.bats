#!/usr/bin/env bats
# Tests for fetch-pr.sh, with a fake gh.

load test_helper

setup() {
  common_setup
  export BASE_SHA="base1111111111" HEAD_SHA="head2222222222"
  export GH_COMPARE_DIFF=$'diff --git a/app.py b/app.py\n+++ b/app.py\n@@ -1 +1 @@\n+print("hi")'
  export GH_PR_JSON='{"title":"Add greeting","body":"Says hi.","author":{"login":"alice"},"baseRefName":"main","headRefName":"greet"}'
}

@test "the diff is fetched for the exact commits in the event, not the PR as it is now" {
  run bash "$ACTION_DIR/fetch-pr.sh"
  [ "$status" -eq 0 ]
  grep -qx "repos/org/repo/compare/base1111111111...head2222222222" "$(calls_with /compare/)"
  [ -z "$(calls_with_arg diff)" ]
}

@test "the diff is requested as a plain diff and saved" {
  run bash "$ACTION_DIR/fetch-pr.sh"
  grep -qx "Accept: application/vnd.github.diff" "$(calls_with /compare/)"
  [ "$(cat .pr-review/pr.diff)" = "$GH_COMPARE_DIFF" ]
}

@test "the PR details are saved, without the list of files as it is now" {
  run bash "$ACTION_DIR/fetch-pr.sh"
  grep -qx "title,body,author,baseRefName,headRefName" "$(calls_with 'pr' | head -n 1)"
  [ "$(jq -r '.title' .pr-review/pr.json)" = "Add greeting" ]
}

@test "a .pr-review folder already in the checkout is replaced" {
  mkdir .pr-review
  echo "planted by the PR" > .pr-review/extra.txt
  run bash "$ACTION_DIR/fetch-pr.sh"
  [ "$status" -eq 0 ]
  [ ! -e .pr-review/extra.txt ]
}
