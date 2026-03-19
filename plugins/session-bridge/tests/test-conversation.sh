#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
CONV_CREATE="$PLUGIN_DIR/scripts/conversation-create.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

# Setup: create a project
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "test-proj" > /dev/null

echo "=== test-conversation.sh ==="
echo ""
echo "--- conversation-create tests ---"

# Test 1: Creates conversation file
CONV_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "test-proj" "sess-a" "sess-b" "Bug in auth flow")
assert_not_empty "returns conversation ID" "$CONV_ID"
CONV_FILE="$BRIDGE_DIR/projects/test-proj/conversations/$CONV_ID.json"
assert_file_exists "conversation file created" "$CONV_FILE"

# Test 2: Conversation has correct fields
assert_json_field "conversationId set" "$CONV_FILE" '.conversationId' "$CONV_ID"
assert_json_field "topic set" "$CONV_FILE" '.topic' "Bug in auth flow"
assert_json_field "initiator set" "$CONV_FILE" '.initiator' "sess-a"
assert_json_field "responder set" "$CONV_FILE" '.responder' "sess-b"
assert_json_field "status is open" "$CONV_FILE" '.status' "open"
assert_json_field "parentConversation is null" "$CONV_FILE" '.parentConversation' "null"
assert_json_field "resolvedAt is null" "$CONV_FILE" '.resolvedAt' "null"
assert_json_field "resolution is null" "$CONV_FILE" '.resolution' "null"

# Test 3: Parent conversation
CHILD_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "test-proj" "sess-b" "sess-c" "Root cause in auth" --parent "$CONV_ID")
CHILD_FILE="$BRIDGE_DIR/projects/test-proj/conversations/$CHILD_ID.json"
assert_json_field "parent set" "$CHILD_FILE" '.parentConversation' "$CONV_ID"
assert_json_field "child topic" "$CHILD_FILE" '.topic' "Root cause in auth"

# Test 4: Multiple conversations coexist
CONV2_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "test-proj" "sess-a" "sess-c" "Logging cleanup")
assert_eq "different IDs" "true" "$([ "$CONV_ID" != "$CONV2_ID" ] && echo true || echo false)"

# Test 5: Fails on nonexistent project
if BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "no-such-project" "a" "b" "topic" 2>/dev/null; then
  echo "  FAIL: should error on nonexistent project"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent project"; PASS=$((PASS + 1))
fi

echo ""
echo "--- conversation-update tests ---"

CONV_UPDATE="$PLUGIN_DIR/scripts/conversation-update.sh"

# Test U1: Update status to waiting
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "$CONV_ID" "waiting"
assert_json_field "status changed to waiting" "$CONV_FILE" '.status' "waiting"

# Test U2: Update status back to open
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "$CONV_ID" "open"
assert_json_field "status changed to open" "$CONV_FILE" '.status' "open"

# Test U3: Resolve with resolution text
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "$CONV_ID" "resolved" --resolution "Fixed JWT validation"
assert_json_field "status is resolved" "$CONV_FILE" '.status' "resolved"
assert_json_field "resolution set" "$CONV_FILE" '.resolution' "Fixed JWT validation"
RESOLVED_AT=$(jq -r '.resolvedAt' "$CONV_FILE")
assert_eq "resolvedAt not null" "true" "$([ "$RESOLVED_AT" != "null" ] && echo true || echo false)"

# Test U4: Resolve without resolution text
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "$CHILD_ID" "resolved"
assert_json_field "child resolved" "$CHILD_FILE" '.status' "resolved"
assert_json_field "child resolvedAt set" "$CHILD_FILE" '.resolvedAt | length > 0' "true"

# Test U5: Fails on nonexistent conversation
if BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "conv-nonexistent" "open" 2>/dev/null; then
  echo "  FAIL: should error on nonexistent conversation"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent conversation"; PASS=$((PASS + 1))
fi

print_results
