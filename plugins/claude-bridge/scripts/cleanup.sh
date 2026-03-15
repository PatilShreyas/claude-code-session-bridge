#!/usr/bin/env bash
# scripts/cleanup.sh — Clean up session on exit. Notify peers.
# SAFETY: Only cleans up if the watcher is NOT running. If a new Claude session
# reclaimed this bridge and started a fresh watcher, we leave it alone.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find session ID: try bridge-session file first, then scan manifests
SESSION_ID=""
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  SESSION_ID=$(cat "$BRIDGE_SESSION_FILE")
else
  for MANIFEST_FILE in "$BRIDGE_DIR"/sessions/*/manifest.json; do
    [ -f "$MANIFEST_FILE" ] || continue
    MANIFEST_PATH=$(jq -r '.projectPath // ""' "$MANIFEST_FILE" 2>/dev/null)
    if [ "$MANIFEST_PATH" = "$PROJECT_DIR" ]; then
      SESSION_ID=$(jq -r '.sessionId' "$MANIFEST_FILE")
      break
    fi
  done
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi
SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"

# SAFETY CHECK: If the watcher is still running, another session owns this bridge.
# Do NOT clean up — just exit quietly.
PID_FILE="$SESSION_DIR/watcher.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  # Watcher is alive — a new session has taken over. Leave everything intact.
  exit 0
fi

# Watcher is dead or doesn't exist — safe to clean up.

# Find connected peers from inbox (senders) and outbox (recipients)
PEER_IDS=""
if [ -d "$SESSION_DIR/inbox" ]; then
  INBOX_PEERS=$(find "$SESSION_DIR/inbox" -name "*.json" \
    -exec jq -r '.from // empty' {} \; 2>/dev/null || true)
  PEER_IDS="${PEER_IDS} ${INBOX_PEERS}"
fi
if [ -d "$SESSION_DIR/outbox" ]; then
  OUTBOX_PEERS=$(find "$SESSION_DIR/outbox" -name "*.json" \
    -exec jq -r '.to // empty' {} \; 2>/dev/null || true)
  PEER_IDS="${PEER_IDS} ${OUTBOX_PEERS}"
fi
PEER_IDS=$(echo "$PEER_IDS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

# Notify each peer
for PEER_ID in $PEER_IDS; do
  if [ -d "$BRIDGE_DIR/sessions/$PEER_ID/inbox" ]; then
    BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" \
      bash "$SCRIPT_DIR/send-message.sh" "$PEER_ID" session-ended "Session ended" 2>/dev/null || true
  fi
done

# Remove session directory
rm -rf "$SESSION_DIR"

# Remove bridge-session pointer
rm -f "$BRIDGE_SESSION_FILE"
