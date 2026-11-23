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
# "<input>:" and shows the value of the first "default:" in the block of that input.
# The block ends at the next line with the same indent or less (the next input, or the
# end of inputs:). Then it shows nothing, so the [ -n ... ] checks find a missing default.
# Blank lines and comments do not end the block.
default_of() {
  awk -v name="$1" '
    function indent_of(line) { match(line, /^ */); return RLENGTH }
    !found && $1 == name ":" { found = 1; key_indent = indent_of($0); next }
    found && NF && $1 !~ /^#/ && indent_of($0) <= key_indent { exit }
    found && $1 == "default:" { gsub(/"/, "", $2); print $2; exit }
  ' "$2"
}

@test "default_of shows nothing for an input without a default" {
  yaml="$BATS_TEST_TMPDIR/inputs.yml"
  cat > "$yaml" <<'EOF'
inputs:
  model:
    description: No default here.
  # A comment at the indent of the inputs.
  max-turns:
    description: The next input.
    default: "25"
  effort:
    description: The last input, also without a default.
runs:
  default: not-an-input-default
EOF
  [ "$(default_of max-turns "$yaml")" = "25" ]
  [ -z "$(default_of model "$yaml")" ]
  [ -z "$(default_of effort "$yaml")" ]
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

@test "the workflow and the action have the same effort default" {
  [ -n "$(default_of effort "$ACTION_DIR/action.yml")" ]
  [ "$(default_of effort "$WORKFLOW")" = "$(default_of effort "$ACTION_DIR/action.yml")" ]
}

@test "the defaults are 2000 lines and 25 turns" {
  [ "$(default_of max-lines "$ACTION_DIR/action.yml")" = "2000" ]
  [ "$(default_of max-turns "$ACTION_DIR/action.yml")" = "25" ]
}
