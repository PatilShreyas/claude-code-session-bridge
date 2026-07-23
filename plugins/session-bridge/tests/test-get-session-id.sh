#!/usr/bin/env bash
# tests/test-get-session-id.sh — Tests for scripts/get-session-id.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
GET_ID="$PLUGIN_DIR/scripts/get-session-id.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_DIR="$TEST_TMPDIR/my-project"
mkdir -p "$PROJECT_DIR"

echo "=== test-get-session-id.sh ==="

# Register a session
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER")
echo "  registered: $SESSION_ID"

# --- Test 1: Finds session from project root ---
echo ""
echo "Test 1: Finds session from project root"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")
assert_eq "finds session from root" "$SESSION_ID" "$FOUND"

# --- Test 2: Finds session from subdirectory ---
echo ""
echo "Test 2: Finds session from a subdirectory of the project"
SUBDIR="$PROJECT_DIR/src/main/kotlin"
mkdir -p "$SUBDIR"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$SUBDIR" bash "$GET_ID")
assert_eq "finds session from subdirectory" "$SESSION_ID" "$FOUND"

# --- Test 3: Finds session from deep nested subdirectory ---
echo ""
echo "Test 3: Finds session from deeply nested subdirectory"
DEEP="$PROJECT_DIR/src/main/kotlin/com/example/feature/impl"
mkdir -p "$DEEP"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$DEEP" bash "$GET_ID")
assert_eq "finds from deep subdir" "$SESSION_ID" "$FOUND"

# --- Test 4: Does NOT find a different project's session ---
echo ""
echo "Test 4: Unrelated directory does not return a session"
UNRELATED="$TEST_TMPDIR/other-project/src"
mkdir -p "$UNRELATED"
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$UNRELATED" bash "$GET_ID" 2>/dev/null; then
  echo "  FAIL: found a session for unrelated directory"; FAIL=$((FAIL + 1))
else
  echo "  PASS: correctly returns nothing for unrelated directory"; PASS=$((PASS + 1))
fi

# --- Test 5: Sibling project does not leak ---
echo ""
echo "Test 5: Sibling project does not pick up neighbor's session"
SIBLING="$TEST_TMPDIR/my-project-2"
mkdir -p "$SIBLING"
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$SIBLING" bash "$GET_ID" 2>/dev/null; then
  echo "  FAIL: sibling project leaked session"; FAIL=$((FAIL + 1))
else
  echo "  PASS: sibling project correctly isolated"; PASS=$((PASS + 1))
fi

# --- Test 6: Two projects, each finds only their own ---
echo ""
echo "Test 6: Two registered projects find only their own sessions"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_B"
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

FOUND_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR/src" bash "$GET_ID")
FOUND_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$GET_ID")

assert_eq "project A finds its own" "$SESSION_ID" "$FOUND_A"
assert_eq "project B finds its own" "$SESSION_B" "$FOUND_B"
if [ "$FOUND_A" != "$FOUND_B" ]; then
  echo "  PASS: sessions are distinct"; PASS=$((PASS + 1))
else
  echo "  FAIL: both returned same session"; FAIL=$((FAIL + 1))
fi

# --- Test 7: Prefers per-session pointer when in project root ---
echo ""
echo "Test 7: Fast path — uses per-session pointer directly when available"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")
assert_eq "fast path works" "$SESSION_ID" "$FOUND"

# --- Test 8: Two sessions in the same repo resolve by session key ---
echo ""
echo "Test 8: Two sessions in same repo — each key resolves its own session"
SHARED="$TEST_TMPDIR/shared-repo"
mkdir -p "$SHARED/src"
ID_A=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$SHARED" bash "$REGISTER")
ID_B=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$SHARED" bash "$REGISTER")

FOUND_KEY_A=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$SHARED" bash "$GET_ID")
FOUND_KEY_B=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$SHARED" bash "$GET_ID")
assert_eq "agent-a resolves from project root" "$ID_A" "$FOUND_KEY_A"
assert_eq "agent-b resolves from project root" "$ID_B" "$FOUND_KEY_B"

FOUND_KEY_A_SUB=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$SHARED/src" bash "$GET_ID")
FOUND_KEY_B_SUB=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$SHARED/src" bash "$GET_ID")
assert_eq "agent-a resolves from subdirectory" "$ID_A" "$FOUND_KEY_A_SUB"
assert_eq "agent-b resolves from subdirectory" "$ID_B" "$FOUND_KEY_B_SUB"

print_results
