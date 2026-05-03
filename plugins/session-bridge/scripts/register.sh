#!/usr/bin/env bash
# scripts/register.sh — Register this session as a bridge peer.
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), PROJECT_DIR (default: pwd),
#      BRIDGE_SESSION_ID (if set, reuse this session instead of creating a new one)
# Outputs: session ID to stdout
# Each Claude session gets its own bridge — multiple sessions in the same repo are independent.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install with: brew install jq (macOS) or apt install jq (Linux)" >&2; exit 1; }

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"

# Reuse existing session only if BRIDGE_SESSION_ID env var is set and points to a valid session.
# This env var is per-process, so two Claude sessions in the same repo won't collide.
if [ -n "${BRIDGE_SESSION_ID:-}" ]; then
  EXISTING_DIR="$BRIDGE_DIR/sessions/$BRIDGE_SESSION_ID"

  if [ -d "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/manifest.json" ]; then
    # Update heartbeat and reuse
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TMP=$(mktemp "$EXISTING_DIR/manifest.XXXXXX")
    jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$EXISTING_DIR/manifest.json" > "$TMP"
    mv "$TMP" "$EXISTING_DIR/manifest.json"
    echo -n "$BRIDGE_SESSION_ID"
    exit 0
  fi
fi

# Create new session
SESSION_ID=$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)

SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR/inbox" "$SESSION_DIR/outbox"

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

# Write the session file as a convenience pointer (last-registered session for this project).
# Other scripts should prefer BRIDGE_SESSION_ID env var over this file.
mkdir -p "$PROJECT_DIR/.claude"
echo -n "$SESSION_ID" > "$BRIDGE_SESSION_FILE"

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "BRIDGE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
fi

echo -n "$SESSION_ID"
