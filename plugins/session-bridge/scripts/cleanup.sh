#!/usr/bin/env bash
# scripts/cleanup.sh — Clean up session on exit. Notify connected peers.
#
# Multi-session aware: resolves THIS agent session's bridge session ID only
# (never a same-repo peer's), notifies its connected peers, removes only its
# own session dir and pointer files, then sweeps stale sessions.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
LEGACY_POINTER="$PROJECT_DIR/.claude/bridge-session"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SESSION_KEY=$(bash "$SCRIPT_DIR/get-session-key.sh")
POINTER_FILE="$PROJECT_DIR/.claude/bridge-sessions/$SESSION_KEY"

# Find THIS agent session's bridge session ID only — never a same-repo peer's.
# Priority: (a) env override, (b) per-session pointer (walk up from
# PROJECT_DIR, validating the manifest), (c) legacy single pointer,
# (d) manifest scan for projectPath == PROJECT_DIR.
SESSION_ID=""
if [ -n "${BRIDGE_SESSION_ID:-}" ] && [ -f "$BRIDGE_DIR/sessions/$BRIDGE_SESSION_ID/manifest.json" ]; then
  SESSION_ID="$BRIDGE_SESSION_ID"
else
  DIR="$PROJECT_DIR"
  while true; do
    POINTER="$DIR/.claude/bridge-sessions/$SESSION_KEY"
    if [ -f "$POINTER" ]; then
      SID=$(cat "$POINTER")
      if [ -f "$BRIDGE_DIR/sessions/$SID/manifest.json" ]; then
        SESSION_ID="$SID"
        POINTER_FILE="$POINTER"
        break
      fi
    fi
    [ "$DIR" = "/" ] && break
    DIR=$(dirname "$DIR")
  done
  if [ -z "$SESSION_ID" ] && [ -f "$LEGACY_POINTER" ]; then
    SID=$(cat "$LEGACY_POINTER")
    if [ -f "$BRIDGE_DIR/sessions/$SID/manifest.json" ]; then
      SESSION_ID="$SID"
    fi
  fi
  if [ -z "$SESSION_ID" ]; then
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
      bash "$SCRIPT_DIR/send-message.sh" "$PEER_ID" session-ended "Session ended" > /dev/null 2>&1 || true
  fi
done

# Remove only the caller's own session directory
rm -rf "$SESSION_DIR"

# Remove only the caller's own per-session pointer (a same-repo peer has its
# own pointer file under bridge-sessions/ — leave those alone)
if [ -f "$POINTER_FILE" ] && [ "$(cat "$POINTER_FILE")" = "$SESSION_ID" ]; then
  rm -f "$POINTER_FILE"
fi

# Remove the legacy pointer only if it points at OUR session (a same-repo
# peer may have written its own ID there before migrating)
if [ -f "$LEGACY_POINTER" ] && [ "$(cat "$LEGACY_POINTER")" = "$SESSION_ID" ]; then
  rm -f "$LEGACY_POINTER"
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
