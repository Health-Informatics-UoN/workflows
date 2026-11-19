#!/usr/bin/env bats
# Checks that the reusable workflow's input defaults match the action's.
#
# The workflow passes its inputs to the action, so the workflow's defaults are what
# callers get. Both define defaults, though, and if they drift apart, using the action
# directly behaves differently from using the workflow.

load test_helper

WORKFLOW="$ACTION_DIR/../../workflows/claude-review.yml"

# Prints the default of input $1 in YAML file $2, without quotes. Finds the line
# "<input>:" and prints the value of the first "default:" after it.
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
