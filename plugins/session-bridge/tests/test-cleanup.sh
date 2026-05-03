#!/usr/bin/env bash
# tests/test-cleanup.sh — Tests for scripts/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
PROJECT_C="$TEST_TMPDIR/project-c"
mkdir -p "$PROJECT_A" "$PROJECT_B" "$PROJECT_C"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$REGISTER")

echo "=== test-cleanup.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B  session_c=$SESSION_C"

# Have B and C send to A (so A knows both as peers)
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" ping "hello" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_C" bash "$SEND_MSG" "$SESSION_A" ping "hello" > /dev/null

# --- Test 1: Session dir removed ---
echo ""
echo "Test 1: Cleanup removes session directory"
SESSION_A_DIR="$BRIDGE_DIR/sessions/$SESSION_A"
assert_dir_exists "session dir exists before cleanup" "$SESSION_A_DIR"
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" BRIDGE_SESSION_ID="$SESSION_A" bash "$CLEANUP"
if [ ! -d "$SESSION_A_DIR" ]; then
  echo "  PASS: session dir removed"; PASS=$((PASS + 1))
else
  echo "  FAIL: session dir still exists"; FAIL=$((FAIL + 1))
fi

# --- Test 2: bridge-session pointer removed (file belongs to this session) ---
echo ""
echo "Test 2: bridge-session file removed when it belongs to the exiting session"
if [ ! -f "$PROJECT_A/.claude/bridge-session" ]; then
  echo "  PASS: bridge-session file removed"; PASS=$((PASS + 1))
else
  echo "  FAIL: bridge-session file still exists"; FAIL=$((FAIL + 1))
fi

# --- Test 3: ALL peers notified with session-ended ---
echo ""
echo "Test 3: All peers receive session-ended notification"
for SID in "$SESSION_B" "$SESSION_C"; do
  FOUND=false
  for F in "$BRIDGE_DIR/sessions/$SID/inbox"/msg-*.json; do
    [ -f "$F" ] || continue
    FTYPE=$(jq -r '.type' "$F" 2>/dev/null)
    FFROM=$(jq -r '.from' "$F" 2>/dev/null)
    if [ "$FTYPE" = "session-ended" ] && [ "$FFROM" = "$SESSION_A" ]; then
      FOUND=true
      break
    fi
  done
  if $FOUND; then
    echo "  PASS: session $SID notified"; PASS=$((PASS + 1))
  else
    echo "  FAIL: session $SID not notified"; FAIL=$((FAIL + 1))
  fi
done

# --- Test 4: Stale sessions cleaned up ---
echo ""
echo "Test 4: Stale sessions (>30 min heartbeat) cleaned up"
STALE_ID="stale99"
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
assert_dir_exists "stale session exists before cleanup" "$STALE_DIR"
PROJECT_D="$TEST_TMPDIR/project-d"
mkdir -p "$PROJECT_D"
SESSION_D=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_D" bash "$REGISTER")
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_D" BRIDGE_SESSION_ID="$SESSION_D" bash "$CLEANUP"
if [ ! -d "$STALE_DIR" ]; then
  echo "  PASS: stale session cleaned up"; PASS=$((PASS + 1))
else
  echo "  FAIL: stale session still exists"; FAIL=$((FAIL + 1))
fi

# --- Test 5: No-op when bridge-session file doesn't exist ---
echo ""
echo "Test 5: Cleanup is no-op when no bridge-session file"
PROJECT_E="$TEST_TMPDIR/project-e"
mkdir -p "$PROJECT_E"
# Don't register — no bridge-session file
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_E" bash "$CLEANUP" 2>/dev/null; then
  echo "  PASS: cleanup exits cleanly with no bridge-session"; PASS=$((PASS + 1))
else
  echo "  FAIL: cleanup errored without bridge-session"; FAIL=$((FAIL + 1))
fi

# --- Test 6: Active sessions not cleaned by stale cleanup ---
echo ""
echo "Test 6: Active sessions (fresh heartbeat) not cleaned as stale"
SESSION_B_DIR="$BRIDGE_DIR/sessions/$SESSION_B"
assert_dir_exists "session B still exists" "$SESSION_B_DIR"

# SESSION_B has fresh heartbeat, should NOT be cleaned up
# Register another session and trigger cleanup
PROJECT_F="$TEST_TMPDIR/project-f"
mkdir -p "$PROJECT_F"
SESSION_F=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_F" bash "$REGISTER")
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_F" BRIDGE_SESSION_ID="$SESSION_F" bash "$CLEANUP"

assert_dir_exists "active session B not cleaned" "$SESSION_B_DIR"

# --- Test 7: Cleanup of one session doesn't delete bridge-session file owned by another ---
echo ""
echo "Test 7: Cleanup preserves bridge-session file owned by another session"
PROJECT_SHARED="$TEST_TMPDIR/project-shared"
mkdir -p "$PROJECT_SHARED"
SID_1=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_SHARED" bash "$REGISTER")
SID_2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_SHARED" bash "$REGISTER")
# File now points to SID_2 (last registered)
assert_eq "file points to SID_2" "$SID_2" "$(cat "$PROJECT_SHARED/.claude/bridge-session")"
# Clean up SID_1 — should NOT delete the file since it belongs to SID_2
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_SHARED" BRIDGE_SESSION_ID="$SID_1" bash "$CLEANUP"
if [ ! -d "$BRIDGE_DIR/sessions/$SID_1" ]; then
  echo "  PASS: session 1 dir removed"; PASS=$((PASS + 1))
else
  echo "  FAIL: session 1 dir still exists"; FAIL=$((FAIL + 1))
fi
assert_file_exists "bridge-session file preserved for session 2" "$PROJECT_SHARED/.claude/bridge-session"
assert_eq "file still points to SID_2" "$SID_2" "$(cat "$PROJECT_SHARED/.claude/bridge-session")"
assert_dir_exists "session 2 dir untouched" "$BRIDGE_DIR/sessions/$SID_2"

print_results
