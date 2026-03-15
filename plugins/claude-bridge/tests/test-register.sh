#!/usr/bin/env bash
# tests/test-register.sh — Tests for scripts/register.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"

# Set up isolated temp dirs for testing
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_DIR="$TEST_TMPDIR/my-project"
mkdir -p "$PROJECT_DIR"

echo "=== test-register.sh ==="

# --- Test 1: Basic registration creates expected structure ---
echo ""
echo "Test 1: Basic registration creates manifest.json, inbox/, outbox/, bridge-session"
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER")
SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"

assert_file_exists "manifest.json exists" "$SESSION_DIR/manifest.json"
assert_dir_exists "inbox/ exists" "$SESSION_DIR/inbox"
assert_dir_exists "outbox/ exists" "$SESSION_DIR/outbox"
assert_file_exists "bridge-session exists" "$PROJECT_DIR/.claude/bridge-session"

# --- Test 2: manifest.json has correct fields ---
echo ""
echo "Test 2: manifest.json has correct sessionId, projectPath, status, projectName"
MANIFEST=$(cat "$SESSION_DIR/manifest.json")

MANIFEST_SESSION_ID=$(echo "$MANIFEST" | jq -r '.sessionId')
MANIFEST_PROJECT_PATH=$(echo "$MANIFEST" | jq -r '.projectPath')
MANIFEST_STATUS=$(echo "$MANIFEST" | jq -r '.status')
MANIFEST_PROJECT_NAME=$(echo "$MANIFEST" | jq -r '.projectName')

assert_eq "sessionId matches" "$SESSION_ID" "$MANIFEST_SESSION_ID"
assert_eq "projectPath matches" "$PROJECT_DIR" "$MANIFEST_PROJECT_PATH"
assert_eq "status is active" "active" "$MANIFEST_STATUS"
assert_eq "projectName matches" "my-project" "$MANIFEST_PROJECT_NAME"

# --- Test 3: bridge-session file contains session ID ---
echo ""
echo "Test 3: bridge-session file contains session ID"
BRIDGE_SESSION_CONTENT=$(cat "$PROJECT_DIR/.claude/bridge-session")
assert_eq "bridge-session contains session ID" "$SESSION_ID" "$BRIDGE_SESSION_CONTENT"

# --- Test 4: Session ID is 6 lowercase alphanumeric chars ---
echo ""
echo "Test 4: Session ID is 6 lowercase alphanumeric chars"
ID_LENGTH=${#SESSION_ID}
assert_eq "session ID length is 6" "6" "$ID_LENGTH"

if echo "$SESSION_ID" | grep -qE '^[a-z0-9]{6}$'; then
  echo "  PASS: session ID matches [a-z0-9]{6}"; PASS=$((PASS + 1))
else
  echo "  FAIL: session ID '$SESSION_ID' does not match [a-z0-9]{6}"; FAIL=$((FAIL + 1))
fi

# --- Test 5: CLAUDE_ENV_FILE integration ---
echo ""
echo "Test 5: CLAUDE_ENV_FILE integration"
ENV_FILE="$TEST_TMPDIR/env-file"
touch "$ENV_FILE"
PROJECT_DIR2="$TEST_TMPDIR/my-project-2"
mkdir -p "$PROJECT_DIR2"

SESSION_ID2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR2" CLAUDE_ENV_FILE="$ENV_FILE" bash "$REGISTER")
ENV_CONTENT=$(cat "$ENV_FILE")
assert_contains "CLAUDE_ENV_FILE has BRIDGE_SESSION_ID" "BRIDGE_SESSION_ID=$SESSION_ID2" "$ENV_CONTENT"

print_results
