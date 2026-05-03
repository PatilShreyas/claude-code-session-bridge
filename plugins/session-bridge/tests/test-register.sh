#!/usr/bin/env bash
# tests/test-register.sh — Tests for scripts/register.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_DIR="$TEST_TMPDIR/my-project"
mkdir -p "$PROJECT_DIR"

echo "=== test-register.sh ==="

# --- Test 1: Creates all expected files/dirs ---
echo ""
echo "Test 1: Creates manifest.json, inbox/, outbox/, bridge-session"
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER")
SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
assert_file_exists "manifest.json exists" "$SESSION_DIR/manifest.json"
assert_dir_exists "inbox/ exists" "$SESSION_DIR/inbox"
assert_dir_exists "outbox/ exists" "$SESSION_DIR/outbox"
assert_file_exists "bridge-session exists" "$PROJECT_DIR/.claude/bridge-session"

# --- Test 2: Manifest has correct fields ---
echo ""
echo "Test 2: manifest.json fields (sessionId, projectPath, status, projectName)"
MANIFEST=$(cat "$SESSION_DIR/manifest.json")
assert_eq "sessionId matches" "$SESSION_ID" "$(echo "$MANIFEST" | jq -r '.sessionId')"
assert_eq "projectPath matches" "$PROJECT_DIR" "$(echo "$MANIFEST" | jq -r '.projectPath')"
assert_eq "status is active" "active" "$(echo "$MANIFEST" | jq -r '.status')"
assert_eq "projectName is dir basename" "my-project" "$(echo "$MANIFEST" | jq -r '.projectName')"
if [ -n "$(echo "$MANIFEST" | jq -r '.startedAt')" ]; then
  echo "  PASS: startedAt is set"; PASS=$((PASS + 1))
else
  echo "  FAIL: startedAt is missing"; FAIL=$((FAIL + 1))
fi
if [ -n "$(echo "$MANIFEST" | jq -r '.lastHeartbeat')" ]; then
  echo "  PASS: lastHeartbeat is set"; PASS=$((PASS + 1))
else
  echo "  FAIL: lastHeartbeat is missing"; FAIL=$((FAIL + 1))
fi

# --- Test 3: bridge-session pointer is correct ---
echo ""
echo "Test 3: bridge-session file contains session ID"
assert_eq "bridge-session contains session ID" "$SESSION_ID" "$(cat "$PROJECT_DIR/.claude/bridge-session")"

# --- Test 4: Session ID format ---
echo ""
echo "Test 4: Session ID is 6 lowercase alphanumeric chars"
assert_eq "session ID length is 6" "6" "${#SESSION_ID}"
if echo "$SESSION_ID" | grep -qE '^[a-z0-9]{6}$'; then
  echo "  PASS: session ID matches [a-z0-9]{6}"; PASS=$((PASS + 1))
else
  echo "  FAIL: session ID '$SESSION_ID' does not match"; FAIL=$((FAIL + 1))
fi

# --- Test 5: CLAUDE_ENV_FILE integration ---
echo ""
echo "Test 5: CLAUDE_ENV_FILE gets BRIDGE_SESSION_ID written"
ENV_FILE="$TEST_TMPDIR/env-file"
touch "$ENV_FILE"
PROJECT_DIR2="$TEST_TMPDIR/my-project-2"
mkdir -p "$PROJECT_DIR2"
SESSION_ID2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR2" CLAUDE_ENV_FILE="$ENV_FILE" bash "$REGISTER")
assert_contains "BRIDGE_SESSION_ID in env file" "BRIDGE_SESSION_ID=$SESSION_ID2" "$(cat "$ENV_FILE")"

# --- Test 6: Re-registering with BRIDGE_SESSION_ID env var reuses session ---
echo ""
echo "Test 6: Re-registering with BRIDGE_SESSION_ID reuses existing session"
SESSION_ID_AGAIN=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" BRIDGE_SESSION_ID="$SESSION_ID" bash "$REGISTER")
assert_eq "reused same session ID via env var" "$SESSION_ID" "$SESSION_ID_AGAIN"

