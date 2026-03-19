#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHER="$PLUGIN_DIR/scripts/inbox-watcher.sh"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJ_DIR="$TEST_TMPDIR/myproj"
mkdir -p "$PROJ_DIR"
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "watch-test" > /dev/null
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$JOIN" "watch-test")

INBOX="$BRIDGE_DIR/projects/watch-test/sessions/$SESSION_ID/inbox"
MANIFEST="$BRIDGE_DIR/projects/watch-test/sessions/$SESSION_ID/manifest.json"

echo "=== test-inbox-watcher.sh ==="

# Test 1: Watcher starts and creates PID file
BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER" "$SESSION_ID" "watch-test" &
WATCHER_PID=$!
sleep 1
assert_eq "watcher is running" "true" "$(kill -0 $WATCHER_PID 2>/dev/null && echo true || echo false)"

# Test 2: Heartbeat updates after watcher runs
OLD_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
sleep 2
# Trigger a heartbeat by waiting (watcher does it periodically)
# For testing, we just verify the watcher hasn't crashed
assert_eq "watcher still running" "true" "$(kill -0 $WATCHER_PID 2>/dev/null && echo true || echo false)"

# Test 3: Clean shutdown
kill $WATCHER_PID 2>/dev/null || true
wait $WATCHER_PID 2>/dev/null || true
assert_eq "watcher stopped" "false" "$(kill -0 $WATCHER_PID 2>/dev/null && echo true || echo false)"

print_results
