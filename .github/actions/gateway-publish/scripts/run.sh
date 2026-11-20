#!/usr/bin/env bash
# Runs the gateway-publish CLI (this action's Python package) and copies its output to the
# job summary.
#
# Environment (set by action.yml):
#   COMMAND               validate or push
#   DATASET_DIR, SCHEMA   the dataset directory and, optionally, the LinkML schema
#   VERSION               the metadata version (required for push)
#   STATUS                DRAFT, ACTIVE or empty (gateway.yaml decides)
#   DRY_RUN, TRASER       "true" or "false"
#   TRASER_URL, GATEWAY_* read by the CLI itself; GATEWAY_APP_ID and GATEWAY_CLIENT_ID are
#                         secrets, so they are never put on the command line
#   GITHUB_ACTION_PATH    this action's directory
#   GITHUB_STEP_SUMMARY   the file that GitHub Actions shows as the job summary
set -euo pipefail

args=()
case "$COMMAND" in
  validate)
    args=(validate --dataset "$DATASET_DIR")
    if [ -n "$VERSION" ]; then args+=(--version "$VERSION"); fi
    if [ "$TRASER" = "true" ]; then args+=(--traser); fi
    ;;
  push)
    if [ -z "$VERSION" ]; then
      echo "::error::The version input is required for push"
      exit 1
    fi
    args=(push "$DATASET_DIR" --version "$VERSION")
    if [ -n "$STATUS" ]; then args+=(--status "$STATUS"); fi
    if [ "$DRY_RUN" = "true" ]; then args+=(--dry-run); fi
    if [ "$TRASER" != "true" ]; then args+=(--skip-traser); fi
    ;;
  *)
    echo "::error::Unknown command '$COMMAND' (expected validate or push)"
    exit 1
    ;;
esac
if [ -n "$SCHEMA" ]; then args+=(--schema "$SCHEMA"); fi

log=$(mktemp)
set +e
uv run --quiet --frozen --no-dev --project "$GITHUB_ACTION_PATH" gateway-publish "${args[@]}" 2>&1 | tee "$log"
result=${PIPESTATUS[0]}
set -e

{
  echo "### HDR UK Gateway: $COMMAND"
  echo
  echo '```'
  cat "$log"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

if [ "$result" -ne 0 ]; then
  echo "::error::gateway-publish $COMMAND failed; see the log above or the job summary"
fi
exit "$result"
