#!/usr/bin/env bats
# These are the tests for post.sh.
#
# fixtures/pr.diff changes these files:
#   app.py   hunk 1: new lines 1-4 (line 2 is added)
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
  set_threads  # There are no review threads, unless a test sets them.
}

posted_review() {
  stdin_of /reviews
}

posted_summary() {
  stdin_of --body-file
}

@test "findings on lines in the diff are posted as one review" {
  write_review '[{"path":"app.py","line":2,"body":"First"},{"path":"app.py","line":22,"body":"Second"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls /reviews)" -eq 1 ]
  [ "$(posted_review | jq '.comments | length')" -eq 2 ]
  [ "$(posted_review | jq -r '.commit_id')" = "abcdef1234567" ]
  [ "$(posted_review | jq -r '.event')" = "COMMENT" ]
}

@test "a single-line finding is posted on its line, on the new side" {
  write_review '[{"path":"app.py","line":2,"body":"Check this"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(posted_review | jq -c '.comments[0] | {path, line, side}')" = '{"path":"app.py","line":2,"side":"RIGHT"}' ]
  [ "$(posted_review | jq '.comments[0] | has("start_line")')" = "false" ]
}

@test "each posted finding carries the hidden marker" {
  write_review '[{"path":"app.py","line":2,"body":"Check this"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(posted_review | jq -r '.comments[0].body')" = $'Check this\n\n<!-- claude-review-finding -->' ]
}

@test "a range within one hunk is posted as a range" {
  write_review '[{"path":"app.py","start_line":1,"line":4,"body":"Block"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(posted_review | jq -c '.comments[0] | {start_line, start_side, line}')" = '{"start_line":1,"start_side":"RIGHT","line":4}' ]
}

@test "a range crossing hunks is posted on its last line only" {
  write_review '[{"path":"app.py","start_line":3,"line":22,"body":"Across hunks"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(posted_review | jq -c '.comments[0] | {line, has_start: has("start_line")}')" = '{"line":22,"has_start":false}' ]
}

@test "a start_line that isn't before line is ignored" {
  write_review '[{"path":"app.py","start_line":4,"line":4,"body":"Same line"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(posted_review | jq '.comments[0] | has("start_line")')" = "false" ]
}

@test "lines that look like diff headers are counted as lines" {
  write_review '[{"path":"app.py","line":23,"body":"Added line"},{"path":"app.py","line":24,"body":"Context line"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(posted_review | jq -c '[.comments[].line]')" = "[23,24]" ]
}

@test "findings that can't be attached go in the summary, not the review" {
  write_review '[{"path":"app.py","line":2,"body":"Attached"},{"path":"app.py","line":10,"body":"Not in diff"},{"path":"old.txt","line":1,"body":"Deleted file"},{"path":"other.py","line":1,"body":"Unknown file"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(posted_review | jq -c '[.comments[].line]')" = "[2]" ]
  posted_summary | grep -qF '`app.py:10`: Not in diff'
  posted_summary | grep -qF '`old.txt:1`: Deleted file'
  posted_summary | grep -qF '`other.py:1`: Unknown file'
  posted_summary | grep -qF '1 inline finding(s)'
}

@test "no findings: no review is posted, and the summary says so" {
  write_review '[]' "No problems found."
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls /reviews)" -eq 0 ]
  posted_summary | grep -qF '0 inline finding(s)'
  posted_summary | grep -qF 'No problems found.'
  ! posted_summary | grep -qF 'could not be attached'
}

@test "only this action's open threads from earlier runs are resolved" {
  set_threads \
    "$(thread "$(as_finding Old)" '[]' false Bot T_ours_open)" \
    "$(thread "$(as_finding Old)" '[]' true Bot T_ours_resolved)" \
    "$(thread 'A reviewer comment' '[]' false User T_person)"
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls resolveReviewThread)" -eq 1 ]
  grep -qx "id=T_ours_open" "$(calls_with resolveReviewThread)"
}

@test "a person's thread containing a copied marker isn't resolved" {
  set_threads "$(thread "$(as_finding Mine)" '[]' false User T_forged)"
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls resolveReviewThread)" -eq 0 ]
}

@test "a thread from an earlier run that someone has replied to is left open" {
  set_threads \
    "$(thread "$(as_finding Old)" "[$(reply alice MEMBER 'I disagree')]" false Bot T_replied)" \
    "$(thread "$(as_finding Old)" '[]' false Bot T_no_reply)"
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls resolveReviewThread)" -eq 1 ]
  grep -qx "id=T_no_reply" "$(calls_with resolveReviewThread)"
}

