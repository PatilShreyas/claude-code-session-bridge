#!/usr/bin/env bash
# tests/test-same-repo.sh — Two agent sessions in the SAME project dir as distinct peers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
GET_ID="$PLUGIN_DIR/scripts/get-session-id.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CONNECT="$PLUGIN_DIR/scripts/connect-peer.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"
RECEIVE="$PLUGIN_DIR/scripts/bridge-receive.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"
LIST_PEERS="$PLUGIN_DIR/scripts/list-peers.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_DIR="$TEST_TMPDIR/my-project"
mkdir -p "$PROJECT_DIR"

echo "=== test-same-repo.sh ==="

# --- Scenario 1: Two agent sessions register in the same project as distinct peers ---
echo ""
echo "Scenario 1: Register backend and frontend in the same project dir"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER" --as backend)
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER" --as frontend)
echo "  Session A (backend): $SESSION_A  Session B (frontend): $SESSION_B"

assert_eq "sessions are different" "true" "$([ "$SESSION_A" != "$SESSION_B" ] && echo true || echo false)"
assert_file_exists "A manifest exists" "$BRIDGE_DIR/sessions/$SESSION_A/manifest.json"
assert_file_exists "B manifest exists" "$BRIDGE_DIR/sessions/$SESSION_B/manifest.json"
assert_eq "A label is backend" "backend" "$(jq -r '.label' "$BRIDGE_DIR/sessions/$SESSION_A/manifest.json")"
assert_eq "B label is frontend" "frontend" "$(jq -r '.label' "$BRIDGE_DIR/sessions/$SESSION_B/manifest.json")"
assert_file_exists "A pointer exists" "$PROJECT_DIR/.claude/bridge-sessions/agent-a"
assert_file_exists "B pointer exists" "$PROJECT_DIR/.claude/bridge-sessions/agent-b"
if [ ! -f "$PROJECT_DIR/.claude/bridge-session" ]; then
  echo "  PASS: legacy bridge-session pointer absent"; PASS=$((PASS + 1))
else
  echo "  FAIL: legacy bridge-session pointer exists"; FAIL=$((FAIL + 1))
fi

# --- Scenario 2: get-session-id resolves each agent's own session ---
echo ""
echo "Scenario 2: get-session-id.sh resolves per session key (root and subdirectory)"

FOUND_A=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")
FOUND_B=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")
assert_eq "agent-a resolves to session A" "$SESSION_A" "$FOUND_A"
assert_eq "agent-b resolves to session B" "$SESSION_B" "$FOUND_B"

SUBDIR="$PROJECT_DIR/src/ui"
mkdir -p "$SUBDIR"
FOUND_A_SUB=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$SUBDIR" bash "$GET_ID")
FOUND_B_SUB=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$SUBDIR" bash "$GET_ID")
assert_eq "agent-a resolves from subdirectory" "$SESSION_A" "$FOUND_A_SUB"
assert_eq "agent-b resolves from subdirectory" "$SESSION_B" "$FOUND_B_SUB"

# --- Scenario 3: Round trip between the two same-repo peers ---
echo ""
echo "Scenario 3: Connect, query, and respond between same-repo peers"

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$CONNECT" "$SESSION_B" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "B sees ping from A" "TYPE=ping" "$OUTPUT"
assert_contains "B sees sender label on ping" "FROM_LABEL=backend" "$OUTPUT"

MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "What is the API base URL?")
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "B sees query from A" "What is the API base URL?" "$OUTPUT"
assert_contains "B knows sender is A" "FROM_ID=$SESSION_A" "$OUTPUT"
assert_contains "B sees sender label on query" "FROM_LABEL=backend" "$OUTPUT"

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Base URL is /api/v2" "$MSG_ID" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "$MSG_ID" 10)
assert_contains "A receives B's response" "Base URL is /api/v2" "$OUTPUT"
assert_contains "response shows sender label" 'Response from my-project \[frontend\]:' "$OUTPUT"

# --- Scenario 4: list-peers shows both labels ---
echo ""
echo "Scenario 4: list-peers shows both same-repo labels"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS")
assert_contains "lists session A ID" "$SESSION_A" "$OUTPUT"
assert_contains "lists session B ID" "$SESSION_B" "$OUTPUT"
assert_contains "lists backend label" "backend" "$OUTPUT"
assert_contains "lists frontend label" "frontend" "$OUTPUT"

# --- Scenario 5: Cleanup of A removes only A and notifies B ---
echo ""
echo "Scenario 5: Cleanup of session A leaves session B intact"

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$PROJECT_DIR" bash "$CLEANUP"
assert_eq "A session dir removed" "false" "$([ -d "$BRIDGE_DIR/sessions/$SESSION_A" ] && echo true || echo false)"
assert_eq "A pointer removed" "false" "$([ -f "$PROJECT_DIR/.claude/bridge-sessions/agent-a" ] && echo true || echo false)"
assert_dir_exists "B session dir still present" "$BRIDGE_DIR/sessions/$SESSION_B"
assert_file_exists "B manifest intact" "$BRIDGE_DIR/sessions/$SESSION_B/manifest.json"
assert_dir_exists "B inbox intact" "$BRIDGE_DIR/sessions/$SESSION_B/inbox"
assert_file_exists "B pointer still present" "$PROJECT_DIR/.claude/bridge-sessions/agent-b"
assert_eq "agent-b still resolves to B" "$SESSION_B" "$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")"

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

# --- Scenario 6: Re-registering agent-a creates a NEW session, B unaffected ---
echo ""
echo "Scenario 6: Re-register agent-a after cleanup"

NEW_SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-a PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER" --as backend)
assert_eq "new session ID differs from old" "true" "$([ "$NEW_SESSION_A" != "$SESSION_A" ] && echo true || echo false)"
assert_dir_exists "new session inbox exists" "$BRIDGE_DIR/sessions/$NEW_SESSION_A/inbox"
assert_eq "new pointer points to new ID" "$NEW_SESSION_A" "$(cat "$PROJECT_DIR/.claude/bridge-sessions/agent-a")"
assert_eq "B still resolves to same session" "$SESSION_B" "$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_KEY=agent-b PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")"

print_results
