#!/usr/bin/env bash
# scripts/inbox-watcher.sh — Background inbox watcher + heartbeat.
# Usage: inbox-watcher.sh <session-id> <project-id>
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Runs until killed. Watches inbox for new files, prints terminal notifications.
# Updates heartbeat every 60 seconds.
set -euo pipefail

SESSION_ID="${1:?Usage: inbox-watcher.sh <session-id> <project-id>}"
PROJECT_ID="${2:?Usage: inbox-watcher.sh <session-id> <project-id>}"

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
INBOX="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID/inbox"
MANIFEST="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID/manifest.json"

if [ ! -d "$INBOX" ]; then
  echo "Error: Inbox not found for session $SESSION_ID" >&2
  exit 1
fi

# Heartbeat update function
update_heartbeat() {
  [ -f "$MANIFEST" ] || return
  local NOW
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local TMP
  TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX")
  jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP" 2>/dev/null && mv "$TMP" "$MANIFEST" || rm -f "$TMP"
}

LAST_HEARTBEAT=$(date +%s)
HEARTBEAT_INTERVAL=60

# Detect watcher tool
if command -v inotifywait >/dev/null 2>&1; then
  WATCHER="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
  WATCHER="fswatch"
else
  WATCHER="poll"
fi

# Graceful shutdown
RUNNING=true
trap 'RUNNING=false' TERM INT

while $RUNNING; do
  # Heartbeat check
  NOW_EPOCH=$(date +%s)
  if [ $((NOW_EPOCH - LAST_HEARTBEAT)) -ge $HEARTBEAT_INTERVAL ]; then
    update_heartbeat
    LAST_HEARTBEAT=$NOW_EPOCH
  fi

  case "$WATCHER" in
    inotifywait)
      # Block until file created or 30s timeout (then loop back for heartbeat check)
      inotifywait -t 30 -e create "$INBOX" >/dev/null 2>&1 || true
      ;;
    fswatch)
      timeout 30 fswatch --one-event "$INBOX" >/dev/null 2>&1 || true
      ;;
    poll)
      sleep 10 &
      wait $! 2>/dev/null || true
      ;;
  esac

  $RUNNING || break

  # Check for new pending messages and notify
  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    FROM=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE" 2>/dev/null)
    TYPE=$(jq -r '.type' "$MSG_FILE" 2>/dev/null)

    if [ "$TYPE" = "human-input-needed" ]; then
      printf '\n>> DECISION NEEDED from "%s" — run /bridge decisions or press Enter.\a\n' "$FROM" >&2
    else
      printf '\n>> Bridge: %s from "%s" — press Enter to process.\a\n' "$TYPE" "$FROM" >&2
    fi
    break  # Notify once per cycle
  done
done
