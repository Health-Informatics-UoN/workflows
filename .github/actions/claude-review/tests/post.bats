#!/usr/bin/env bats
# These are the tests for post.sh.
#
# fixtures/pr.diff changes these files:
#   app.py   hunk 1: new lines 1-4 (line 2 is added; line 3 is a blank context line,
#            which a diff stores as one space)
#            hunk 2: new lines 21-24 (lines 22 and 23 are added). The hunk has a removed
#            line that starts with "-- " and an added line that starts with "++ ". In
#            the diff, these lines show as "--- " and "+++ ", the same as file headers.
#            The tests make sure that post.sh counts them as lines.
#   old.txt  is deleted, so you cannot comment on it.
#   "my notes.txt"  is a new file with a space in its name. Git adds a TAB after the
#            name on the "+++" line. New line 1.
#   café.py  has a name that git quotes and writes with backslash codes
#            ("b/caf\303\251.py"). New line 1.

load test_helper

setup() {
  common_setup
  mkdir -p .pr-review
  cp "$BATS_TEST_DIRNAME/fixtures/pr.diff" .pr-review/pr.diff
}

posted_review() {
  stdin_of /reviews
}

posted_summary() {
  stdin_of POST | jq -r '.body'
}

@test "findings on lines in the diff are posted as one review" {
  write_review '[{"path":"app.py","line":2,"body":"First"},{"path":"app.py","line":22,"body":"Second"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls /reviews)" -eq 1 ]
  [ "$(posted_review | jq '.comments | length')" -eq 2 ]
  [ "$(posted_review | jq -r '.commit_id')" = "abcdef1234567" ]
  [ "$(posted_review | jq -r '.event')" = "COMMENT" ]
}

@test "a single-line finding is posted on its line, on the new side" {
  write_review '[{"path":"app.py","line":2,"body":"Check this"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(posted_review | jq -c '.comments[0] | {path, line, side}')" = '{"path":"app.py","line":2,"side":"RIGHT"}' ]
  [ "$(posted_review | jq '.comments[0] | has("start_line")')" = "false" ]
}

@test "each posted finding carries the hidden marker" {
  write_review '[{"path":"app.py","line":2,"body":"Check this"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(posted_review | jq -r '.comments[0].body')" = $'Check this\n\n<!-- claude-review-finding -->' ]
}

@test "a range within one hunk is posted as a range" {
  write_review '[{"path":"app.py","start_line":1,"line":4,"body":"Block"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(posted_review | jq -c '.comments[0] | {start_line, start_side, line}')" = '{"start_line":1,"start_side":"RIGHT","line":4}' ]
}

@test "a range crossing hunks is posted on its last line only" {
  write_review '[{"path":"app.py","start_line":3,"line":22,"body":"Across hunks"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(posted_review | jq -c '.comments[0] | {line, has_start: has("start_line")}')" = '{"line":22,"has_start":false}' ]
}

@test "a start_line that isn't before line is ignored" {
  write_review '[{"path":"app.py","start_line":4,"line":4,"body":"Same line"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(posted_review | jq '.comments[0] | has("start_line")')" = "false" ]
}

@test "lines that look like diff headers are counted as lines" {
  write_review '[{"path":"app.py","line":23,"body":"Added line"},{"path":"app.py","line":24,"body":"Context line"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(posted_review | jq -c '[.comments[].line]')" = "[23,24]" ]
}

@test "findings that can't be attached go in the summary, not the review" {
  write_review '[{"path":"app.py","line":2,"body":"Attached"},{"path":"app.py","line":10,"body":"Not in diff"},{"path":"old.txt","line":1,"body":"Deleted file"},{"path":"other.py","line":1,"body":"Unknown file"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(posted_review | jq -c '[.comments[].line]')" = "[2]" ]
  posted_summary | grep -qF '`app.py:10`: Not in diff'
  posted_summary | grep -qF '`old.txt:1`: Deleted file'
  posted_summary | grep -qF '`other.py:1`: Unknown file'
  posted_summary | grep -qF '1 inline finding(s)'
}

