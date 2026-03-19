#!/usr/bin/env bash
# scripts/check-inbox.sh — Check session inbox for pending messages.
# v2: rate limiting, early exit for non-bridge sessions, project-scoped scanning.
# Usage: check-inbox.sh [--rate-limited] [--summary-only]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), BRIDGE_SESSION_ID, PROJECT_DIR
set -euo pipefail

# --- 1. Parse flags ---
RATE_LIMITED=false
SUMMARY_ONLY=false
case "${1:-}" in
  --rate-limited) RATE_LIMITED=true ;;
  --summary-only) SUMMARY_ONLY=true ;;
esac

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"

# --- 2. Early exit for non-bridge sessions ---
# If neither BRIDGE_SESSION_ID env nor .claude/bridge-session file exists, this
# session has no bridge registration. Exit immediately with zero cost.
if [ -z "${BRIDGE_SESSION_ID:-}" ] && [ ! -f "${PROJECT_DIR:-.}/.claude/bridge-session" ]; then
  echo '{"continue": true}'
  exit 0
fi

# --- 3. Resolve this session's ID and inbox path ---
MY_SESSION_ID="${BRIDGE_SESSION_ID:-$(cat "${PROJECT_DIR:-.}/.claude/bridge-session" 2>/dev/null || echo "")}"
MY_INBOX=""
MY_PROJECT_ID=""
SESSIONS_DIR=""

# Check project-scoped sessions first
if [ -n "$MY_SESSION_ID" ]; then
  for PM in "$BRIDGE_DIR"/projects/*/sessions/"$MY_SESSION_ID"/manifest.json; do
    [ -f "$PM" ] || continue
    MY_PROJECT_ID=$(jq -r '.projectId' "$PM")
    MY_INBOX="$BRIDGE_DIR/projects/$MY_PROJECT_ID/sessions/$MY_SESSION_ID/inbox"
    SESSIONS_DIR="$BRIDGE_DIR/projects/$MY_PROJECT_ID/sessions"
    break
  done
fi

# Fall back to legacy flat sessions directory
if [ -z "$MY_INBOX" ] && [ -n "$MY_SESSION_ID" ]; then
  MY_INBOX="$BRIDGE_DIR/sessions/$MY_SESSION_ID/inbox"
  SESSIONS_DIR="$BRIDGE_DIR/sessions"
fi

# If we still can't resolve an inbox, exit cleanly
if [ -z "$MY_INBOX" ] || [ ! -d "$MY_INBOX" ]; then
  # For legacy mode without project: scan all sessions (backward compat)
  if [ -z "$MY_PROJECT_ID" ] && [ -d "$BRIDGE_DIR/sessions" ]; then
    SESSIONS_DIR="$BRIDGE_DIR/sessions"
  else
    echo '{"continue": true}'
    exit 0
  fi
fi

# --- 4. Rate limiting (only with --rate-limited flag) ---
if [ "$RATE_LIMITED" = true ]; then
  LAST_CHECK_FILE="$BRIDGE_DIR/.last_inbox_check"
  NOW_EPOCH=$(date +%s)
  LAST=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)
  if [ $((NOW_EPOCH - LAST)) -lt 5 ]; then
    # Check for critical urgency messages (fast grep, no jq)
    # Handle both compact ("urgency":"critical") and pretty-printed ("urgency": "critical") JSON
    HAS_CRITICAL=$(grep -rl '"urgency":[[:space:]]*"critical"' "$MY_INBOX"/*.json 2>/dev/null | head -1 || true)
    if [ -z "$HAS_CRITICAL" ]; then
      echo '{"continue": true}'
      exit 0
    fi
  fi
  echo "$NOW_EPOCH" > "$LAST_CHECK_FILE"
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- 5. Summary-only mode ---
if [ "$SUMMARY_ONLY" = true ]; then
  SESSION_INFO=""

  if [ -n "$MY_PROJECT_ID" ]; then
    # Project-scoped: include project context, conversations, peers
    for MANIFEST in "$SESSIONS_DIR"/*/manifest.json; do
      [ -f "$MANIFEST" ] || continue
      SID=$(jq -r '.sessionId' "$MANIFEST")
      SNAME=$(jq -r '.projectName' "$MANIFEST")
      SROLE=$(jq -r '.role // "unknown"' "$MANIFEST")
      SSTATUS=$(jq -r '.status // "unknown"' "$MANIFEST")
      SESSION_INFO="${SESSION_INFO}\n- ${SNAME} (${SID}) [${SROLE}, ${SSTATUS}]"
    done

    # Active conversations
    CONV_INFO=""
    CONV_DIR="$BRIDGE_DIR/projects/$MY_PROJECT_ID/conversations"
    if [ -d "$CONV_DIR" ]; then
      for CONV_FILE in "$CONV_DIR"/conv-*.json; do
        [ -f "$CONV_FILE" ] || continue
        CSTATUS=$(jq -r '.status' "$CONV_FILE")
        [ "$CSTATUS" = "resolved" ] && continue
        CID=$(jq -r '.conversationId' "$CONV_FILE")
        CTOPIC=$(jq -r '.topic' "$CONV_FILE")
        CONV_INFO="${CONV_INFO}\n- ${CID}: ${CTOPIC} [${CSTATUS}]"
      done
    fi

    SUMMARY="=== CLAUDE BRIDGE STATE ===\nProject: ${MY_PROJECT_ID}\nSession: ${MY_SESSION_ID}\nActive sessions:${SESSION_INFO}"
    if [ -n "$CONV_INFO" ]; then
      SUMMARY="${SUMMARY}\n\nActive conversations:${CONV_INFO}"
    fi
    SUMMARY="${SUMMARY}\n\nTo send messages, use Bash: \${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh <peer-id> <type> \"<content>\" [in-reply-to]\n=== END BRIDGE ==="
  else
    # Legacy: scan all sessions
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
  fi

  jq -n --arg msg "$SUMMARY" '{continue: true, suppressOutput: false, systemMessage: $msg}'
  exit 0
