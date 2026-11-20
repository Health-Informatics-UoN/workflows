#!/usr/bin/env bash
# This script posts the findings in $RUNNER_TEMP/review.json to the PR:
#   1. It processes the findings from earlier runs that have no replies. If the token
#      has permission, it resolves them. If not, it marks them as superseded.
#   2. It posts the findings as one review, so all findings make one notification.
#   3. It posts a new summary at the bottom of the PR and deletes the earlier summaries.
# The summary shows the findings that are not on a diff line, so no finding is lost.
#
# Environment (action.yml sets these values):
#   REPO        the owner/name of the repository, for example org/repo
#   PR_NUMBER   the PR number
#   HEAD_SHA    the PR commit that Claude reviewed. The comments attach to this commit.
#   GH_TOKEN    the token that gh uses. It needs pull-requests: write.
#   RUNNER_TEMP the folder with review.json (from review.sh) and threads.json (the
#               review threads of the PR, from fetch-discussed.sh)
# The current directory is the checkout. It contains the diff in .pr-review/pr.diff.
set -euo pipefail

out="$RUNNER_TEMP/review.json"
threads_file="$RUNNER_TEMP/threads.json"
commentable_file="$RUNNER_TEMP/commentable.json"
diff=".pr-review/pr.diff"

# Hidden HTML markers identify the comments of this action on later runs.
finding_marker="<!-- claude-review-finding -->"
summary_marker="<!-- claude-review-summary -->"
superseded_marker="<!-- claude-review-superseded -->"

# --- Find the lines that can have a comment ------------------------------------------
#
# GitHub accepts a review comment only on a line in the PR diff (an added line or a
# context line near it). One comment on a different line makes GitHub reject the full
# review. Thus, the script checks each finding first. An example diff:
#
#   +++ b/app.py      <- the file name, after "+++ b/"
#   @@ -1,3 +1,4 @@   <- a "hunk": +1 means it starts at new line 1
#    import os        <- a context line: new line 1
#   +import sys       <- an added line: new line 2
#   -import re        <- a removed line: not in the new file
#
# For each line that can have a comment, awk prints "file<TAB>line<TAB>hunk". A comment
# on a range of lines must start and end in the same hunk.
#
# In a hunk, a removed line "-- x" shows as "--- x", and an added line "++ x" shows as
# "+++ x". Thus, awk reads "+++" as a file name only before the first hunk of a file.
#
# Git changes some names on the "+++" line, and awk reverses the changes:
#   - If a name has a space, Git adds a TAB at the end:  +++ b/my notes.txt<TAB>
#   - Git quotes a name with other unusual characters and writes them as backslash
#     codes:  +++ "b/caf\303\251.py"  for café.py
# LC_ALL=C makes awk use bytes, so the codes become the correct bytes in all awk types.
#
# jq changes the lines into one object: {"path": {"line": hunk}}, for example
# {"app.py": {"1": "1", "21": "2"}}. The object goes into a file for --slurpfile, not a
# variable, because Linux limits one command-line argument to 128 KiB.
LC_ALL=C awk '
  # Change a quoted name from the diff back into the real name: remove the quotes and
  # change each backslash code into its character: \NNN (octal byte), \t, \n. A
  # backslash before a different character becomes that character. The names after
  # the extra spaces are local variables, as is usual in awk.
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

  # "+++ /dev/null" is a deleted file: no lines for comments, so keep the name empty.
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

  # Context (space) and added (+) lines are in the new file. Removed (-) lines are not.
  in_hunk && file != "" && /^[ +]/ { print file "\t" line "\t" hunk; line++ }
' "$diff" | jq -Rn 'reduce (inputs | split("\t")) as [$path, $line, $hunk] ({}; .[$path][$line] = $hunk)' \
  > "$commentable_file"

# --- Sort the findings ----------------------------------------------------------------
#
# comments:   findings on a diff line, in the format of the GitHub reviews API
# unanchored: all other findings. The summary shows these findings.
# A start_line makes a multi-line comment only if the range is in order and in one
# hunk. If not, the script removes start_line and comments on the last line only.
# "side": "RIGHT" means the new version of the file.
split=$(jq --slurpfile commentable "$commentable_file" --arg marker "$finding_marker" '
  # The hunk that contains a line, or null if the line is not in the diff.
  # --slurpfile gives the file contents as a list, so the object is $commentable[0].
  def hunk_of($path; $line): $commentable[0][$path][($line | tostring)];

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
# The default token cannot resolve threads ("Resource not accessible by integration"),
# and this action does not ask for more permission. Then the script adds a superseded
# note to the top of the bot comment, and people resolve the thread. The script does
# not change a thread with a reply, because it is a conversation between people.
# The filter keeps open threads without replies that a bot started with our marker and
# that are not superseded. Anyone can copy the marker, so the bot check is important.
# threads.json is from before the review. A person can reply during the review, so
# the loop gets the state of each thread again just before it changes the thread.
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

  # Skip the thread if it now has a reply or is resolved. If the check fails, skip the
  # thread too: the new findings are more important.
  # shellcheck disable=SC2016
  now=$(gh api graphql -F id="$id" -f query='
    query($id: ID!) { node(id: $id) { ... on PullRequestReviewThread {
      isResolved comments(first: 1) { totalCount } } } }' \
    --jq '.data.node | "\(.isResolved) \(.comments.totalCount)"') \
    || { echo "::warning::Could not check review thread $id"; continue; }
  [ "$now" = "false 1" ] || continue

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
# "event": "COMMENT" does not approve or request changes. If GitHub rejects the review,
# the summary gets all findings (without the marker), so no finding is lost.
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
# A new summary at the bottom tells people that the review ran. An edited summary stays
# far up in the PR, where people do not look, and nobody gets a notification.
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

# Old summaries. The bot check keeps comments from people that quote the marker.
previous=$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.type == \"Bot\" and (.body | contains(\"$summary_marker\"))) | .id")

# Post the new summary first, so the PR always has a summary if a step fails. Send the
# body on stdin, not as an argument: a long body can exceed the 128 KiB argument limit.
printf '%s' "$body" | gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file -

for id in $previous; do
  gh api -X DELETE "repos/${REPO}/issues/comments/${id}" > /dev/null \
    || echo "::warning::Could not delete the previous summary comment $id"
done
