#!/usr/bin/env bash
# scripts/bridge-listen.sh — Block until a pending message arrives in THIS session's inbox.
# Usage: bridge-listen.sh <session-id> [timeout-seconds]
# If no session-id given, uses get-session-id.sh to find it.
# Uses inotifywait (Linux) or fswatch (macOS) for efficient waiting, falls back to polling.
# Outputs the message details when found.
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
  # No session ID given, try to find it
  SESSION_ID=$(bash "$SCRIPT_DIR/get-session-id.sh" 2>/dev/null) || {
    echo "Error: No bridge session found. Run /bridge start first." >&2
    exit 1
  }
  TIMEOUT="${1:-0}"
fi

# Resolve inbox: project-scoped first, legacy fallback
INBOX=""
for PROJ_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PROJ_MANIFEST" ] || continue
  PROJ_ID=$(jq -r '.projectId' "$PROJ_MANIFEST")
  INBOX="$BRIDGE_DIR/projects/$PROJ_ID/sessions/$SESSION_ID/inbox"
  break
done
[ -z "$INBOX" ] && INBOX="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"

if [ ! -d "$INBOX" ]; then
  echo "Error: Session $SESSION_ID inbox not found." >&2
  exit 1
fi

# Detect filesystem watcher
if command -v inotifywait >/dev/null 2>&1; then
  WATCHER="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
  WATCHER="fswatch"
else
  WATCHER="poll"
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

  # Wait for new files using the best available method
  case "$WATCHER" in
    inotifywait)
      if [ "$TIMEOUT" -gt 0 ]; then
        REMAINING=$((TIMEOUT - ELAPSED))
      else
        REMAINING="$INTERVAL"
      fi
      # Capture exit code — disable set -e for this command since
      # inotifywait returns 2 on timeout which would kill the script
      WATCH_RC=0
      inotifywait -t "$REMAINING" -e create "$INBOX" >/dev/null 2>&1 || WATCH_RC=$?
      if [ "$WATCH_RC" -eq 2 ]; then
        # Timeout — update elapsed and let the loop re-check
        ELAPSED=$((ELAPSED + REMAINING))
        continue
      fi
      # File event detected — update elapsed conservatively and re-scan
      ELAPSED=$((ELAPSED + 1))
      ;;
    fswatch)
      if [ "$TIMEOUT" -gt 0 ]; then
        REMAINING=$((TIMEOUT - ELAPSED))
      else
        REMAINING="$INTERVAL"
      fi
      timeout "$REMAINING" fswatch --one-event "$INBOX" >/dev/null 2>&1 || true
      ELAPSED=$((ELAPSED + REMAINING))
      ;;
    poll)
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
      ;;
  esac
done