fi

# --- 6. Normal mode: scan for pending inbox messages ---
ALL_MESSAGES=""
TOTAL_COUNT=0

if [ -n "$MY_PROJECT_ID" ]; then
  # Project-scoped: only scan this session's own inbox
  INBOX="$MY_INBOX"
  if [ -d "$INBOX" ]; then
    SESSION_NAME="unknown"
    MANIFEST="$SESSIONS_DIR/$MY_SESSION_ID/manifest.json"
    if [ -f "$MANIFEST" ]; then
      SESSION_NAME=$(jq -r '.projectName // "unknown"' "$MANIFEST")
    fi

    for MSG_FILE in "$INBOX"/*.json; do
      [ -f "$MSG_FILE" ] || continue
      STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
      [ "$STATUS" = "pending" ] || continue

      MSG_ID=$(jq -r '.id' "$MSG_FILE")
      FROM_ID=$(jq -r '.from' "$MSG_FILE")
      TO_ID=$(jq -r '.to' "$MSG_FILE")
      MSG_TYPE=$(jq -r '.type' "$MSG_FILE")
      CONTENT=$(jq -r '.content' "$MSG_FILE")
      FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE")
      IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$MSG_FILE")
      CONV_ID=$(jq -r '.conversationId // ""' "$MSG_FILE")
      MSG_URGENCY=$(jq -r '.metadata.urgency // "normal"' "$MSG_FILE")

      TO_NAME="$SESSION_NAME"

      ALL_MESSAGES="${ALL_MESSAGES}\n--- Message for '${TO_NAME}' (${TO_ID}) from '${FROM_PROJECT}' (${FROM_ID}) [${MSG_TYPE}] ---"
      ALL_MESSAGES="${ALL_MESSAGES}\nMessage ID: ${MSG_ID}"
      if [ -n "$CONV_ID" ] && [ "$CONV_ID" != "null" ]; then
        ALL_MESSAGES="${ALL_MESSAGES}\nConversation: ${CONV_ID}"
      fi
      if [ -n "$IN_REPLY_TO" ] && [ "$IN_REPLY_TO" != "null" ]; then
        ALL_MESSAGES="${ALL_MESSAGES}\nIn reply to: ${IN_REPLY_TO}"
      fi
      if [ "$MSG_URGENCY" != "normal" ]; then
        ALL_MESSAGES="${ALL_MESSAGES}\nUrgency: ${MSG_URGENCY}"
      fi
      ALL_MESSAGES="${ALL_MESSAGES}\nContent: ${CONTENT}"
      ALL_MESSAGES="${ALL_MESSAGES}\n"
      ALL_MESSAGES="${ALL_MESSAGES}\nTo respond: BRIDGE_SESSION_ID=${TO_ID} bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh\" ${FROM_ID} response \"Your answer\" --reply-to ${MSG_ID} --conversation ${CONV_ID}"
      ALL_MESSAGES="${ALL_MESSAGES}\n"

      # Mark as read
      TMP=$(mktemp "$INBOX/${MSG_ID}.XXXXXX")
      jq '.status = "read"' "$MSG_FILE" > "$TMP"
      mv "$TMP" "$MSG_FILE"

      TOTAL_COUNT=$((TOTAL_COUNT + 1))
    done
  fi
else
  # Legacy mode: scan ALL sessions for pending inbox messages
  for SESSION_DIR in "$SESSIONS_DIR"/*/; do
    [ -d "$SESSION_DIR" ] || continue
    INBOX="$SESSION_DIR/inbox"
    [ -d "$INBOX" ] || continue

    SESSION_ID=$(basename "$SESSION_DIR")
    SESSION_NAME="unknown"
    MANIFEST="$SESSION_DIR/manifest.json"
    if [ -f "$MANIFEST" ]; then
      SESSION_NAME=$(jq -r '.projectName // "unknown"' "$MANIFEST")
    fi

    for MSG_FILE in "$INBOX"/*.json; do
      [ -f "$MSG_FILE" ] || continue
      STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
      [ "$STATUS" = "pending" ] || continue

      MSG_ID=$(jq -r '.id' "$MSG_FILE")
      FROM_ID=$(jq -r '.from' "$MSG_FILE")
      TO_ID=$(jq -r '.to' "$MSG_FILE")
      MSG_TYPE=$(jq -r '.type' "$MSG_FILE")
      CONTENT=$(jq -r '.content' "$MSG_FILE")
      FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE")
      IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$MSG_FILE")

      # Skip messages not addressed to this session
      if [ "$TO_ID" != "$SESSION_ID" ]; then
        continue
      fi

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
fi

if [ "$TOTAL_COUNT" -eq 0 ]; then
  echo '{"continue": true}'
  exit 0
fi

SYSTEM_MSG="=== CLAUDE BRIDGE: ${TOTAL_COUNT} pending message(s) ===\nYou MUST respond to queries and acknowledge pings before doing anything else.${ALL_MESSAGES}\n=== END BRIDGE ==="

jq -n --arg msg "$SYSTEM_MSG" '{continue: true, suppressOutput: false, systemMessage: $msg}'
