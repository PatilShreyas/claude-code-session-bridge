#!/usr/bin/env bash
# tests/test-integration.sh — End-to-end two-session communication tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CONNECT="$PLUGIN_DIR/scripts/connect-peer.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"
RECEIVE="$PLUGIN_DIR/scripts/bridge-receive.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"
LIST_PEERS="$PLUGIN_DIR/scripts/list-peers.sh"

# Session key the scripts will compute for this process tree (BRIDGE_SESSION_KEY unset)
KEY=$(bash "$PLUGIN_DIR/scripts/get-session-key.sh")

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A/.claude" "$PROJECT_B/.claude"

echo "=== test-integration.sh ==="

# --- Scenario 1: Basic query and response ---
echo ""
echo "Scenario 1: Basic query and response"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")
echo "  Session A: $SESSION_A  Session B: $SESSION_B"
assert_eq "sessions are different" "true" "$([ "$SESSION_A" != "$SESSION_B" ] && echo true || echo false)"

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$CONNECT" "$SESSION_B" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "B sees ping from A" "TYPE=ping" "$OUTPUT"

MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "What changed in v2?")
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "B sees query" "What changed in v2?" "$OUTPUT"
assert_contains "B knows message ID" "MESSAGE_ID=" "$OUTPUT"
assert_contains "B knows sender" "FROM_ID=$SESSION_A" "$OUTPUT"

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "auth() renamed to login()" "$MSG_ID" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "$MSG_ID" 10)
assert_contains "A receives response" "auth() renamed to login()" "$OUTPUT"

# --- Scenario 2: Back-and-forth clarification ---
echo ""
echo "Scenario 2: Multi-turn clarification (C asks D, D asks back, C answers, D responds)"

PROJECT_C="$TEST_TMPDIR/project-c"
PROJECT_D="$TEST_TMPDIR/project-d"
mkdir -p "$PROJECT_C" "$PROJECT_D"
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$REGISTER")
SESSION_D=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_D" bash "$REGISTER")

Q1_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_C" bash "$SEND_MSG" "$SESSION_D" query "How do I use the new API?")
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_D" 5 > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_D" bash "$SEND_MSG" "$SESSION_C" response "What language are you using?" "$Q1_ID" > /dev/null

OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_C" "$Q1_ID" 5)
assert_contains "C gets follow-up from D" "What language are you using?" "$OUTPUT"

Q2_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_C" bash "$SEND_MSG" "$SESSION_D" query "We use Kotlin")
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_D" 5 > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_D" bash "$SEND_MSG" "$SESSION_C" response "For Kotlin: authenticate(config)" "$Q2_ID" > /dev/null

OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_C" "$Q2_ID" 5)
assert_contains "C gets final answer" "authenticate(config)" "$OUTPUT"

# --- Scenario 3: Multiple peers, messages go to right inboxes ---
echo ""
echo "Scenario 3: Multiple sessions, messages routed to correct inboxes"

PROJECT_E="$TEST_TMPDIR/project-e"
PROJECT_F="$TEST_TMPDIR/project-f"
PROJECT_G="$TEST_TMPDIR/project-g"
mkdir -p "$PROJECT_E" "$PROJECT_F" "$PROJECT_G"
SESSION_E=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_E" bash "$REGISTER")
SESSION_F=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_F" bash "$REGISTER")
SESSION_G=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_G" bash "$REGISTER")

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_E" bash "$SEND_MSG" "$SESSION_F" query "Question from E" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_G" bash "$SEND_MSG" "$SESSION_F" query "Question from G" > /dev/null

OUT1=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_F" 5)
OUT2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_F" 5)
ALL_OUTPUT="$OUT1 $OUT2"
assert_contains "F got E's message" "Question from E" "$ALL_OUTPUT"
assert_contains "F got G's message" "Question from G" "$ALL_OUTPUT"

if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_F" 2 > /dev/null 2>&1; then
  echo "  FAIL: unexpected stray message found"; FAIL=$((FAIL + 1))
else
  echo "  PASS: no stray messages in other inboxes"; PASS=$((PASS + 1))
fi

# --- Scenario 4: Cleanup notifies connected peers and removes session ---
echo ""
echo "Scenario 4: Cleanup notifies peers and removes session"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLEANUP"
assert_eq "session A dir removed" "false" "$([ -d "$BRIDGE_DIR/sessions/$SESSION_A" ] && echo true || echo false)"
assert_eq "per-session pointer removed" "false" "$([ -f "$PROJECT_A/.claude/bridge-sessions/$KEY" ] && echo true || echo false)"

FOUND_ENDED=false
for F in "$BRIDGE_DIR/sessions/$SESSION_B/inbox"/msg-*.json; do
  [ -f "$F" ] || continue
  if [ "$(jq -r '.type' "$F")" = "session-ended" ] && [ "$(jq -r '.from' "$F")" = "$SESSION_A" ]; then
    FOUND_ENDED=true
    break
  fi
done
if $FOUND_ENDED; then
  echo "  PASS: B notified of A's departure via session-ended"; PASS=$((PASS + 1))
else
  echo "  FAIL: B not notified of A's departure"; FAIL=$((FAIL + 1))
fi

# --- Scenario 5: list-peers shows active sessions ---
echo ""
echo "Scenario 5: list-peers shows all active sessions"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS")
assert_contains "lists session B" "$SESSION_B" "$OUTPUT"
assert_contains "lists session C" "$SESSION_C" "$OUTPUT"

# --- Scenario 6: Re-register after cleanup works ---
echo ""
echo "Scenario 6: Re-register after cleanup creates new session"
NEW_SESSION=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
assert_eq "new session is different" "true" "$([ "$NEW_SESSION" != "$SESSION_A" ] && echo true || echo false)"
assert_dir_exists "new session inbox exists" "$BRIDGE_DIR/sessions/$NEW_SESSION/inbox"
assert_file_exists "new per-session pointer" "$PROJECT_A/.claude/bridge-sessions/$KEY"
assert_eq "pointer points to new ID" "$NEW_SESSION" "$(cat "$PROJECT_A/.claude/bridge-sessions/$KEY")"

print_results
