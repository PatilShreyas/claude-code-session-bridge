#!/usr/bin/env bash
# tests/test-connect-peer.sh — Tests for scripts/connect-peer.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
CONNECT_PEER="$PLUGIN_DIR/scripts/connect-peer.sh"

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

echo "=== test-connect-peer.sh ==="
echo "  sender=$SENDER_ID  target=$TARGET_ID"

# --- Test 1: Ping sent to peer inbox ---
echo ""
echo "Test 1: connect-peer sends a ping message to the target's inbox"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$CONNECT_PEER" "$TARGET_ID")

assert_contains "output says Connected" "Connected" "$OUTPUT"
assert_contains "output contains peer project name" "project-b" "$OUTPUT"

# Check that a ping message landed in the target's inbox
PING_FILE=$(find "$BRIDGE_DIR/sessions/$TARGET_ID/inbox" -name "msg-*.json" -print | head -1)
if [ -n "$PING_FILE" ]; then
  PING_TYPE=$(jq -r '.type' "$PING_FILE")
  PING_FROM=$(jq -r '.from' "$PING_FILE")
  assert_eq "ping type is ping" "ping" "$PING_TYPE"
  assert_eq "ping from is sender" "$SENDER_ID" "$PING_FROM"
else
  echo "  FAIL: no ping message found in target inbox"; FAIL=$((FAIL + 1))
  echo "  FAIL: no ping message found in target inbox (from check)"; FAIL=$((FAIL + 1))
fi

# --- Test 2: Non-existent peer fails ---
echo ""
echo "Test 2: Connecting to non-existent peer fails with error"
if OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$CONNECT_PEER" "nonexistent" 2>&1); then
  echo "  FAIL: should have exited non-zero"; FAIL=$((FAIL + 1))
else
  assert_contains "error mentions session not found" "not found" "$OUTPUT"
fi

print_results
