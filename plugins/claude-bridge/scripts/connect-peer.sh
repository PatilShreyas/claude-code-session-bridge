#!/usr/bin/env bash
# scripts/connect-peer.sh — Connect to a peer by sending a ping.
set -euo pipefail

TARGET_ID="$1"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
SENDER_ID="${BRIDGE_SESSION_ID:?BRIDGE_SESSION_ID must be set}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET_MANIFEST="$BRIDGE_DIR/sessions/$TARGET_ID/manifest.json"

if [ ! -f "$TARGET_MANIFEST" ]; then
  echo "Error: Session $TARGET_ID not found." >&2
  exit 1
fi

PEER_NAME=$(jq -r '.projectName' "$TARGET_MANIFEST")
PEER_PATH=$(jq -r '.projectPath' "$TARGET_MANIFEST")

# Check for staleness (>5 min since last heartbeat)
PEER_HB=$(jq -r '.lastHeartbeat' "$TARGET_MANIFEST")
NOW_EPOCH=$(date -u +%s)
HB_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$PEER_HB" +%s 2>/dev/null || date -u -d "$PEER_HB" +%s 2>/dev/null || echo "0")
AGE=$((NOW_EPOCH - HB_EPOCH))
if [ "$AGE" -gt 300 ]; then
  echo "Warning: Session $TARGET_ID appears stale (last active ${AGE}s ago). Connecting anyway." >&2
fi

# Send ping via send-message.sh
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" \
  bash "$SCRIPT_DIR/send-message.sh" "$TARGET_ID" ping "connected" > /dev/null

echo "Connected to '$PEER_NAME' ($TARGET_ID) at $PEER_PATH"