# --- Test 6b: Re-registering same project WITHOUT env var creates new session ---
echo ""
echo "Test 6b: Re-registering same project without env var creates new session"
SESSION_ID_NEW=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER")
if [ "$SESSION_ID_NEW" != "$SESSION_ID" ]; then
  echo "  PASS: new session created without env var (simulates second Claude session)"; PASS=$((PASS + 1))
else
  echo "  FAIL: reused session without env var"; FAIL=$((FAIL + 1))
fi

# --- Test 7: Stale pointer (session dir missing) creates new session ---
echo ""
echo "Test 7: Stale bridge-session pointer — creates new session when dir is gone"
# Manually delete the session dir to simulate a stale pointer
rm -rf "$SESSION_DIR"
NEW_SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER")
if [ "$NEW_SESSION_ID" != "$SESSION_ID" ]; then
  echo "  PASS: new session created after stale pointer"; PASS=$((PASS + 1))
else
  echo "  FAIL: returned old session ID despite dir being gone"; FAIL=$((FAIL + 1))
fi
assert_dir_exists "new session inbox created" "$BRIDGE_DIR/sessions/$NEW_SESSION_ID/inbox"

# --- Test 8: Multiple projects get different session IDs ---
echo ""
echo "Test 8: Different projects get different session IDs"
PROJECT_X="$TEST_TMPDIR/project-x"
PROJECT_Y="$TEST_TMPDIR/project-y"
mkdir -p "$PROJECT_X" "$PROJECT_Y"
ID_X=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_X" bash "$REGISTER")
ID_Y=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_Y" bash "$REGISTER")
if [ "$ID_X" != "$ID_Y" ]; then
  echo "  PASS: different projects get different IDs"; PASS=$((PASS + 1))
else
  echo "  FAIL: same ID for different projects"; FAIL=$((FAIL + 1))
fi

# --- Test 9: heartbeat updated on re-register ---
echo ""
echo "Test 9: Heartbeat is updated when re-registering with env var"
# Set old heartbeat
NEW_SESSION_DIR="$BRIDGE_DIR/sessions/$NEW_SESSION_ID"
TMP=$(mktemp "$NEW_SESSION_DIR/manifest.XXXXXX")
jq '.lastHeartbeat = "2020-01-01T00:00:00Z"' "$NEW_SESSION_DIR/manifest.json" > "$TMP"
mv "$TMP" "$NEW_SESSION_DIR/manifest.json"
# Re-register with BRIDGE_SESSION_ID set
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" BRIDGE_SESSION_ID="$NEW_SESSION_ID" bash "$REGISTER" > /dev/null
UPDATED_HB=$(jq -r '.lastHeartbeat' "$NEW_SESSION_DIR/manifest.json")
if [ "$UPDATED_HB" != "2020-01-01T00:00:00Z" ]; then
  echo "  PASS: heartbeat updated on re-register"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat not updated"; FAIL=$((FAIL + 1))
fi

# --- Test 10: Two sessions in same project get independent bridges ---
echo ""
echo "Test 10: Two sessions in same project get independent bridge IDs"
PROJECT_SHARED="$TEST_TMPDIR/shared-project"
mkdir -p "$PROJECT_SHARED"
SID_1=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_SHARED" bash "$REGISTER")
SID_2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_SHARED" bash "$REGISTER")
if [ "$SID_1" != "$SID_2" ]; then
  echo "  PASS: two sessions in same project get different IDs"; PASS=$((PASS + 1))
else
  echo "  FAIL: both sessions got same ID"; FAIL=$((FAIL + 1))
fi
assert_dir_exists "session 1 dir exists" "$BRIDGE_DIR/sessions/$SID_1"
assert_dir_exists "session 2 dir exists" "$BRIDGE_DIR/sessions/$SID_2"

print_results
