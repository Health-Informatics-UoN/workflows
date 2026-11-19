#!/usr/bin/env bash
# Posts the findings in $RUNNER_TEMP/review.json to the PR:
#   1. Resolves the review threads from earlier runs that nobody has replied to, so
#      only the current findings are open (the base branch may require all threads
#      resolved before merging).
#   2. Posts the findings as one review, so there is one notification per run.
#   3. Updates one summary comment in place, or creates it on the first run.
# Findings GitHub won't attach to a line (not in the diff) are listed in the summary
# instead, so none are lost.
#
# Environment (set by action.yml):
#   REPO        owner/name of the repository, for example org/repo
#   PR_NUMBER   the PR number
#   HEAD_SHA    the PR commit that was reviewed; comments are attached to it
#   GH_TOKEN    token gh uses; needs pull-requests: write
#   RUNNER_TEMP folder holding review.json from review.sh
# The current directory is the checkout, which holds the diff in .pr-review/pr.diff.
set -euo pipefail  # Stop on any error, unset variable or failed command in a pipe.

out="$RUNNER_TEMP/review.json"
diff=".pr-review/pr.diff"

# Hidden markers that identify this action's comments on later runs. They're HTML
# comments, so GitHub doesn't show them, but they stay in the comment text.
finding_marker="<!-- claude-review-finding -->"
summary_marker="<!-- claude-review-summary -->"

