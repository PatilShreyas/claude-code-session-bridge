#!/usr/bin/env bash
# tests/test-list-peers.sh — Tests for scripts/list-peers.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
LIST_PEERS="$PLUGIN_DIR/scripts/list-peers.sh"

# Set up isolated temp dirs for testing
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-list-peers.sh ==="

# --- Test 1: No sessions ---
echo ""
echo "Test 1: No sessions directory outputs 'No active bridge sessions'"
BRIDGE_DIR="$TEST_TMPDIR/empty-bridge"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS")
assert_contains "shows no sessions message" "No active bridge sessions" "$OUTPUT"

# --- Test 2: One active session ---
echo ""
echo "Test 2: One active session is listed with project name and active status"
BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-alpha"
mkdir -p "$PROJECT_A"

SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS")

assert_contains "output contains session ID" "$SESSION_ID" "$OUTPUT"
assert_contains "output contains project name" "project-alpha" "$OUTPUT"
assert_contains "output contains active status" "active" "$OUTPUT"

# --- Test 3: Stale session shows stale status ---
echo ""
echo "Test 3: Stale session (heartbeat 2020-01-01) shows stale status"
STALE_ID="old123"
STALE_DIR="$BRIDGE_DIR/sessions/$STALE_ID"
mkdir -p "$STALE_DIR/inbox" "$STALE_DIR/outbox"
cat > "$STALE_DIR/manifest.json" <<EOF
{
  "sessionId": "$STALE_ID",
  "projectName": "old-project",
  "projectPath": "/tmp/old",
  "startedAt": "2020-01-01T00:00:00Z",
  "lastHeartbeat": "2020-01-01T00:00:00Z",
  "status": "active",
  "capabilities": ["query"]
}
EOF

OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS")
assert_contains "output contains stale session ID" "$STALE_ID" "$OUTPUT"
assert_contains "output contains stale status" "stale" "$OUTPUT"
assert_contains "output contains stale project name" "old-project" "$OUTPUT"

print_results
