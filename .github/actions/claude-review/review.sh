#!/usr/bin/env bash
# Runs Claude Code over the checked-out PR and saves its findings.
#
# Claude runs read-only: it can read and search files in the checkout (the current
# directory), and nothing else. It has no shell, no network tools and no GitHub token.
# The PR details and diff were fetched by an earlier step into .pr-review/, so Claude
# doesn't need any of those.
#
# Writes Claude Code's JSON output to $RUNNER_TEMP/review.json, for post.sh to post.
# Fails the step if the review didn't complete, so a broken review shows as a failed
# check instead of looking like "no findings".
#
# Environment (set by action.yml):
#   ANTHROPIC_API_KEY   key Claude Code uses to call the Claude API
#   MODEL, MAX_TURNS    from the action inputs
#   GITHUB_ACTION_PATH  this action's folder: prompt, standards, schema and Claude Code
#   RUNNER_TEMP         temporary folder outside the checkout, so Claude can't read it
set -euo pipefail  # Stop on any error, unset variable or failed command in a pipe.

out="$RUNNER_TEMP/review.json"

# The JSON schema Claude's answer must follow (findings + summary), squashed onto one
# line to pass as an argument.
schema=$(jq -c . "$GITHUB_ACTION_PATH/schema.json")

# The prompt is the instructions (prompt.md) followed by the review standards
# (standards.md), separated by a blank line.
prompt="$(cat "$GITHUB_ACTION_PATH/prompt.md")

$(cat "$GITHUB_ACTION_PATH/standards.md")"

# How Claude is restricted. Each restriction is a command-line flag below; the tests in
# tests/review.bats fail if one is removed.
#
# --setting-sources user: ignore any .claude/settings.json in the repo, so it
#   can't change which tools Claude may use or add hooks.
# --strict-mcp-config with no --mcp-config: start no MCP servers, so a .mcp.json
#   in the repo can't run a command on the runner, where it would see the API key.
# --tools: Claude has only Read, Grep and Glob. Other tools (Bash, WebFetch and so on)
#   are removed, not only refused.
# --allowedTools: Read, Grep and Glob are allowed only inside the checkout ("./**").
#   In print mode (-p) anything not allowed is refused, including symlinks that point
#   outside the checkout.
# --disallowedTools: a backstop that denies reading the places that hold secrets,
#   such as /proc/self/environ, which contains the API key. "//" means an absolute
#   path and "~" the home folder.
allow="Read(./**),Grep(./**),Glob(./**)"
deny="Read(//proc/**),Read(//sys/**),Read(//etc/**),Read(//root/**),Read(//tmp/**),Read(//run/**),Read(//var/**),Read(~/.*/**)"

# -p: print mode. Claude Code runs the prompt without a person present, prints the
#   result and exits.
# --max-turns: stop after this many back-and-forth steps, to limit cost.
# --output-format json: print one JSON object with the result, cost and errors.
# --json-schema: the answer must match the schema; it's returned as structured_output.
#
# Claude Code's exit status isn't checked here ("|| true"), because a failed run still
# prints JSON with the error in it, which is checked below with a clearer message.
"$GITHUB_ACTION_PATH/node_modules/.bin/claude" -p "$prompt" \
  --model "$MODEL" \
  --max-turns "$MAX_TURNS" \
  --setting-sources user \
  --strict-mcp-config \
  --tools "Read,Grep,Glob" \
  --output-format json \
  --json-schema "$schema" \
  --allowedTools "$allow" \
  --disallowedTools "$deny" \
  > "$out" || true

# Claude Code prints plain text, not JSON, for some failures (for example, no credit).
# Show that text as the error instead of failing later with a confusing jq error.
if ! jq -e 'type == "object"' "$out" > /dev/null 2>&1; then
  echo "::error::Claude review did not complete"
  cat "$out"
  exit 1
fi

# Log how the run went: errors, turns used, cost, and any tool use that was refused.
jq '{is_error, num_turns, total_cost_usd, permission_denials}' "$out"

# The review completed only if there's no error and Claude returned findings in the
# schema's shape. Running out of turns, for example, gives no structured_output.
# "::error::" makes GitHub Actions show the message as an error on the run.
if [ "$(jq -r '.is_error' "$out")" != "false" ] \
   || [ "$(jq -r '.structured_output | type' "$out")" != "object" ]; then
  echo "::error::Claude review did not complete"
  jq -r '.result // empty' "$out"
  exit 1
fi
