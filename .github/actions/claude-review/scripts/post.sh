#!/usr/bin/env bash
# This script posts the findings in $RUNNER_TEMP/review.json to the PR:
#   1. It processes the findings from earlier runs that have no replies. If the token
#      has permission, it resolves them. If not, it marks them as superseded.
#   2. It posts the findings as one review, so each run makes one notification.
#   3. It posts a new summary comment at the bottom of the PR and deletes the old one.
# GitHub does not attach a finding to a line that is not in the diff. The summary shows
# these findings, so no finding is lost.
#
# Environment (action.yml sets these values):
#   REPO        the owner/name of the repository, for example org/repo
#   PR_NUMBER   the PR number
#   HEAD_SHA    the PR commit that Claude reviewed. The comments attach to this commit.
#   GH_TOKEN    the token that gh uses. It needs pull-requests: write.
#   RUNNER_TEMP the folder that contains review.json from review.sh, and threads.json
#               (the review threads of the PR) from fetch-discussed.sh
# The current directory is the checkout. It contains the diff in .pr-review/pr.diff.
set -euo pipefail

out="$RUNNER_TEMP/review.json"
threads_file="$RUNNER_TEMP/threads.json"
diff=".pr-review/pr.diff"

# Hidden markers identify the comments of this action on later runs. They are HTML
# comments. GitHub does not show them, but they stay in the comment text.
finding_marker="<!-- claude-review-finding -->"
summary_marker="<!-- claude-review-summary -->"
superseded_marker="<!-- claude-review-superseded -->"

