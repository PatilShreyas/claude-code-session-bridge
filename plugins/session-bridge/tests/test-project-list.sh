#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"
LIST="$PLUGIN_DIR/scripts/project-list.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-project-list.sh ==="

# Test 1: No projects
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "no projects message" "No projects" "$OUTPUT"

# Test 2: Lists created projects
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "project-alpha" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "project-beta" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "lists alpha" "project-alpha" "$OUTPUT"
assert_contains "lists beta" "project-beta" "$OUTPUT"

# Test 3: Shows session count (manually create session dir since project-join.sh may not exist yet)
mkdir -p "$BRIDGE_DIR/projects/project-alpha/sessions/test-session-1"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "shows session count" "1" "$OUTPUT"

# Test 4: Shows header
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "has PROJECT header" "PROJECT" "$OUTPUT"
assert_contains "has SESSIONS header" "SESSIONS" "$OUTPUT"
assert_contains "has CREATED header" "CREATED" "$OUTPUT"

# Test 5: Shows creation date from project.json
CREATED=$(jq -r '.createdAt' "$BRIDGE_DIR/projects/project-alpha/project.json")
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "shows creation date" "$CREATED" "$OUTPUT"

# Test 6: Multiple sessions counted correctly
mkdir -p "$BRIDGE_DIR/projects/project-alpha/sessions/test-session-2"
mkdir -p "$BRIDGE_DIR/projects/project-alpha/sessions/test-session-3"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "shows 3 sessions" "3" "$OUTPUT"

# Test 7: Project with zero sessions
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "beta has 0 sessions" "0" "$OUTPUT"

print_results
