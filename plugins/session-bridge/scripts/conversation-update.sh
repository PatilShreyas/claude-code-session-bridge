#!/usr/bin/env bash
# scripts/conversation-update.sh — Update conversation status.
# Usage: conversation-update.sh <project-id> <conversation-id> <new-status> [--resolution "<text>"]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_ID="${1:?Usage: conversation-update.sh <project-id> <conversation-id> <new-status> [--resolution \"<text>\"]}"
CONV_ID="${2:?Missing conversation-id}"
NEW_STATUS="${3:?Missing new-status}"
shift 3

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
CONV_FILE="$BRIDGE_DIR/projects/$PROJECT_ID/conversations/$CONV_ID.json"

if [ ! -f "$CONV_FILE" ]; then
  echo "Error: Conversation '$CONV_ID' not found in project '$PROJECT_ID'." >&2
  exit 1
fi

# Parse optional args
RESOLUTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resolution) RESOLUTION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$(dirname "$CONV_FILE")/$CONV_ID.XXXXXX")

if [ "$NEW_STATUS" = "resolved" ]; then
  if [ -n "$RESOLUTION" ]; then
    jq --arg s "$NEW_STATUS" --arg ra "$NOW" --arg res "$RESOLUTION" \
      '.status = $s | .resolvedAt = $ra | .resolution = $res' "$CONV_FILE" > "$TMP"
  else
    jq --arg s "$NEW_STATUS" --arg ra "$NOW" \
      '.status = $s | .resolvedAt = $ra' "$CONV_FILE" > "$TMP"
  fi
else
  jq --arg s "$NEW_STATUS" '.status = $s' "$CONV_FILE" > "$TMP"
fi

mv "$TMP" "$CONV_FILE"
