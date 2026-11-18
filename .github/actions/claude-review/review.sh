#!/usr/bin/env bash
# Runs Claude Code read-only over the checkout (the current directory) and writes
# its findings to $RUNNER_TEMP/review.json. Fails if the review didn't complete.
set -euo pipefail

out="$RUNNER_TEMP/review.json"
schema=$(jq -c . "$GITHUB_ACTION_PATH/schema.json")
prompt="$(cat "$GITHUB_ACTION_PATH/prompt.md")

$(cat "$GITHUB_ACTION_PATH/standards.md")"

# --setting-sources user: ignore any .claude/settings.json in the repo, so it
# can't change which tools Claude may use or add hooks.
# --strict-mcp-config with no --mcp-config: start no MCP servers, so a .mcp.json
# in the repo can't run a command on the runner, where it would see the API key.
# Read, Grep and Glob are allowed only inside the checkout; in print mode anything
# else is refused, including symlinks that point outside it. The deny list is a
# backstop for the places that hold secrets (/proc/self/environ has the API key).
allow="Read(./**),Grep(./**),Glob(./**)"
deny="Read(//proc/**),Read(//sys/**),Read(//etc/**),Read(//root/**),Read(//tmp/**),Read(//run/**),Read(//var/**),Read(~/.*/**)"

# Errors are reported from the JSON below, so don't stop on a non-zero exit here.
"$GITHUB_ACTION_PATH/node_modules/.bin/claude" -p "$prompt" \
  --model "$MODEL" \
  --max-turns "$MAX_TURNS" \
  --setting-sources user \
  --strict-mcp-config \
  --output-format json \
  --json-schema "$schema" \
  --allowedTools "$allow" \
  --disallowedTools "$deny" \
  > "$out" || true

jq '{is_error, num_turns, total_cost_usd, permission_denials}' "$out"
if [ "$(jq -r '.is_error' "$out")" != "false" ] \
   || [ "$(jq -r '.structured_output | type' "$out")" != "object" ]; then
  echo "::error::Claude review did not complete"
  jq -r '.result // empty' "$out"
  exit 1
fi
