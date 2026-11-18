#!/usr/bin/env bash
# Posts each finding in $RUNNER_TEMP/review.json as an inline comment, then one
# summary comment. Findings GitHub won't attach to a line (not in the diff) are
# listed in the summary instead, so none are lost.
set -euo pipefail

out="$RUNNER_TEMP/review.json"
posted=0
unanchored=""

while IFS= read -r finding; do
  path=$(jq -r '.path' <<< "$finding")
  line=$(jq -r '.line' <<< "$finding")
  body=$(jq -r '.body' <<< "$finding")
  if printf '%s' "$body" | gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
       -f commit_id="$HEAD_SHA" -f path="$path" -F line="$line" -f side=RIGHT \
       -F body=@- > /dev/null; then
    posted=$((posted + 1))
  else
    unanchored="${unanchored}
- \`${path}:${line}\`: ${body}"
  fi
done < <(jq -c '.structured_output.findings[]' "$out")

summary=$(jq -r '.structured_output.summary' "$out")
{
  printf '**Claude review:** %s inline finding(s).\n\n%s\n' "$posted" "$summary"
  if [ -n "$unanchored" ]; then
    printf '\n**Findings that could not be attached to a diff line:**%s\n' "$unanchored"
  fi
} | gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file -
