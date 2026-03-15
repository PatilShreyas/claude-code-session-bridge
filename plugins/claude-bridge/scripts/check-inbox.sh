#!/usr/bin/env bash
# scripts/check-inbox.sh — Check ALL session inboxes for pending messages.
# Does NOT depend on working directory — scans ~/.claude/bridge/sessions/ directly.
# Usage: check-inbox.sh [--summary-only]
# Env: BRIDGE_DIR (default: ~/.claude/bridge)
set -euo pipefail

SUMMARY_ONLY=false
if [ "${1:-}" = "--summary-only" ]; then
  SUMMARY_ONLY=true
fi

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
SESSIONS_DIR="$BRIDGE_DIR/sessions"

# No sessions at all — exit silently
if [ ! -d "$SESSIONS_DIR" ]; then
  echo '{"continue": true}'
  exit 0
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Summary-only mode: output state for ALL sessions
if [ "$SUMMARY_ONLY" = true ]; then
  SESSION_INFO=""
  for MANIFEST in "$SESSIONS_DIR"/*/manifest.json; do
    [ -f "$MANIFEST" ] || continue
    SID=$(jq -r '.sessionId' "$MANIFEST")
    SNAME=$(jq -r '.projectName' "$MANIFEST")
    SESSION_INFO="${SESSION_INFO}\n- ${SNAME} (${SID})"
  done

  if [ -z "$SESSION_INFO" ]; then
    echo '{"continue": true}'
    exit 0
  fi

  SUMMARY="=== CLAUDE BRIDGE STATE ===\nActive sessions:${SESSION_INFO}\n\nTo send messages, use Bash: \${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh <peer-id> <type> \"<content>\" [in-reply-to]\n=== END BRIDGE ==="
  jq -n --arg msg "$SUMMARY" '{continue: true, suppressOutput: false, systemMessage: $msg}'
  exit 0
fi

# Normal mode: scan ALL sessions for pending inbox messages
ALL_MESSAGES=""
TOTAL_COUNT=0

for SESSION_DIR in "$SESSIONS_DIR"/*/; do
  [ -d "$SESSION_DIR" ] || continue
  INBOX="$SESSION_DIR/inbox"
  [ -d "$INBOX" ] || continue

  SESSION_ID=$(basename "$SESSION_DIR")
  SESSION_NAME="unknown"
  MANIFEST="$SESSION_DIR/manifest.json"
  if [ -f "$MANIFEST" ]; then
    SESSION_NAME=$(jq -r '.projectName // "unknown"' "$MANIFEST")
    # Note: heartbeat is updated by the watcher (bridge-watcher.sh), not here.
    # This script scans ALL sessions and should not touch other sessions' manifests.
  fi

  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    MSG_ID=$(jq -r '.id' "$MSG_FILE")
    FROM_ID=$(jq -r '.from' "$MSG_FILE")
    MSG_TYPE=$(jq -r '.type' "$MSG_FILE")
    CONTENT=$(jq -r '.content' "$MSG_FILE")
    FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE")
    TO_ID=$(jq -r '.to' "$MSG_FILE")
    IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$MSG_FILE")

    # Find the project name for the recipient
    TO_NAME="$SESSION_NAME"

    ALL_MESSAGES="${ALL_MESSAGES}\n--- Message for '${TO_NAME}' (${TO_ID}) from '${FROM_PROJECT}' (${FROM_ID}) [${MSG_TYPE}] ---"
    ALL_MESSAGES="${ALL_MESSAGES}\nMessage ID: ${MSG_ID}"
    if [ -n "$IN_REPLY_TO" ] && [ "$IN_REPLY_TO" != "null" ]; then
      ALL_MESSAGES="${ALL_MESSAGES}\nIn reply to: ${IN_REPLY_TO}"
    fi
    ALL_MESSAGES="${ALL_MESSAGES}\nContent: ${CONTENT}"
    ALL_MESSAGES="${ALL_MESSAGES}\n"
    ALL_MESSAGES="${ALL_MESSAGES}\nTo respond: BRIDGE_SESSION_ID=${TO_ID} bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh\" ${FROM_ID} response \"Your answer\" ${MSG_ID}"
    ALL_MESSAGES="${ALL_MESSAGES}\n"

    # Mark as read
    TMP=$(mktemp "$INBOX/${MSG_ID}.XXXXXX")
    jq '.status = "read"' "$MSG_FILE" > "$TMP"
    mv "$TMP" "$MSG_FILE"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
  done
done

if [ "$TOTAL_COUNT" -eq 0 ]; then
  echo '{"continue": true}'
  exit 0
fi

SYSTEM_MSG="=== CLAUDE BRIDGE: ${TOTAL_COUNT} pending message(s) ===\nYou MUST respond to queries and acknowledge pings before doing anything else.${ALL_MESSAGES}\n=== END BRIDGE ==="

jq -n --arg msg "$SYSTEM_MSG" '{continue: true, suppressOutput: false, systemMessage: $msg}'
