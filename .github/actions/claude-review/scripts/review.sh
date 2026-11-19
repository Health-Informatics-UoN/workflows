#!/usr/bin/env bash
# Runs Claude Code on the checked-out PR and saves its findings.
#
# Claude runs read-only. It can read and search files in the checkout (the current
# directory), and it cannot do other tasks. It has no shell, no network tools and no
# GitHub token. An earlier step got the PR details and the diff into .pr-review/.
# Thus, Claude does not need these items.
#
# Writes the JSON output of Claude Code to $RUNNER_TEMP/review.json. post.sh posts it.
# If the review does not complete, the step fails. Thus, a broken review shows as a
# failed check, not as "no findings".
#
# Environment (set by action.yml):
#   ANTHROPIC_API_KEY   the key that Claude Code uses to call the Claude API
#   MODEL, MAX_TURNS, EFFORT  from the action inputs
#   GITHUB_ACTION_PATH  the action folder: prompt, standards, schema and Claude Code
#   RUNNER_TEMP         a temporary folder outside the checkout. Claude cannot read it.
set -euo pipefail

out="$RUNNER_TEMP/review.json"

# If the secret of the caller does not exist, GitHub gives an empty string, not an
# error. This occurs also if the workflow marks the secret as required. Then Claude
# Code shows only "Not logged in". Thus, examine the key here and show the real problem.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "::error::ANTHROPIC_API_KEY is empty. Add it as an Actions secret (Settings > Secrets and variables > Actions) and pass it to the workflow under secrets:."
  exit 1
fi

# jq -c puts the schema on one line, and also checks that schema.json is valid JSON.
schema=$(jq -c . "$GITHUB_ACTION_PATH/prompt/schema.json")

prompt="$(cat "$GITHUB_ACTION_PATH/prompt/prompt.md")

$(cat "$GITHUB_ACTION_PATH/prompt/standards.md")"

# The limits on Claude. Each limit is a command-line flag below. If you remove one,
# the tests in tests/review.bats fail.
#
# --setting-sources user: ignore all .claude/settings.json files in the repo. Thus,
#   they cannot change the tools that Claude can use, and they cannot add hooks.
# --strict-mcp-config with no --mcp-config: start no MCP servers. Thus, a .mcp.json
#   in the repo cannot run a command on the runner, where the API key is visible.
# --tools: Claude has only Read, Grep and Glob. The flag removes other tools (Bash,
#   WebFetch and other tools). It does not only refuse them.
# --allowedTools: Read, Grep and Glob are permitted only in the checkout ("./**").
#   In print mode (-p), Claude Code refuses all items that are not permitted. This
#   includes symlinks that point outside the checkout.
# --disallowedTools: a second barrier. It denies Read, Grep and Glob on the locations
#   that contain secrets, for example /proc/self/environ, which contains the API key.
#   It also denies $RUNNER_TEMP, which is outside the checkout. It contains
#   threads.json, with comments from any person, which Claude must not read.
#   "//" is an absolute path and "~" is the home folder.
allow="Read(./**),Grep(./**),Glob(./**)"
# The "~" is for Claude Code, not for the shell, so the shell must not expand it.
# shellcheck disable=SC2088
# RUNNER_TEMP starts with /, so "/${RUNNER_TEMP}" starts with // (an absolute path).
denied_paths=("//proc/**" "//sys/**" "//etc/**" "//root/**" "//tmp/**" "//run/**" \
  "//var/**" "~/.*/**" "/${RUNNER_TEMP}/**")
deny=""
for tool in Read Grep Glob; do
  for denied_path in "${denied_paths[@]}"; do
    deny+="${tool}(${denied_path}),"
  done
done
deny=${deny%,}  # Remove the last comma.

# --json-schema: Claude Code returns the answer as structured_output.
# "|| true": a failed run also prints JSON that contains the error. The checks below
# examine it and show a clearer message.
"$GITHUB_ACTION_PATH/node_modules/.bin/claude" -p "$prompt" \
  --model "$MODEL" \
  --max-turns "$MAX_TURNS" \
  --effort "$EFFORT" \
  --setting-sources user \
  --strict-mcp-config \
  --tools "Read,Grep,Glob" \
  --output-format json \
  --json-schema "$schema" \
  --allowedTools "$allow" \
  --disallowedTools "$deny" \
  > "$out" || true

# For some failures (for example, no credit), Claude Code prints plain text, not JSON.
# Show that text as the error. If not, a jq error that is not clear occurs later.
if ! jq -e 'type == "object"' "$out" > /dev/null 2>&1; then
  echo "::error::Claude review did not complete"
  cat "$out"
  exit 1
fi

jq '{is_error, num_turns, total_cost_usd, permission_denials}' "$out"

# The review is complete only if there is no error and Claude returned findings in the
# shape of the schema. For example, if Claude uses all turns, there is no
# structured_output.
if [ "$(jq -r '.is_error' "$out")" != "false" ] \
   || [ "$(jq -r '.structured_output | type' "$out")" != "object" ]; then
  echo "::error::Claude review did not complete"
  jq -r '.result // empty' "$out"
  exit 1
fi