@test "no findings: no review is posted, and the summary says so" {
  write_review '[]' "No problems found."
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls /reviews)" -eq 0 ]
  posted_summary | grep -qF '0 inline finding(s)'
  posted_summary | grep -qF 'No problems found.'
  ! posted_summary | grep -qF 'could not be attached'
}

@test "the first run posts the summary comment, with its marker" {
  write_review '[]' "All good."
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(count_calls POST)" -eq 1 ]
  [ "$(count_calls DELETE)" -eq 0 ]
  posted_summary | head -n 1 | grep -qxF '<!-- claude-review-summary -->'
  posted_summary | grep -qF 'of abcdef1'
}

# The comment list is read after the new summary is posted, so it contains the new
# summary (999, from the fake gh) too.
@test "a later run posts a new summary at the bottom, then deletes the previous one" {
  export GH_ISSUE_COMMENTS_JSON='[{"id":111,"user":{"login":"someone","type":"User"},"body":"A person"},{"id":222,"user":{"login":"github-actions[bot]","type":"Bot"},"body":"<!-- claude-review-summary -->\nOld summary"},{"id":999,"user":{"login":"github-actions[bot]","type":"Bot"},"body":"<!-- claude-review-summary -->\nNew summary"}]'
  write_review '[]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls POST)" -eq 1 ]
  [ "$(count_calls DELETE)" -eq 1 ]
  grep -qx "repos/org/repo/issues/comments/222" "$(calls_with DELETE)"
  posted=$(basename "$(calls_with POST)")
  deleted=$(basename "$(calls_with DELETE)")
  [[ "$posted" < "$deleted" ]]
}

@test "a person's comment containing the marker isn't deleted" {
  export GH_ISSUE_COMMENTS_JSON='[{"id":111,"user":{"login":"someone","type":"User"},"body":"Quoting <!-- claude-review-summary -->"}]'
  write_review '[]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$(count_calls DELETE)" -eq 0 ]
  [ "$(count_calls POST)" -eq 1 ]
}

@test "another bot's comment containing the marker isn't deleted" {
  export GH_ISSUE_COMMENTS_JSON='[{"id":333,"user":{"login":"other-app[bot]","type":"Bot"},"body":"Copied: <!-- claude-review-summary -->"}]'
  write_review '[]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls DELETE)" -eq 0 ]
}

@test "a diff too large to pass as one command-line argument still works" {
  # 20000 added lines make a line map of more than 128 KiB, the Linux limit for one
  # command-line argument.
  {
    printf 'diff --git a/big.txt b/big.txt\nnew file mode 100644\n--- /dev/null\n+++ b/big.txt\n'
    printf '@@ -0,0 +1,20000 @@\n'
    seq 1 20000 | sed 's/^/+line /'
  } > .pr-review/pr.diff
  write_review '[{"path":"big.txt","line":19999,"body":"Near the end"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %s "$RUNNER_TEMP/commentable.json")" -gt 131072 ]
  [ "$(posted_review | jq -c '.comments[0] | {path, line}')" = '{"path":"big.txt","line":19999}' ]
}

@test "a file name with a space can be commented on" {
  write_review '[{"path":"my notes.txt","line":1,"body":"Spaces"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(posted_review | jq -c '.comments[0] | {path, line}')" = '{"path":"my notes.txt","line":1}' ]
}

@test "a file name git quotes can be commented on" {
  write_review '[{"path":"café.py","line":1,"body":"Accent"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [ "$(posted_review | jq -r '.comments[0].path')" = "café.py" ]
}

@test "if GitHub rejects the review, every finding goes in the summary" {
  export GH_FAIL_REVIEW=1
  write_review '[{"path":"app.py","line":2,"body":"First"},{"path":"app.py","line":10,"body":"Not in diff"}]'
  run bash "$ACTION_DIR/scripts/post.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::GitHub rejected the review"* ]]
  posted_summary | grep -qF '0 inline finding(s)'
  posted_summary | grep -qxF -- '- `app.py:2`: First'
  posted_summary | grep -qF '`app.py:10`: Not in diff'
}
