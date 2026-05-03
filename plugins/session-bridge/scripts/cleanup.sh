#!/usr/bin/env bash
# scripts/cleanup.sh — Clean up session on exit. Notify connected peers.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find session ID — prefer env var (per-process), then file, then scan
SESSION_ID="${BRIDGE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
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
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi
SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"

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

# Only remove bridge-session pointer if it still points to THIS session.
# Another session in the same repo may have overwritten it with their own ID.
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  FILE_ID=$(cat "$BRIDGE_SESSION_FILE")
  if [ "$FILE_ID" = "$SESSION_ID" ]; then
    rm -f "$BRIDGE_SESSION_FILE"
  fi
fi

# Clean up stale sessions (heartbeat older than 30 minutes)
STALE_CUTOFF=$(date -u -v-30M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "30 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$STALE_CUTOFF" ]; then
  for STALE_MANIFEST in "$BRIDGE_DIR"/sessions/*/manifest.json; do
    [ -f "$STALE_MANIFEST" ] || continue
    STALE_DIR=$(dirname "$STALE_MANIFEST")
    STALE_HB=$(jq -r '.lastHeartbeat // ""' "$STALE_MANIFEST" 2>/dev/null || echo "")
    if [ -n "$STALE_HB" ] && [[ "$STALE_HB" < "$STALE_CUTOFF" ]]; then
      rm -rf "$STALE_DIR"
    fi
  done
fi
