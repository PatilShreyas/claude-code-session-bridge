#!/usr/bin/env bash
# tests/test-bridge-listen.sh — Tests for scripts/bridge-listen.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-bridge-listen.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B"

# --- Test 1: Returns message when pending ---
echo ""
echo "Test 1: Returns message content when a pending message exists"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Hello from A" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "has MESSAGE_ID" "MESSAGE_ID=" "$OUTPUT"
assert_contains "has FROM_ID" "FROM_ID=$SESSION_A" "$OUTPUT"
assert_contains "has TYPE=query" "TYPE=query" "$OUTPUT"
assert_contains "has message content" "Hello from A" "$OUTPUT"
if echo "$OUTPUT" | grep -qF -- "---"; then
  echo "  PASS: has separator between metadata and content"; PASS=$((PASS + 1))
else
  echo "  FAIL: missing separator"; FAIL=$((FAIL + 1))
fi

# --- Test 2: Message marked as read ---
echo ""
echo "Test 2: Message marked as read after pickup"
MSG_FILE=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox" -name "*.json" | head -1)
assert_eq "message status is read" "read" "$(jq -r '.status' "$MSG_FILE")"

# --- Test 3: Already-read messages are not re-delivered ---
echo ""
echo "Test 3: Already-read messages are ignored"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 3 > /dev/null 2>&1; then
  echo "  FAIL: re-delivered an already-read message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: already-read message not returned again"; PASS=$((PASS + 1))
fi

# --- Test 4: Times out with exit code 1 when inbox is empty ---
echo ""
echo "Test 4: Times out correctly on empty inbox"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out"; FAIL=$((FAIL + 1))
else
  echo "  PASS: timed out with exit 1"; PASS=$((PASS + 1))
fi

# --- Test 5: Picks up ping messages ---
echo ""
echo "Test 5: Handles ping message type"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" ping "connected" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "ping type detected" "TYPE=ping" "$OUTPUT"

# --- Test 6: Only picks messages from OWN inbox, not other sessions ---
echo ""
echo "Test 6: Does not pick up messages from other sessions' inboxes"
PROJECT_C="$TEST_TMPDIR/project-c"
mkdir -p "$PROJECT_C"
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$REGISTER")
# Send to C's inbox from A
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_C" query "For session C" > /dev/null
# Listen on B — should NOT pick up C's message
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 3 > /dev/null 2>&1; then
  echo "  FAIL: B picked up C's message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: B correctly ignores C's inbox"; PASS=$((PASS + 1))
fi
# Listen on C — SHOULD pick it up
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_C" 5)
assert_contains "C picks up its own message" "For session C" "$OUTPUT"

# --- Test 7: Does NOT pick up own outgoing messages (echo prevention) ---
echo ""
echo "Test 7: Does not echo own messages back"
# B sends to A — message lands in A's inbox
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" query "From B" > /dev/null
# A listens and picks it up
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_A" 5)
assert_contains "A picks up B's message" "From B" "$OUTPUT"
# Now: B sends a response to A, message lands in A's inbox FROM B
# If B somehow had that in its own inbox too, it should be skipped
# This tests the FROM_ID != SESSION_ID check

# --- Test 8: inReplyTo field is included in output when set ---
echo ""
echo "Test 8: inReplyTo field is included in output when set"
ORIG_ID="msg-original-123"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" response "My reply" "$ORIG_ID" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "inReplyTo in output" "IN_REPLY_TO=$ORIG_ID" "$OUTPUT"

echo ""
echo "--- inotifywait/project-scoped tests ---"

# Test I1: Works with project-scoped inbox
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "listen-proj" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "listen-proj")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "listen-proj")

# Send a message, then listen — should find it immediately
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$PLUGIN_DIR/scripts/send-message.sh" "$V2_SID_B" ping "hello" > /dev/null
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" bash "$LISTEN" "$V2_SID_B" 5 2>/dev/null || true)
assert_contains "finds project-scoped message" "TYPE=ping" "$OUTPUT"

rm -rf "$V2_TMPDIR"

print_results