# --- Which lines can a comment attach to? -------------------------------------------
#
# GitHub only accepts a review comment on a line that appears in the PR diff: an added
# line or an unchanged line shown around it (a "context" line). A comment on any other
# line makes GitHub reject the whole review, so each finding is checked first.
#
# A diff looks like this:
#
#   diff --git a/app.py b/app.py        <- a new file starts
#   --- a/app.py
#   +++ b/app.py                        <- the file name, after "+++ b/"
#   @@ -1,3 +1,4 @@                     <- a "hunk": +1 means it starts at new line 1
#    import os                          <- context line: new line 1
#   +import sys                         <- added line: new line 2
#   -import re                          <- removed line: not in the new file
#
# The awk program reads the diff line by line and prints "file<TAB>line<TAB>hunk" for
# each line that can be commented on. The hunk number is printed too, because a comment
# on a range of lines must start and end in the same hunk.
#
# Inside a hunk, a removed line "-- x" appears as "--- x", and an added line "++ x"
# as "+++ x", like file headers. So "+++" is only read as a file name before the first
# hunk of a file (when in_hunk is 0).
#
# jq then turns those lines into one JSON object: {"path": {"line": hunk number}},
# for example {"app.py": {"1": "1", "2": "1", "21": "2"}}.
commentable=$(awk '
  # A new file in the diff: forget the previous file, and wait for its header.
  /^diff --git / { file = ""; in_hunk = 0; next }

  # The new file name, from "+++ b/path". A deleted file has "+++ /dev/null" and
  # nothing to comment on, so its name is left empty.
  !in_hunk && /^\+\+\+ / { file = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }

  # A hunk header, "@@ -a,b +c,d @@": count the hunk, and start counting new lines at c.
  /^@@ / {
    in_hunk = 1; hunk++
    match($0, /\+[0-9]+/); line = substr($0, RSTART + 1, RLENGTH - 1)
    next
  }

  # A context line (starts with a space) or an added line (starts with +) is in the
  # new file, so it can be commented on. Removed lines (start with -) are skipped and
  # not counted, as they are not in the new file.
  in_hunk && file != "" && /^[ +]/ { print file "\t" line "\t" hunk; line++ }
' "$diff" | jq -Rn 'reduce (inputs | split("\t")) as [$p, $l, $h] ({}; .[$p][$l] = $h)')

# --- Sort the findings ----------------------------------------------------------------
#
# Splits the findings into:
#   comments:   ones on a line in the diff, in the shape the GitHub reviews API expects
#   unanchored: the rest, which go in the summary instead
# Each comment gets the hidden marker, so the next run can find and resolve it.
# A finding with a start_line becomes a multi-line comment, but only if the range is
# the right way round and within one hunk; otherwise the start_line is dropped and the
# comment goes on the last line only.
# "side": "RIGHT" means the new version of the file, not the old one.
split=$(jq --argjson ok "$commentable" --arg marker "$finding_marker" '
  # The hunk a line is in, or null if the line is not in the diff.
  def hunk($p; $l): $ok[$p][($l | tostring)];

  .structured_output.findings
  | map(. as $f | hunk($f.path; $f.line) as $h
      | if $h == null then {unanchored: $f}
        else {comment: ({path, line, side: "RIGHT", body: (.body + "\n\n" + $marker)}
          + (if .start_line != null and .start_line < .line
                and hunk($f.path; $f.start_line) == $h
             then {start_line, start_side: "RIGHT"} else {} end))}
        end)
  | {comments: map(.comment // empty), unanchored: map(.unanchored // empty)}
' "$out")

# --- 1. Resolve earlier findings nobody has replied to -----------------------------------
#
# Each run reviews the whole PR again, so the earlier findings are replaced by this
# run's. Resolving the old threads means only the current findings are left open.
# A thread with a reply is a conversation between people, so it's left for them to
# resolve. Checks the first 100 threads, which covers all but very long-running PRs.
#
# Review threads are only available through the GraphQL API, not the REST API.
# The query gets each thread's id, whether it's resolved, how many comments it has,
# and the text of its first comment (where the marker is). The --jq filter keeps the
# open threads with one comment (no replies) that start with our marker.
# REPO is "owner/name": ${REPO%/*} is the owner and ${REPO#*/} the name.
#
# The $ names in the queries are GraphQL variables, not shell ones, so they're in
# single quotes on purpose (shellcheck would otherwise warn about it).
# shellcheck disable=SC2016
threads=$(gh api graphql \
  -f owner="${REPO%/*}" -f name="${REPO#*/}" -F number="$PR_NUMBER" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes { id isResolved comments(first: 1) { totalCount nodes { body } } }
          }
        }
      }
    }' \
  --jq ".data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved | not)
        | select(.comments.totalCount == 1)
        | select(.comments.nodes[0].body | contains(\"$finding_marker\"))
        | .id")

# Resolve each one. If GitHub refuses (for example, the token isn't allowed to), log a
# warning and carry on: the new findings are more important.
for id in $threads; do
  # shellcheck disable=SC2016
  gh api graphql -F id="$id" -f query='
    mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }' \
    > /dev/null || echo "::warning::Could not resolve review thread $id"
done

# --- 2. Post the findings as one review ----------------------------------------------
#
# One review with all the comments, rather than one comment per finding, so people get
# one notification. "event": "COMMENT" posts it without approving or requesting changes.
# commit_id ties the comments to the commit that was reviewed.
#
# If GitHub still rejects the review, move every finding into the summary, without
# the hidden marker, so none are lost.
count=$(jq '.comments | length' <<< "$split")
if [ "$count" -gt 0 ]; then
  if ! jq --arg sha "$HEAD_SHA" \
         '{commit_id: $sha, event: "COMMENT", body: "Claude review findings. See the summary comment.", comments}' \
         <<< "$split" \
       | gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --input - > /dev/null; then
    echo "::warning::GitHub rejected the review; listing all findings in the summary."
    split=$(jq '{comments: [], unanchored: (.unanchored + (.comments | map({path, line, body: (.body | split("\n\n<!--")[0])})))}' <<< "$split")
    count=0
  fi
fi

# --- 3. Update the summary comment ---------------------------------------------------
#
# The summary is one comment that each run edits, rather than a new comment per run.
# It holds: the hidden marker, the commit reviewed and number of inline findings,
# Claude's summary, and any findings that couldn't be attached to a line.
body=$(
  printf '%s\n' "$summary_marker"
  printf '**Claude review** of %s: %s inline finding(s).\n\n' "${HEAD_SHA:0:7}" "$count"
  jq -r '.structured_output.summary' "$out"
  jq -r '.unanchored
    | if length > 0 then
        "\n**Findings that could not be attached to a diff line:**\n"
        + (map("- `\(.path):\(.line)`: \(.body)") | join("\n"))
      else empty end' <<< "$split"
)

# Find the summary from an earlier run: a comment by a bot account that contains the
# marker. Checking it's a bot stops a person's comment that quotes the marker from
# being treated as the summary. --paginate reads every page of comments; sed keeps the
# first match.
existing=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.type == \"Bot\" and (.body | contains(\"$summary_marker\"))) | .id" \
  | sed -n 1p)

# Edit it if found (edits don't notify anyone); otherwise post a new one. The body is
# passed on stdin ("@-" and "-"), so its text is never treated as shell code.
if [ -n "$existing" ]; then
  printf '%s' "$body" | gh api -X PATCH "repos/${REPO}/issues/comments/${existing}" -F body=@- > /dev/null
else
  printf '%s' "$body" | gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file -
fi
