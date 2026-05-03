#!/usr/bin/env bash
# scripts/bridge-listen.sh — Block until a pending message arrives in THIS session's inbox.
# Usage: bridge-listen.sh <session-id> [timeout-seconds]
# If no session-id given, uses get-session-id.sh to find it.
# Polls every 3 seconds. Outputs the message details when found.
# Exits 0 with message content on success, exits 1 on timeout.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get session ID: from argument, or from get-session-id.sh
if [ -n "${1:-}" ] && [ "${1:-}" != "0" ] && ! echo "$1" | grep -qE '^[0-9]+$'; then
  # First arg looks like a session ID (not a number/timeout)
  SESSION_ID="$1"
  TIMEOUT="${2:-0}"
else
  # No session ID given — prefer BRIDGE_SESSION_ID env var, then fall back to get-session-id.sh
  if [ -n "${BRIDGE_SESSION_ID:-}" ]; then
    SESSION_ID="$BRIDGE_SESSION_ID"
  else
    SESSION_ID=$(bash "$SCRIPT_DIR/get-session-id.sh" 2>/dev/null) || {
      echo "Error: No bridge session found. Run /bridge start first." >&2
      exit 1
    }
  fi
  TIMEOUT="${1:-0}"
fi

INBOX="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"

if [ ! -d "$INBOX" ]; then
  echo "Error: Session $SESSION_ID inbox not found." >&2
  exit 1
fi

ELAPSED=0
INTERVAL=3

while true; do
  # Timeout check (0 = infinite)
  if [ "$TIMEOUT" -gt 0 ] && [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    exit 1
  fi

  # Scan only THIS session's inbox
  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    # Found a pending message!
    MSG_ID=$(jq -r '.id' "$MSG_FILE")
    FROM_ID=$(jq -r '.from' "$MSG_FILE")
    TO_ID=$(jq -r '.to' "$MSG_FILE")
    MSG_TYPE=$(jq -r '.type' "$MSG_FILE")
    CONTENT=$(jq -r '.content' "$MSG_FILE")
    FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE")
    IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$MSG_FILE")

    # Skip messages FROM ourselves (echo prevention)
    if [ "$FROM_ID" = "$SESSION_ID" ]; then
      continue
    fi

    # Mark as read
    TMP=$(mktemp "$INBOX/${MSG_ID}.XXXXXX")
    jq '.status = "read"' "$MSG_FILE" > "$TMP"
    mv "$TMP" "$MSG_FILE"

    # Output message details for the agent
    echo "MESSAGE_ID=$MSG_ID"
    echo "FROM_ID=$FROM_ID"
    echo "TO_ID=$TO_ID"
    echo "FROM_PROJECT=$FROM_PROJECT"
    echo "TYPE=$MSG_TYPE"
    echo "IN_REPLY_TO=$IN_REPLY_TO"
    echo "---"
    echo "$CONTENT"
    exit 0
  done

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
