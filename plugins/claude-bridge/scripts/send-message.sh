#!/usr/bin/env bash
# scripts/send-message.sh — Send a message to a peer's inbox.
# Usage: send-message.sh <target-id> <type> <content> [in-reply-to]
# Env: BRIDGE_DIR (default: ~/.claude/bridge), BRIDGE_SESSION_ID (required)
# Outputs: message ID to stdout
set -euo pipefail

TARGET_ID="$1"
MSG_TYPE="$2"
CONTENT="$3"
IN_REPLY_TO="${4:-null}"

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
SENDER_ID="${BRIDGE_SESSION_ID:?BRIDGE_SESSION_ID must be set}"

TARGET_INBOX="$BRIDGE_DIR/sessions/$TARGET_ID/inbox"
SENDER_OUTBOX="$BRIDGE_DIR/sessions/$SENDER_ID/outbox"

if [ ! -d "$TARGET_INBOX" ]; then
  echo "Error: Target session $TARGET_ID not found" >&2
  exit 1
fi

# Generate UUID-style message ID
MSG_ID="msg-$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Read sender project name from manifest
SENDER_PROJECT="unknown"
SENDER_MANIFEST="$BRIDGE_DIR/sessions/$SENDER_ID/manifest.json"
if [ -f "$SENDER_MANIFEST" ]; then
  SENDER_PROJECT=$(jq -r '.projectName // "unknown"' "$SENDER_MANIFEST")
fi

# Format inReplyTo as JSON (null or quoted string)
if [ "$IN_REPLY_TO" = "null" ]; then
  IN_REPLY_TO_JSON="null"
else
  IN_REPLY_TO_JSON="\"$IN_REPLY_TO\""
fi

# Build message JSON — use jq for safe content escaping
MSG_JSON=$(jq -n \
  --arg id "$MSG_ID" \
  --arg from "$SENDER_ID" \
  --arg to "$TARGET_ID" \
  --arg type "$MSG_TYPE" \
  --arg ts "$NOW" \
  --arg content "$CONTENT" \
  --arg fromProject "$SENDER_PROJECT" \
  --argjson inReplyTo "$IN_REPLY_TO_JSON" \
  '{
    id: $id,
    from: $from,
    to: $to,
    type: $type,
    timestamp: $ts,
    status: "pending",
    content: $content,
    inReplyTo: $inReplyTo,
    metadata: {
      urgency: "normal",
      fromProject: $fromProject
    }
  }')

# Atomic write to target inbox
TMP_FILE=$(mktemp "$TARGET_INBOX/$MSG_ID.XXXXXX")
echo "$MSG_JSON" > "$TMP_FILE"
mv "$TMP_FILE" "$TARGET_INBOX/$MSG_ID.json"

# Copy to sender outbox (audit log)
TMP_FILE=$(mktemp "$SENDER_OUTBOX/$MSG_ID.XXXXXX")
echo "$MSG_JSON" > "$TMP_FILE"
mv "$TMP_FILE" "$SENDER_OUTBOX/$MSG_ID.json"

echo -n "$MSG_ID"
