#!/usr/bin/env bash
# tests/test-check-inbox.sh — Tests for scripts/check-inbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CHECK_INBOX="$PLUGIN_DIR/scripts/check-inbox.sh"

# Set up isolated temp dirs for testing
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

# Register two sessions
SENDER_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
TARGET_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-check-inbox.sh ==="
echo "  sender=$SENDER_ID  target=$TARGET_ID"

# --- Test 1: Empty inbox returns continue true with no systemMessage ---
echo ""
echo "Test 1: Empty inbox returns continue true with no systemMessage"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$CHECK_INBOX")
CONTINUE=$(echo "$OUTPUT" | jq -r '.continue')
HAS_SYSTEM_MSG=$(echo "$OUTPUT" | jq 'has("systemMessage")')
assert_eq "continue is true" "true" "$CONTINUE"
assert_eq "no systemMessage key" "false" "$HAS_SYSTEM_MSG"

# --- Test 2: One pending query returns systemMessage with expected content ---
echo ""
echo "Test 2: One pending query returns systemMessage with CLAUDE BRIDGE header, peer name, content, instruction"
MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" "query" "What APIs do you expose?")

OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$CHECK_INBOX")
CONTINUE=$(echo "$OUTPUT" | jq -r '.continue')
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')

assert_eq "continue is true" "true" "$CONTINUE"
assert_contains "has CLAUDE BRIDGE header" "CLAUDE BRIDGE" "$SYSTEM_MSG"
assert_contains "has peer project name" "project-a" "$SYSTEM_MSG"
assert_contains "has message content" "What APIs do you expose?" "$SYSTEM_MSG"
assert_contains "has send-message instruction" "send-message.sh" "$SYSTEM_MSG"

# --- Test 3: Message marked as read after check ---
echo ""
echo "Test 3: Message marked as read after check"
MSG_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$MSG_ID.json"
MSG_STATUS=$(jq -r '.status' "$MSG_FILE")
assert_eq "message status is read" "read" "$MSG_STATUS"

# --- Test 4: Heartbeat updated ---
echo ""
echo "Test 4: Heartbeat updated after check-inbox"
# Set heartbeat to an old value
MANIFEST="$BRIDGE_DIR/sessions/$TARGET_ID/manifest.json"
OLD_HB="2020-01-01T00:00:00Z"
TMP=$(mktemp "$BRIDGE_DIR/sessions/$TARGET_ID/manifest.XXXXXX")
jq --arg hb "$OLD_HB" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

# Verify old value is set
CURRENT_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
assert_eq "heartbeat set to old value" "$OLD_HB" "$CURRENT_HB"

# Run check-inbox (no pending messages, so output is just continue:true)
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$CHECK_INBOX")

# check-inbox.sh does NOT update heartbeat (watcher handles that)
# Verify heartbeat is unchanged
UPDATED_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
if [ "$UPDATED_HB" = "$OLD_HB" ]; then
  echo "  PASS: heartbeat correctly left unchanged by check-inbox"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat was modified (should be unchanged)"; FAIL=$((FAIL + 1))
fi

# --- Test 5: --summary-only mode ---
echo ""
echo "Test 5: --summary-only mode contains session ID, send-message instruction, peer name"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$CHECK_INBOX" --summary-only)
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')

assert_contains "summary has session ID" "$TARGET_ID" "$SYSTEM_MSG"
assert_contains "summary has send-message instruction" "send-message.sh" "$SYSTEM_MSG"
assert_contains "summary has peer project name" "project-a" "$SYSTEM_MSG"

# --- Test 6: check-inbox does not clean up stale sessions (watcher handles that) ---
echo ""
echo "Test 6: check-inbox leaves stale sessions alone (cleanup is watcher's job)"
STALE_ID="stale1"
STALE_DIR="$BRIDGE_DIR/sessions/$STALE_ID"
mkdir -p "$STALE_DIR/inbox" "$STALE_DIR/outbox"
cat > "$STALE_DIR/manifest.json" <<EOF
{
  "sessionId": "$STALE_ID",
  "projectName": "stale-project",
  "projectPath": "/tmp/stale",
  "startedAt": "2020-01-01T00:00:00Z",
  "lastHeartbeat": "2020-01-01T00:00:00Z",
  "status": "active",
  "capabilities": ["query"]
}
EOF

# Run check-inbox
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$CHECK_INBOX")

# Stale session should still exist (check-inbox doesn't clean up)
if [ -d "$STALE_DIR" ]; then
  echo "  PASS: stale session correctly left alone by check-inbox"; PASS=$((PASS + 1))
else
  echo "  FAIL: stale session was unexpectedly removed"; FAIL=$((FAIL + 1))
fi

print_results
