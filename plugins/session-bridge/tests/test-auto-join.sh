#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
AUTO_JOIN="$PLUGIN_DIR/scripts/auto-join.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJ_DIR="$TEST_TMPDIR/my-app"
mkdir -p "$PROJ_DIR"

echo "=== test-auto-join.sh ==="

# Test 1: No bridge-role file — exits cleanly
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$AUTO_JOIN" 2>/dev/null)
assert_contains "no config exits clean" '"continue": true' "$OUTPUT"

# Test 2: Setup — join a project first to create bridge-role
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "auto-test" > /dev/null
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$JOIN" "auto-test" --role orchestrator --specialty "coordination")

# Verify bridge-role was created with project field
assert_file_exists "bridge-role exists" "$PROJ_DIR/.claude/bridge-role"
assert_json_field "bridge-role has project" "$PROJ_DIR/.claude/bridge-role" '.project' "auto-test"
assert_json_field "bridge-role has role" "$PROJ_DIR/.claude/bridge-role" '.role' "orchestrator"

# Test 3: Auto-join works — rejoins the project automatically
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$AUTO_JOIN" 2>/dev/null)
assert_contains "auto-join has system message" "BRIDGE AUTO-JOINED" "$OUTPUT"
assert_contains "auto-join shows project" "auto-test" "$OUTPUT"
assert_contains "auto-join shows role" "orchestrator" "$OUTPUT"
assert_contains "auto-join shows specialty" "coordination" "$OUTPUT"

# Test 4: Session is active after auto-join
MANIFEST="$BRIDGE_DIR/projects/auto-test/sessions/$SESSION_ID/manifest.json"
assert_file_exists "session manifest exists" "$MANIFEST"
assert_json_field "role is orchestrator" "$MANIFEST" '.role' "orchestrator"

# Test 5: Auto-join with nonexistent project exits cleanly
rm -rf "$BRIDGE_DIR/projects/auto-test"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$AUTO_JOIN" 2>/dev/null)
assert_contains "missing project exits clean" '"continue": true' "$OUTPUT"

# Test 6: Specialist auto-join
PROJ_B="$TEST_TMPDIR/auth-server"
mkdir -p "$PROJ_B"
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "auto-test-2" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_B" bash "$JOIN" "auto-test-2" --role specialist --specialty "auth, JWT" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_B" bash "$AUTO_JOIN" 2>/dev/null)
assert_contains "specialist auto-joins" "specialist" "$OUTPUT"
assert_contains "specialist shows specialty" "auth, JWT" "$OUTPUT"

print_results
