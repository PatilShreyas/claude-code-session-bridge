#!/usr/bin/env bash
# tests/test-cleanup.sh — Tests for scripts/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"

# Set up isolated temp dirs for testing
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

# Register two sessions
SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-cleanup.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B"

# Have session B send a ping to session A (so A knows B is a peer)
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" ping "hello" > /dev/null

# --- Test 1: Session dir removed ---
echo ""
echo "Test 1: Cleanup removes session directory"
SESSION_A_DIR="$BRIDGE_DIR/sessions/$SESSION_A"
assert_dir_exists "session dir exists before cleanup" "$SESSION_A_DIR"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLEANUP"

if [ ! -d "$SESSION_A_DIR" ]; then
  echo "  PASS: session dir removed after cleanup"; PASS=$((PASS + 1))
else
  echo "  FAIL: session dir still exists after cleanup"; FAIL=$((FAIL + 1))
fi

# --- Test 2: bridge-session file removed ---
echo ""
echo "Test 2: Cleanup removes bridge-session pointer file"
if [ ! -f "$PROJECT_A/.claude/bridge-session" ]; then
  echo "  PASS: bridge-session file removed"; PASS=$((PASS + 1))
else
  echo "  FAIL: bridge-session file still exists"; FAIL=$((FAIL + 1))
fi

# --- Test 3: Peer notified with session-ended ---
echo ""
echo "Test 3: Peer (session B) received session-ended notification"
ENDED_FILE=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox" -name "msg-*.json" -exec jq -r 'select(.type == "session-ended") | input_filename' {} \; 2>/dev/null | head -1 || true)

# Alternative approach: search for session-ended messages directly
if [ -z "$ENDED_FILE" ]; then
  for F in "$BRIDGE_DIR/sessions/$SESSION_B/inbox"/msg-*.json; do
    [ -f "$F" ] || continue
    FTYPE=$(jq -r '.type' "$F")
    if [ "$FTYPE" = "session-ended" ]; then
      ENDED_FILE="$F"
      break
    fi
  done
fi

if [ -n "$ENDED_FILE" ] && [ -f "$ENDED_FILE" ]; then
  ENDED_TYPE=$(jq -r '.type' "$ENDED_FILE")
  ENDED_FROM=$(jq -r '.from' "$ENDED_FILE")
  assert_eq "notification type is session-ended" "session-ended" "$ENDED_TYPE"
  assert_eq "notification from is session A" "$SESSION_A" "$ENDED_FROM"
else
  echo "  FAIL: no session-ended message found in peer inbox"; FAIL=$((FAIL + 1))
  echo "  FAIL: no session-ended message found (from check)"; FAIL=$((FAIL + 1))
fi

print_results
