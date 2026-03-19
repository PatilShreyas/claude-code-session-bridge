#!/usr/bin/env bash
# tests/test-bidirectional-integration.sh — End-to-end bidirectional orchestration tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"
RECEIVE="$PLUGIN_DIR/scripts/bridge-receive.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"
LIST_PEERS="$PLUGIN_DIR/scripts/list-peers.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-bidirectional-integration.sh ==="

# --- Scenario 1: Full orchestrator -> specialist -> specialist chain ---
echo ""
echo "Scenario 1: Task delegation chain (orchestrator -> dev -> framework)"

ORCH_DIR="$TEST_TMPDIR/orchestrator"
DEV_DIR="$TEST_TMPDIR/dev-app"
FW_DIR="$TEST_TMPDIR/framework"
mkdir -p "$ORCH_DIR" "$DEV_DIR" "$FW_DIR"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "chain-test" > /dev/null

ORCH_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$ORCH_DIR" bash "$JOIN" "chain-test" --role orchestrator --specialty "coordination")
DEV_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$DEV_DIR" bash "$JOIN" "chain-test" --role specialist --specialty "app development")
FW_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$FW_DIR" bash "$JOIN" "chain-test" --role specialist --specialty "shared framework")

# Orchestrator assigns task to dev
TASK_MSG=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$ORCH_ID" bash "$SEND_MSG" "$DEV_ID" task-assign "Fix issue #123")
TASK_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/chain-test/sessions/$DEV_ID/inbox/$TASK_MSG.json")
assert_not_empty "task conversation created" "$TASK_CONV"

# Dev picks up the task
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$DEV_ID" 5)
assert_contains "dev sees task-assign" "Fix issue #123" "$OUTPUT"
assert_contains "dev sees type" "TYPE=task-assign" "$OUTPUT"

# Dev needs help from framework — sends query (new conversation, auto-created)
FW_QUERY=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$DEV_ID" bash "$SEND_MSG" "$FW_ID" query "Bug in shared utils, can you investigate?")
FW_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/chain-test/sessions/$FW_ID/inbox/$FW_QUERY.json")

# Framework picks up the query
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$FW_ID" 5)
assert_contains "framework sees query" "Bug in shared utils" "$OUTPUT"

# Framework responds with task-complete
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$FW_ID" bash "$SEND_MSG" "$DEV_ID" task-complete "Fixed: updated validate() in utils.go" --conversation "$FW_CONV" --reply-to "$FW_QUERY" > /dev/null

# Dev picks up framework's response via bridge-receive
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$DEV_ID" "$FW_QUERY" 10)
assert_contains "dev gets framework response" "Fixed: updated validate()" "$OUTPUT"

# Dev completes task back to orchestrator
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$DEV_ID" bash "$SEND_MSG" "$ORCH_ID" task-complete "Issue #123 fixed, framework utils updated" --conversation "$TASK_CONV" --reply-to "$TASK_MSG" > /dev/null

# Orchestrator picks up completion
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$ORCH_ID" "$TASK_MSG" 10)
assert_contains "orchestrator gets completion" "Issue #123 fixed" "$OUTPUT"

# Verify conversation states
assert_json_field "task conv resolved" "$BRIDGE_DIR/projects/chain-test/conversations/$TASK_CONV.json" '.status' "resolved"
assert_json_field "fw conv resolved" "$BRIDGE_DIR/projects/chain-test/conversations/$FW_CONV.json" '.status' "resolved"

# --- Scenario 2: Bidirectional — both sessions ask each other ---
echo ""
echo "Scenario 2: Bidirectional query exchange"

PROJ_X="$TEST_TMPDIR/proj-x"
PROJ_Y="$TEST_TMPDIR/proj-y"
mkdir -p "$PROJ_X" "$PROJ_Y"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "bidir-test" > /dev/null
SID_X=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_X" bash "$JOIN" "bidir-test" --role specialist --specialty "frontend")
SID_Y=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_Y" bash "$JOIN" "bidir-test" --role specialist --specialty "backend")

# X asks Y
Q1_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_X" bash "$SEND_MSG" "$SID_Y" query "What does the new API return?")

# Y asks X (independent conversation)
Q2_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_Y" bash "$SEND_MSG" "$SID_X" query "What frontend components use the old API?")

# Both pick up each other's messages
OUT_Y=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_Y" 5)
assert_contains "Y sees X's query" "new API return" "$OUT_Y"

OUT_X=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_X" 5)
assert_contains "X sees Y's query" "frontend components" "$OUT_X"

# Both respond
Q1_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/bidir-test/sessions/$SID_Y/inbox/$Q1_ID.json")
Q2_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/bidir-test/sessions/$SID_X/inbox/$Q2_ID.json")

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_Y" bash "$SEND_MSG" "$SID_X" response "Returns JSON with userId field" --conversation "$Q1_CONV" --reply-to "$Q1_ID" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_X" bash "$SEND_MSG" "$SID_Y" response "UserCard and ProfilePage use it" --conversation "$Q2_CONV" --reply-to "$Q2_ID" > /dev/null

OUT_X2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SID_X" "$Q1_ID" 10)
assert_contains "X gets response about API" "userId field" "$OUT_X2"

OUT_Y2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SID_Y" "$Q2_ID" 10)
assert_contains "Y gets response about components" "UserCard" "$OUT_Y2"

# --- Scenario 3: Human-input-needed message ---
echo ""
echo "Scenario 3: Human decision escalation"

HIN_CONV=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$PLUGIN_DIR/scripts/conversation-create.sh" "bidir-test" "$SID_Y" "$SID_X" "API design question")
HIN_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_Y" bash "$SEND_MSG" "$SID_X" human-input-needed "REST or GraphQL?" --conversation "$HIN_CONV" --urgency high)
HIN_FILE="$BRIDGE_DIR/projects/bidir-test/sessions/$SID_X/inbox/$HIN_ID.json"
assert_json_field "human-input urgency is high" "$HIN_FILE" '.metadata.urgency' "high"
assert_json_field "human-input type correct" "$HIN_FILE" '.type' "human-input-needed"

# --- Scenario 4: Legacy backward compatibility ---
echo ""
echo "Scenario 4: Legacy ad-hoc bridge still works"

LEGACY_A="$TEST_TMPDIR/legacy-a"
LEGACY_B="$TEST_TMPDIR/legacy-b"
mkdir -p "$LEGACY_A/.claude" "$LEGACY_B/.claude"

# Use original register.sh (not project-join)
LEGACY_SID_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$LEGACY_A" bash "$PLUGIN_DIR/scripts/register.sh")
LEGACY_SID_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$LEGACY_B" bash "$PLUGIN_DIR/scripts/register.sh")

MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$LEGACY_SID_A" bash "$SEND_MSG" "$LEGACY_SID_B" query "Legacy test")
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$LEGACY_SID_B" 5)
assert_contains "legacy message delivered" "Legacy test" "$OUTPUT"

print_results