# --- Find the lines that can have a comment ------------------------------------------
#
# GitHub accepts a review comment only on a line in the PR diff. This is an added line
# or an unchanged line near it (a "context" line). If a comment is on a different line,
# GitHub rejects the full review. Thus, the script checks each finding first.
#
# This is an example of a diff:
#
#   diff --git a/app.py b/app.py        <- the start of a new file
#   --- a/app.py
#   +++ b/app.py                        <- the file name, after "+++ b/"
#   @@ -1,3 +1,4 @@                     <- a "hunk": +1 means it starts at new line 1
#    import os                          <- a context line: new line 1
#   +import sys                         <- an added line: new line 2
#   -import re                          <- a removed line: not in the new file
#
# The awk program reads the diff one line at a time. For each line that can have a
# comment, it prints "file<TAB>line<TAB>hunk". It also prints the hunk number, because
# a comment on a range of lines must start and end in the same hunk.
#
# In a hunk, a removed line "-- x" shows as "--- x", and an added line "++ x" shows as
# "+++ x". These are the same as file headers. Thus, the program reads "+++" as a file
# name only before the first hunk of a file (when in_hunk is 0).
#
# On the "+++" line, Git writes some file names in a different format:
#   - If a name has a space, Git adds a TAB at the end:  +++ b/my notes.txt<TAB>
#   - If a name has other unusual characters, Git puts it in quotes and writes those
#     characters as backslash codes:  +++ "b/caf\303\251.py"  for café.py
# The awk program reverses the two changes, so the name is the same as the Claude name.
# LC_ALL=C makes awk use bytes, so the codes become the correct bytes in all awk types.
#
# Then jq changes these lines into one JSON object: {"path": {"line": hunk number}},
# for example {"app.py": {"1": "1", "2": "1", "21": "2"}}.
commentable=$(LC_ALL=C awk '
  # This function changes a quoted name from the diff back into the real name. It
  # removes the quotes and changes each backslash code into its character: \NNN (an
  # octal byte value), \t (TAB), \n (new line). A backslash followed by a different
  # character becomes that character.
  # The names after the extra spaces are local variables, as is usual in awk.
  function unquote(quoted,    name, pos, char, next_char, code) {
    quoted = substr(quoted, 2, length(quoted) - 2)
    name = ""
    for (pos = 1; pos <= length(quoted); pos++) {
      char = substr(quoted, pos, 1)
      if (char != "\\") { name = name char; continue }
      next_char = substr(quoted, pos + 1, 1)
      if (next_char ~ /[0-7]/) {
        # Three octal digits give the value of one byte.
        code = substr(quoted, pos + 1, 1) * 64 + substr(quoted, pos + 2, 1) * 8 \
          + substr(quoted, pos + 3, 1)
        name = name sprintf("%c", code)
        pos += 3
      } else {
        name = name (next_char == "t" ? "\t" : next_char == "n" ? "\n" : next_char)
        pos++
      }
    }
    return name
  }

  # A new file starts: wait for its header.
  /^diff --git / { file = ""; in_hunk = 0; next }

  # The new file name comes from "+++ b/path". A deleted file has "+++ /dev/null" and
  # has no lines for comments, so the program keeps its name empty.
  !in_hunk && /^\+\+\+ / {
    path = substr($0, 5)
    if (path == "/dev/null") { file = ""; next }
    sub(/\t$/, "", path)
    if (substr(path, 1, 1) == "\"") path = unquote(path)
    file = substr(path, 3)                               # remove the "b/"
    next
  }

  # A hunk header, "@@ -a,b +c,d @@": add 1 to the hunk count. Count new lines from c.
  /^@@ / {
    in_hunk = 1; hunk++
    match($0, /\+[0-9]+/); line = substr($0, RSTART + 1, RLENGTH - 1)
    next
  }

  # Context lines (space) and added lines (+) are in the new file. Removed lines (-)
  # are not, so the program does not count them.
  in_hunk && file != "" && /^[ +]/ { print file "\t" line "\t" hunk; line++ }
' "$diff" | jq -Rn 'reduce (inputs | split("\t")) as [$path, $line, $hunk] ({}; .[$path][$line] = $hunk)')

# --- Sort the findings ----------------------------------------------------------------
#
# The script divides the findings into two groups:
#   comments:   findings on a line in the diff, in the format of the GitHub reviews API
#   unanchored: all other findings. The summary shows these findings.
# A finding with a start_line becomes a multi-line comment, but only if the range is in
# the correct order and in one hunk. If not, the script removes the start_line and puts
# the comment on the last line only.
# "side": "RIGHT" means the new version of the file, not the old version.
split=$(jq --argjson commentable "$commentable" --arg marker "$finding_marker" '
  # The hunk that contains a line, or null if the line is not in the diff.
  def hunk_of($path; $line): $commentable[$path][($line | tostring)];

  .structured_output.findings
  | map(. as $finding | hunk_of($finding.path; $finding.line) as $hunk
      | if $hunk == null then {unanchored: $finding}
        else {comment: ({path, line, side: "RIGHT", body: (.body + "\n\n" + $marker)}
          + (if .start_line != null and .start_line < .line
                and hunk_of($finding.path; $finding.start_line) == $hunk
             then {start_line, start_side: "RIGHT"} else {} end))}
        end)
  | {comments: map(.comment // empty), unanchored: map(.unanchored // empty)}
' "$out")

# --- 1. Earlier findings that have no replies ----------------------------------------
#
# Each run reviews the full PR again, so its findings replace the earlier findings.
# The default workflow token cannot resolve threads (GitHub answers "Resource not
# accessible by integration"), and this action does not ask for more permission. Then
# the script adds a superseded note to the top of the bot comment, which the token can
# edit, and people resolve the thread. A thread with a reply is a conversation between
# people, so the script does not change it.
#
# The filter keeps the open threads without replies that a bot started with our marker
# and that do not have the superseded mark. The bot check is important, because anyone
# can copy the marker into their own comment.
threads=$(jq -r --arg finding "$finding_marker" --arg superseded "$superseded_marker" '
  .[]
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

  # The token cannot resolve the thread, so mark the comment as superseded.
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
# "event": "COMMENT" does not approve the PR or request changes. If GitHub rejects the
# review after these checks, the script moves all findings into the summary without
# the hidden marker. Thus, no finding is lost.
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
# A new summary at the bottom tells people that the review ran. If the script edits the
# previous summary, the latest review stays far up in the PR, where people do not look,
# and nobody gets a notification.
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

# Find the summaries from earlier runs. The bot check makes sure that the script does
# not delete a comment from a person that quotes the marker.
previous=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.type == \"Bot\" and (.body | contains(\"$summary_marker\"))) | .id")

# Post the new summary first. Then, if a step fails, the PR always has a summary.
# The script sends the body on stdin ("-"), so the shell never runs its text as code.
printf '%s' "$body" | gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file -

for id in $previous; do
  gh api -X DELETE "repos/${REPO}/issues/comments/${id}" > /dev/null \
    || echo "::warning::Could not delete the previous summary comment $id"
done
