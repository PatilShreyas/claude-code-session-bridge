#!/usr/bin/env bash
# scripts/conversation-create.sh — Create a conversation file.
# Usage: conversation-create.sh <project-id> <initiator-id> <responder-id> <topic> [--parent <conv-id>]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Outputs: conversation ID to stdout
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_ID="${1:?Usage: conversation-create.sh <project-id> <initiator-id> <responder-id> <topic> [--parent <conv-id>]}"
INITIATOR="${2:?Missing initiator-id}"
RESPONDER="${3:?Missing responder-id}"
TOPIC="${4:?Missing topic}"
shift 4

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
CONV_DIR="$BRIDGE_DIR/projects/$PROJECT_ID/conversations"

if [ ! -d "$CONV_DIR" ]; then
  echo "Error: Project '$PROJECT_ID' not found." >&2
  exit 1
fi

# Parse optional args
PARENT="null"
while [ $# -gt 0 ]; do
  case "$1" in
    --parent) PARENT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CONV_ID="conv-$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Format parent as JSON
if [ "$PARENT" = "null" ]; then
  PARENT_JSON="null"
else
  PARENT_JSON="\"$PARENT\""
fi

TMP=$(mktemp "$CONV_DIR/$CONV_ID.XXXXXX")
jq -n \
  --arg cid "$CONV_ID" \
  --arg topic "$TOPIC" \
  --arg init "$INITIATOR" \
  --arg resp "$RESPONDER" \
  --argjson parent "$PARENT_JSON" \
  --arg now "$NOW" \
  '{
    conversationId: $cid,
    topic: $topic,
    initiator: $init,
    responder: $resp,
    parentConversation: $parent,
    status: "open",
    createdAt: $now,
    resolvedAt: null,
    resolution: null
  }' > "$TMP"
mv "$TMP" "$CONV_DIR/$CONV_ID.json"

echo -n "$CONV_ID"
