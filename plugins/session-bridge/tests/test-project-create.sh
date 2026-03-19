#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-project-create.sh ==="

# Test 1: Creates project directory structure
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "my-project")
assert_eq "outputs project name" "my-project" "$OUTPUT"
assert_dir_exists "project dir created" "$BRIDGE_DIR/projects/my-project"
assert_dir_exists "conversations dir created" "$BRIDGE_DIR/projects/my-project/conversations"
assert_dir_exists "sessions dir created" "$BRIDGE_DIR/projects/my-project/sessions"
assert_file_exists "project.json created" "$BRIDGE_DIR/projects/my-project/project.json"

# Test 2: project.json has correct fields
assert_json_field "projectId set" "$BRIDGE_DIR/projects/my-project/project.json" '.projectId' "my-project"
assert_json_field "name set" "$BRIDGE_DIR/projects/my-project/project.json" '.name' "my-project"
assert_json_field "topology is empty object" "$BRIDGE_DIR/projects/my-project/project.json" '.topology | length' "0"
assert_json_field "createdBy is null" "$BRIDGE_DIR/projects/my-project/project.json" '.createdBy' "null"

# Test 3: Fails if project already exists
if BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "my-project" 2>/dev/null; then
  echo "  FAIL: should error on duplicate project"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on duplicate project"; PASS=$((PASS + 1))
fi

# Test 4: Creates multiple independent projects
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "project-two" > /dev/null
assert_dir_exists "second project created" "$BRIDGE_DIR/projects/project-two"
assert_dir_exists "first project still exists" "$BRIDGE_DIR/projects/my-project"

# Test 5: Project name with hyphens and numbers
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "plextura-suite-v2" > /dev/null
assert_dir_exists "hyphenated name works" "$BRIDGE_DIR/projects/plextura-suite-v2"

print_results
