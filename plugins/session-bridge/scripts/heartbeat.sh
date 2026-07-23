#!/usr/bin/env bash
# scripts/heartbeat.sh — Update lastHeartbeat in manifest.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve this agent session's ID via the shared resolver; nothing to do if none
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" \
  bash "$SCRIPT_DIR/get-session-id.sh" 2>/dev/null || echo "")
[ -n "$SESSION_ID" ] || exit 0

MANIFEST="$BRIDGE_DIR/sessions/$SESSION_ID/manifest.json"
[ -f "$MANIFEST" ] || exit 0

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$BRIDGE_DIR/sessions/$SESSION_ID/manifest.XXXXXX")
jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"
