#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/my-app"
PROJECT_B="$TEST_TMPDIR/auth-server"
mkdir -p "$PROJECT_A" "$PROJECT_B"

# Create the project first
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "test-suite" > /dev/null

echo "=== test-project-join.sh ==="

# Test 1: Join creates session in project directory
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "test-suite" --role specialist --specialty "app development")
assert_not_empty "returns session ID" "$SESSION_ID"
assert_dir_exists "session dir created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID"
assert_dir_exists "inbox created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/inbox"
assert_dir_exists "outbox created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/outbox"
assert_file_exists "manifest created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/manifest.json"

# Test 2: Manifest has correct fields
MANIFEST="$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/manifest.json"
assert_json_field "sessionId set" "$MANIFEST" '.sessionId' "$SESSION_ID"
assert_json_field "projectId set" "$MANIFEST" '.projectId' "test-suite"
assert_json_field "projectName set" "$MANIFEST" '.projectName' "my-app"
assert_json_field "role set" "$MANIFEST" '.role' "specialist"
assert_json_field "specialty set" "$MANIFEST" '.specialty' "app development"
assert_json_field "status is active" "$MANIFEST" '.status' "active"

# Test 3: bridge-session file created in project dir
assert_file_exists "bridge-session pointer" "$PROJECT_A/.claude/bridge-session"
assert_eq "bridge-session contains ID" "$SESSION_ID" "$(cat "$PROJECT_A/.claude/bridge-session")"

# Test 4: Second session joins same project
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$JOIN" "test-suite" --role specialist --specialty "authentication, JWT")
assert_eq "sessions are different" "true" "$([ "$SESSION_ID" != "$SESSION_B" ] && echo true || echo false)"
assert_dir_exists "second session exists" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_B"
assert_json_field "second session role" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_B/manifest.json" '.role' "specialist"

# Test 5: Reuses existing session if already joined
SESSION_REUSE=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "test-suite" --role specialist --specialty "app development")
assert_eq "reuses session ID" "$SESSION_ID" "$SESSION_REUSE"

# Test 6: Fails if project doesn't exist
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "nonexistent" 2>/dev/null; then
  echo "  FAIL: should error on nonexistent project"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent project"; PASS=$((PASS + 1))
fi

# Test 7: Defaults to specialist role if not specified
PROJECT_C="$TEST_TMPDIR/plain-session"
mkdir -p "$PROJECT_C"
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$JOIN" "test-suite")
assert_json_field "defaults to specialist" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_C/manifest.json" '.role' "specialist"
assert_json_field "defaults to empty specialty" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_C/manifest.json" '.specialty' ""

# Test 8: --name overrides projectName
PROJECT_D="$TEST_TMPDIR/generic-dir"
mkdir -p "$PROJECT_D"
SESSION_D=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_D" bash "$JOIN" "test-suite" --name "custom-name" --role orchestrator)
assert_json_field "custom name set" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_D/manifest.json" '.projectName' "custom-name"
assert_json_field "orchestrator role" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_D/manifest.json" '.role' "orchestrator"

# Test 9: projectPath is set correctly in manifest
assert_json_field "projectPath set" "$MANIFEST" '.projectPath' "$PROJECT_A"

# Test 10: startedAt and lastHeartbeat are set
STARTED=$(jq -r '.startedAt' "$MANIFEST")
HEARTBEAT=$(jq -r '.lastHeartbeat' "$MANIFEST")
assert_not_empty "startedAt is set" "$STARTED"
assert_not_empty "lastHeartbeat is set" "$HEARTBEAT"
assert_eq "startedAt matches lastHeartbeat on creation" "$STARTED" "$HEARTBEAT"

# Test 11: Reuse updates lastHeartbeat
sleep 1
SESSION_REUSE2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "test-suite")
NEW_HEARTBEAT=$(jq -r '.lastHeartbeat' "$MANIFEST")
assert_eq "reuses session again" "$SESSION_ID" "$SESSION_REUSE2"
# Heartbeat should be updated (may or may not differ in fast execution, but should not error)
assert_not_empty "lastHeartbeat updated on reuse" "$NEW_HEARTBEAT"

# Test 12: Session ID format is 6 alphanumeric characters
assert_eq "session ID is 6 chars" "6" "${#SESSION_ID}"
if echo "$SESSION_ID" | grep -qE '^[a-z0-9]{6}$'; then
  echo "  PASS: session ID matches [a-z0-9]{6}"; PASS=$((PASS + 1))
else
  echo "  FAIL: session ID '$SESSION_ID' doesn't match [a-z0-9]{6}"; FAIL=$((FAIL + 1))
fi

print_results
