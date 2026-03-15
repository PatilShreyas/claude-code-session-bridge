#!/usr/bin/env bash
# tests/test-heartbeat.sh — Tests for scripts/heartbeat.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
HEARTBEAT="$PLUGIN_DIR/scripts/heartbeat.sh"

# Set up isolated temp dirs for testing
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
mkdir -p "$PROJECT_A"

# Register a session
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")

echo "=== test-heartbeat.sh ==="
echo "  session=$SESSION_ID"

MANIFEST="$BRIDGE_DIR/sessions/$SESSION_ID/manifest.json"

# --- Test 1: Heartbeat via BRIDGE_SESSION_ID env var ---
echo ""
echo "Test 1: Heartbeat via BRIDGE_SESSION_ID env var updates lastHeartbeat"

# Set heartbeat to an old value
OLD_HB="2020-01-01T00:00:00Z"
TMP=$(mktemp "$BRIDGE_DIR/sessions/$SESSION_ID/manifest.XXXXXX")
jq --arg hb "$OLD_HB" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

CURRENT_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
assert_eq "heartbeat set to old value" "$OLD_HB" "$CURRENT_HB"

# Run heartbeat with env var
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" bash "$HEARTBEAT"

UPDATED_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
if [ "$UPDATED_HB" != "$OLD_HB" ]; then
  echo "  PASS: heartbeat updated via env var"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat not updated (still $OLD_HB)"; FAIL=$((FAIL + 1))
fi

# --- Test 2: Heartbeat via bridge-session file fallback ---
echo ""
echo "Test 2: Heartbeat via bridge-session file fallback updates lastHeartbeat"

# Set heartbeat to old value again
OLD_HB="2020-01-01T00:00:00Z"
TMP=$(mktemp "$BRIDGE_DIR/sessions/$SESSION_ID/manifest.XXXXXX")
jq --arg hb "$OLD_HB" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

CURRENT_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
assert_eq "heartbeat set to old value again" "$OLD_HB" "$CURRENT_HB"

# Run heartbeat without BRIDGE_SESSION_ID, relying on bridge-session file
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$HEARTBEAT"

UPDATED_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
if [ "$UPDATED_HB" != "$OLD_HB" ]; then
  echo "  PASS: heartbeat updated via bridge-session file"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat not updated via fallback (still $OLD_HB)"; FAIL=$((FAIL + 1))
fi

print_results