@test "earlier threads are resolved before the new review is posted" {
  set_threads "$(thread "$(as_finding Old)" '[]' false)"
  write_review '[{"path":"app.py","line":2,"body":"New"}]'
  run bash "$ACTION_DIR/post.sh"
  resolve=$(basename "$(calls_with resolveReviewThread)")
  review=$(basename "$(calls_with /reviews)")
  [[ "$resolve" < "$review" ]]
}

@test "a thread the token can't resolve is marked as superseded instead" {
  export GH_FAIL_RESOLVE=1
  set_threads "$(thread "$(as_finding 'Old finding')" '[]' false)"
  write_review '[{"path":"app.py","line":2,"body":"New"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  grep -qx "repos/org/repo/pulls/comments/901" "$(calls_with pulls/comments/)"
  edited=$(stdin_of pulls/comments/)
  [[ "$edited" == "**Superseded** by the review of \`abcdef1\`."* ]]
  [[ "$edited" == *"<!-- claude-review-superseded -->"* ]]
  [[ "$edited" == *"$(as_finding 'Old finding')" ]]
  [[ "$output" == *"::notice::Marked 1 earlier finding(s) as superseded"* ]]
  [[ "$output" != *"::warning::"* ]]
  [ "$(count_calls /reviews)" -eq 1 ]
}

@test "a thread that is resolved isn't also marked as superseded" {
  set_threads "$(thread "$(as_finding Old)" '[]' false)"
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(count_calls resolveReviewThread)" -eq 1 ]
  [ -z "$(calls_with pulls/comments/)" ]
}

@test "a finding already marked as superseded is left alone" {
  export GH_FAIL_RESOLVE=1
  marked=$'**Superseded** by ...\n<!-- claude-review-superseded -->\n\n'"$(as_finding Old)"
  set_threads "$(thread "$marked" '[]' false)"
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls resolveReviewThread)" -eq 0 ]
  [ -z "$(calls_with pulls/comments/)" ]
}

@test "no GitHub query is made for threads: post.sh reads the saved file" {
  set_threads "$(thread "$(as_finding Old)" '[]' false)"
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ -z "$(calls_with reviewThreads)" ]
}

@test "the first run posts the summary comment, with its marker" {
  write_review '[]' "All good."
  run bash "$ACTION_DIR/post.sh"
  [ "$(count_calls --body-file)" -eq 1 ]
  [ "$(count_calls DELETE)" -eq 0 ]
  posted_summary | head -n 1 | grep -qxF '<!-- claude-review-summary -->'
  posted_summary | grep -qF 'of abcdef1'
}

@test "a later run posts a new summary at the bottom, then deletes the previous one" {
  export GH_ISSUE_COMMENTS_JSON='[{"id":111,"user":{"type":"User"},"body":"A person"},{"id":222,"user":{"type":"Bot"},"body":"<!-- claude-review-summary -->\nOld summary"}]'
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(count_calls --body-file)" -eq 1 ]
  [ "$(count_calls DELETE)" -eq 1 ]
  grep -qx "repos/org/repo/issues/comments/222" "$(calls_with DELETE)"
  posted=$(basename "$(calls_with --body-file)")
  deleted=$(basename "$(calls_with DELETE)")
  [[ "$posted" < "$deleted" ]]
}

@test "a person's comment containing the marker isn't deleted" {
  export GH_ISSUE_COMMENTS_JSON='[{"id":111,"user":{"type":"User"},"body":"Quoting <!-- claude-review-summary -->"}]'
  write_review '[]'
  run bash "$ACTION_DIR/post.sh"
  [ "$(count_calls DELETE)" -eq 0 ]
  [ "$(count_calls --body-file)" -eq 1 ]
}

@test "a file name with a space can be commented on" {
  write_review '[{"path":"my notes.txt","line":1,"body":"Spaces"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(posted_review | jq -c '.comments[0] | {path, line}')" = '{"path":"my notes.txt","line":1}' ]
}

@test "a file name git quotes can be commented on" {
  write_review '[{"path":"café.py","line":1,"body":"Accent"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [ "$(posted_review | jq -r '.comments[0].path')" = "café.py" ]
}

@test "if GitHub rejects the review, every finding goes in the summary" {
  export GH_FAIL_REVIEW=1
  write_review '[{"path":"app.py","line":2,"body":"First"},{"path":"app.py","line":10,"body":"Not in diff"}]'
  run bash "$ACTION_DIR/post.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::GitHub rejected the review"* ]]
  posted_summary | grep -qF '0 inline finding(s)'
  posted_summary | grep -qxF -- '- `app.py:2`: First'
  posted_summary | grep -qF '`app.py:10`: Not in diff'
}
