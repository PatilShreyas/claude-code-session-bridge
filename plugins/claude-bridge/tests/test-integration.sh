#!/usr/bin/env bash
# tests/test-integration.sh — End-to-end test: two sessions communicate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$(dirname "$0")/test-helpers.sh"
TEST_BRIDGE_DIR=$(mktemp -d)
PROJECT_A=$(mktemp -d)
PROJECT_B=$(mktemp -d)
mkdir -p "$PROJECT_A/.claude" "$PROJECT_B/.claude"

cleanup() { rm -rf "$TEST_BRIDGE_DIR" "$PROJECT_A" "$PROJECT_B"; }
trap cleanup EXIT

echo "=== Integration Test: Two-Session Communication ==="

# Step 1: Register two sessions
echo "Step 1: Register sessions"
SESSION_A=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" \
  bash "$SCRIPT_DIR/scripts/register.sh")
SESSION_B=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" \
  bash "$SCRIPT_DIR/scripts/register.sh")
echo "  Session A: $SESSION_A"
echo "  Session B: $SESSION_B"
assert_eq "two different session IDs" "true" "$([ "$SESSION_A" != "$SESSION_B" ] && echo true || echo false)"

# Step 2: Session A connects to Session B
echo "Step 2: Connect A -> B"
BRIDGE_DIR="$TEST_BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" \
  bash "$SCRIPT_DIR/scripts/connect-peer.sh" "$SESSION_B"

# Step 3: Session B checks inbox (sees ping from A)
echo "Step 3: B checks inbox (sees ping)"
OUTPUT=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" \
  bash "$SCRIPT_DIR/scripts/check-inbox.sh")
SYS_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage // ""')
assert_contains "B sees ping from A" "ping" "$SYS_MSG"

# Step 4: Session A sends query to B
echo "Step 4: A sends query to B"
MSG_ID=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" \
  bash "$SCRIPT_DIR/scripts/send-message.sh" "$SESSION_B" query "What changed in the auth module?")

# Step 5: Session B checks inbox (sees query)
echo "Step 5: B checks inbox (sees query)"
OUTPUT=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" \
  bash "$SCRIPT_DIR/scripts/check-inbox.sh")
SYS_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage // ""')
assert_contains "B sees query from A" "What changed in the auth module?" "$SYS_MSG"
assert_contains "B gets reply instructions" "send-message.sh" "$SYS_MSG"

# Step 6: Session B responds
echo "Step 6: B responds to A"
REPLY_ID=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" \
  bash "$SCRIPT_DIR/scripts/send-message.sh" "$SESSION_A" response "auth.login() was renamed to auth.authenticate()" "$MSG_ID")

# Step 7: Session A checks inbox (sees response)
echo "Step 7: A checks inbox (sees response)"
OUTPUT=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" \
  bash "$SCRIPT_DIR/scripts/check-inbox.sh")
SYS_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage // ""')
assert_contains "A sees response from B" "auth.authenticate()" "$SYS_MSG"
assert_contains "A sees it's a response" "response" "$SYS_MSG"

# Step 8: List peers shows both
echo "Step 8: List peers"
OUTPUT=$(BRIDGE_DIR="$TEST_BRIDGE_DIR" bash "$SCRIPT_DIR/scripts/list-peers.sh")
assert_contains "lists session A" "$SESSION_A" "$OUTPUT"
assert_contains "lists session B" "$SESSION_B" "$OUTPUT"

# Step 9: Session A stops (cleanup)
echo "Step 9: A cleans up"
BRIDGE_DIR="$TEST_BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" \
  bash "$SCRIPT_DIR/scripts/cleanup.sh"

assert_eq "A's session dir removed" "false" "$([ -d "$TEST_BRIDGE_DIR/sessions/$SESSION_A" ] && echo true || echo false)"
assert_eq "A's bridge-session removed" "false" "$([ -f "$PROJECT_A/.claude/bridge-session" ] && echo true || echo false)"

# B should have a session-ended notice
ENDED_COUNT=$(find "$TEST_BRIDGE_DIR/sessions/$SESSION_B/inbox" -name "*.json" \
  -exec jq -r 'select(.type == "session-ended") | .id' {} \; 2>/dev/null | wc -l | tr -d ' ')
assert_eq "B notified of A's departure" "1" "$ENDED_COUNT"

print_results
