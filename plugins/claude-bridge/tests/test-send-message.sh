#!/usr/bin/env bash
# tests/test-send-message.sh — Tests for scripts/send-message.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"

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

echo "=== test-send-message.sh ==="
echo "  sender=$SENDER_ID  target=$TARGET_ID"

# --- Test 1: Send a query message ---
echo ""
echo "Test 1: Send a query message, verify inbox and outbox"
MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" "query" "What APIs do you expose?")

INBOX_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$MSG_ID.json"
OUTBOX_FILE="$BRIDGE_DIR/sessions/$SENDER_ID/outbox/$MSG_ID.json"

assert_file_exists "message in target inbox" "$INBOX_FILE"
assert_file_exists "message in sender outbox" "$OUTBOX_FILE"

MSG=$(cat "$INBOX_FILE")
assert_eq "from is sender" "$SENDER_ID" "$(echo "$MSG" | jq -r '.from')"
assert_eq "to is target" "$TARGET_ID" "$(echo "$MSG" | jq -r '.to')"
assert_eq "type is query" "query" "$(echo "$MSG" | jq -r '.type')"
assert_eq "content matches" "What APIs do you expose?" "$(echo "$MSG" | jq -r '.content')"
assert_eq "status is pending" "pending" "$(echo "$MSG" | jq -r '.status')"
assert_eq "inReplyTo is null" "null" "$(echo "$MSG" | jq -r '.inReplyTo')"
assert_eq "fromProject is project-a" "project-a" "$(echo "$MSG" | jq -r '.metadata.fromProject')"

# --- Test 2: Send a response with inReplyTo ---
echo ""
echo "Test 2: Send a response with inReplyTo"
REPLY_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$TARGET_ID" bash "$SEND_MSG" "$SENDER_ID" "response" "Here are the APIs..." "$MSG_ID")

REPLY_FILE="$BRIDGE_DIR/sessions/$SENDER_ID/inbox/$REPLY_ID.json"
assert_file_exists "reply in sender inbox" "$REPLY_FILE"

REPLY=$(cat "$REPLY_FILE")
assert_eq "reply type is response" "response" "$(echo "$REPLY" | jq -r '.type')"
assert_eq "inReplyTo references original" "$MSG_ID" "$(echo "$REPLY" | jq -r '.inReplyTo')"

# --- Test 3: Send a ping ---
echo ""
echo "Test 3: Send a ping message"
PING_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" "ping" "are you there?")

PING_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$PING_ID.json"
assert_file_exists "ping in target inbox" "$PING_FILE"

PING=$(cat "$PING_FILE")
assert_eq "ping type is ping" "ping" "$(echo "$PING" | jq -r '.type')"

print_results
