#!/usr/bin/env bash
# Posts the findings in $RUNNER_TEMP/review.json to the PR:
#   1. Deals with the findings from earlier runs that nobody has replied to: resolves
#      them if the token is allowed to, or marks them as superseded if not.
#   2. Posts the findings as one review, so there is one notification per run.
#   3. Posts a new summary comment at the bottom of the PR, and deletes the previous one.
# Findings GitHub won't attach to a line (not in the diff) are listed in the summary
# instead, so none are lost.
#
# Environment (set by action.yml):
#   REPO        owner/name of the repository, for example org/repo
#   PR_NUMBER   the PR number
#   HEAD_SHA    the PR commit that was reviewed; comments are attached to it
#   GH_TOKEN    token gh uses; needs pull-requests: write
#   RUNNER_TEMP folder holding review.json from review.sh, and threads.json (the PR's
#               review threads) from fetch-discussed.sh
# The current directory is the checkout, which holds the diff in .pr-review/pr.diff.
set -euo pipefail  # Stop on any error, unset variable or failed command in a pipe.

out="$RUNNER_TEMP/review.json"
threads_file="$RUNNER_TEMP/threads.json"
diff=".pr-review/pr.diff"

# Hidden markers that identify this action's comments on later runs. They're HTML
# comments, so GitHub doesn't show them, but they stay in the comment text.
finding_marker="<!-- claude-review-finding -->"
summary_marker="<!-- claude-review-summary -->"
superseded_marker="<!-- claude-review-superseded -->"

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
# Git writes some file names differently on the "+++" line:
#   - a name with a space gets a TAB added at the end:  +++ b/my notes.txt<TAB>
#   - a name with other unusual characters is quoted, with those characters written as
#     backslash codes:  +++ "b/caf\303\251.py"  for café.py
# The awk program undoes both, so the name matches the one Claude gives.
# LC_ALL=C makes awk work in bytes, so the codes become the right bytes in any awk.
#
# jq then turns those lines into one JSON object: {"path": {"line": hunk number}},
# for example {"app.py": {"1": "1", "2": "1", "21": "2"}}.
commentable=$(LC_ALL=C awk '
  # Turns a quoted name from the diff back into the real name: removes the quotes,
  # and turns each backslash code into its character: \NNN (an octal byte value),
  # \t (TAB), \n (new line), or a backslash followed by any other character, which
  # is that character.
  function unquote(s,    out, i, c, next_c) {
    s = substr(s, 2, length(s) - 2)
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c != "\\") { out = out c; continue }
      next_c = substr(s, i + 1, 1)
      if (next_c ~ /[0-7]/) {
        out = out sprintf("%c", substr(s, i + 1, 1) * 64 + substr(s, i + 2, 1) * 8 + substr(s, i + 3, 1))
        i += 3
      } else {
        out = out (next_c == "t" ? "\t" : next_c == "n" ? "\n" : next_c)
        i++
      }
    }
    return out
  }

  # A new file in the diff: forget the previous file, and wait for its header.
  /^diff --git / { file = ""; in_hunk = 0; next }

  # The new file name, from "+++ b/path". A deleted file has "+++ /dev/null" and
  # nothing to comment on, so its name is left empty.
  !in_hunk && /^\+\+\+ / {
    path = substr($0, 5)
    if (path == "/dev/null") { file = ""; next }
    sub(/\t$/, "", path)                                 # the TAB after a name with a space
    if (substr(path, 1, 1) == "\"") path = unquote(path)  # a quoted name
    file = substr(path, 3)                               # remove the "b/"
    next
  }

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
# Each comment gets the hidden marker, so the next run can find it.
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

# --- 1. Earlier findings nobody has replied to ---------------------------------------
#
# Each run reviews the whole PR again, so this run's findings replace the earlier ones.
# The earlier ones are resolved if the token is allowed to. The default workflow token
# isn't (GitHub answers "Resource not accessible by integration"), and this action
# doesn't ask for more permission. In that case the finding is marked as superseded
# instead: a note is added to the top of the bot's own comment, which the token can
# edit. People then resolve those threads. A finding already marked is skipped.
# A thread with a reply is a conversation between people, so it's left alone.
#
# The review threads were fetched once by fetch-discussed.sh, before Claude ran, and
# saved to $RUNNER_TEMP/threads.json. This filter keeps the open threads with one
# comment (no replies), started by a bot account with our marker, and not yet marked
# as superseded, and prints each as one line of JSON. Checking for a bot matters
# because anyone can copy the marker into a comment of their own; this way a person's
# comment is never changed.
threads=$(jq -r --arg finding "$finding_marker" --arg superseded "$superseded_marker" '
  .data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isResolved | not)
  | select(.comments.totalCount == 1)
  | select(.comments.nodes[0].author.__typename == "Bot")
  | select(.comments.nodes[0].body | contains($finding))
  | select(.comments.nodes[0].body | contains($superseded) | not)
  | {id, comment: .comments.nodes[0].databaseId, body: .comments.nodes[0].body}
  | tojson
' "$threads_file")

superseded=0
while IFS= read -r thread; do
  [ -n "$thread" ] || continue
  id=$(jq -r '.id' <<< "$thread")

  # shellcheck disable=SC2016
  if gh api graphql -F id="$id" -f query='
       mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }' \
       > /dev/null 2>&1; then
    continue
  fi

  # Not allowed to resolve it: add the superseded note to the top of the comment.
  comment=$(jq -r '.comment' <<< "$thread")
  if jq -r --arg sha "${HEAD_SHA:0:7}" --arg marker "$superseded_marker" \
       '"**Superseded** by the review of `\($sha)`. This finding is from an earlier review and may no longer apply. Resolve this thread when you have checked it.\n\($marker)\n\n" + .body' \
       <<< "$thread" \
     | gh api -X PATCH "repos/${REPO}/pulls/comments/${comment}" -F body=@- > /dev/null; then
    superseded=$((superseded + 1))
  else
    echo "::warning::Could not resolve or mark review thread $id"
  fi
done <<< "$threads"

if [ "$superseded" -gt 0 ]; then
  echo "::notice::Marked $superseded earlier finding(s) as superseded; the token can't resolve review threads."
fi

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

# --- 3. Post the summary at the bottom, and delete the previous one -------------------
#
# There's one summary on the PR at a time. Each run posts a new one, so it appears at
# the bottom of the conversation and notifies people that the review ran, then deletes
# the previous one. (Editing the previous one instead would leave the latest review
# far up the PR, where nobody looks, with no notification.)
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

# Find the summaries from earlier runs: comments by a bot account that contain the
# marker. Checking it's a bot stops a person's comment that quotes the marker from
# being deleted. --paginate reads every page of comments.
previous=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.type == \"Bot\" and (.body | contains(\"$summary_marker\"))) | .id")

# Post the new summary first, so the PR is never left without one if a step fails.
# The body is passed on stdin ("-"), so its text is never treated as shell code.
printf '%s' "$body" | gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file -

for id in $previous; do
  gh api -X DELETE "repos/${REPO}/issues/comments/${id}" > /dev/null \
    || echo "::warning::Could not delete the previous summary comment $id"
done
