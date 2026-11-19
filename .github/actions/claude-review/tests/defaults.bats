#!/usr/bin/env bats
# These tests make sure that the input defaults of the reusable workflow are the same
# as the input defaults of the action.
#
# The workflow gives its inputs to the action, so callers get the workflow defaults.
# But the workflow and the action each define defaults. If the two sets of defaults
# become different, the action behaves differently when you use it directly.

load test_helper

WORKFLOW="$ACTION_DIR/../../workflows/claude-review.yml"

# Shows the default of input $1 in YAML file $2, without quotes. It finds the line
# "<input>:" and shows the value of the first "default:" after that line.
default_of() {
  awk -v name="$1" '
    $1 == name ":" { found = 1; next }
    found && $1 == "default:" { gsub(/"/, "", $2); print $2; exit }
  ' "$2"
}

@test "the workflow and the action have the same max-lines default" {
  [ -n "$(default_of max-lines "$ACTION_DIR/action.yml")" ]
  [ "$(default_of max-lines "$WORKFLOW")" = "$(default_of max-lines "$ACTION_DIR/action.yml")" ]
}

@test "the workflow and the action have the same max-turns default" {
  [ -n "$(default_of max-turns "$ACTION_DIR/action.yml")" ]
  [ "$(default_of max-turns "$WORKFLOW")" = "$(default_of max-turns "$ACTION_DIR/action.yml")" ]
}

@test "the workflow and the action have the same model default" {
  [ -n "$(default_of model "$ACTION_DIR/action.yml")" ]
  [ "$(default_of model "$WORKFLOW")" = "$(default_of model "$ACTION_DIR/action.yml")" ]
}

@test "the defaults are 2000 lines and 25 turns" {
  [ "$(default_of max-lines "$ACTION_DIR/action.yml")" = "2000" ]
  [ "$(default_of max-turns "$ACTION_DIR/action.yml")" = "25" ]
}
