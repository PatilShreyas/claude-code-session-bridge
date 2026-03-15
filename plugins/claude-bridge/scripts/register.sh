#!/usr/bin/env bash
# scripts/register.sh — Register this session as a bridge peer.
# Env: BRIDGE_DIR (default: ~/.claude/bridge), PROJECT_DIR (default: pwd)
# Outputs: session ID to stdout
# If a bridge session already exists for this project and has an active watcher,
# outputs the existing session ID instead of creating a new one.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install with: brew install jq (macOS) or apt install jq (Linux)" >&2; exit 1; }

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"

# Check if a bridge session already exists for this project
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  EXISTING_ID=$(cat "$BRIDGE_SESSION_FILE")
  EXISTING_DIR="$BRIDGE_DIR/sessions/$EXISTING_ID"
  EXISTING_PID_FILE="$EXISTING_DIR/watcher.pid"

  if [ -d "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/manifest.json" ]; then
    # Session directory exists — check if watcher is still alive
    if [ -f "$EXISTING_PID_FILE" ] && kill -0 "$(cat "$EXISTING_PID_FILE")" 2>/dev/null; then
      # Active watcher running — reuse this session
      echo "EXISTING:$EXISTING_ID" >&2
      echo -n "$EXISTING_ID"
      exit 0
    fi
    # Session exists but no active watcher — reclaim it by updating heartbeat
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TMP=$(mktemp "$EXISTING_DIR/manifest.XXXXXX")
    jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$EXISTING_DIR/manifest.json" > "$TMP"
    mv "$TMP" "$EXISTING_DIR/manifest.json"
    echo "RECLAIMED:$EXISTING_ID" >&2
    echo -n "$EXISTING_ID"
    exit 0
  fi
  # Stale pointer — session dir is gone. Will create new one below.
fi

# Generate 6-char lowercase alphanumeric session ID
SESSION_ID=$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)

SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR/inbox" "$SESSION_DIR/outbox"

# Write manifest atomically
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MANIFEST_TMP=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
cat > "$MANIFEST_TMP" <<MANIFEST
{
  "sessionId": "$SESSION_ID",
  "projectName": "$PROJECT_NAME",
  "projectPath": "$PROJECT_DIR",
  "startedAt": "$NOW",
  "lastHeartbeat": "$NOW",
  "status": "active",
  "capabilities": ["query", "context-dump", "conversation"]
}
MANIFEST
mv "$MANIFEST_TMP" "$SESSION_DIR/manifest.json"

# Write bridge-session pointer
mkdir -p "$PROJECT_DIR/.claude"
echo -n "$SESSION_ID" > "$BRIDGE_SESSION_FILE"

# Write to CLAUDE_ENV_FILE if available
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "BRIDGE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
fi

echo "NEW:$SESSION_ID" >&2
echo -n "$SESSION_ID"
