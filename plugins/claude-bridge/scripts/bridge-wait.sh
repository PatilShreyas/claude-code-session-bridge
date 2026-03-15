#!/usr/bin/env bash
# scripts/bridge-wait.sh — Block until a response to a specific message arrives.
# Usage: bridge-wait.sh <session-id> <message-id> [timeout-seconds]
# Polls inbox every 3 seconds, returns the response content when found.
# Exits with code 1 on timeout.
set -euo pipefail

SESSION_ID="${1:?Usage: bridge-wait.sh <session-id> <message-id> [timeout]}"
ORIG_MSG_ID="${2:?Usage: bridge-wait.sh <session-id> <message-id> [timeout]}"
TIMEOUT="${3:-60}"

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
INBOX="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"

ELAPSED=0
INTERVAL=3

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  # Scan inbox for a response with inReplyTo matching our message
  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$MSG_FILE" 2>/dev/null) || continue
    [ "$IN_REPLY_TO" = "$ORIG_MSG_ID" ] || continue

    # Found the response!
    CONTENT=$(jq -r '.content' "$MSG_FILE")
    FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE")
    MSG_TYPE=$(jq -r '.type' "$MSG_FILE")

    # Mark as read
    TMP=$(mktemp "$INBOX/$(basename "$MSG_FILE" .json).XXXXXX")
    jq '.status = "read"' "$MSG_FILE" > "$TMP"
    mv "$TMP" "$MSG_FILE"

    echo "Response from $FROM_PROJECT:"
    echo "$CONTENT"
    exit 0
  done

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "No response received after ${TIMEOUT}s. The peer may be inactive."
exit 1
