#!/usr/bin/env bash
# scripts/auto-join.sh — Automatically rejoin a bridge project on session start.
# Called by the SessionStart hook. Checks for .claude/bridge-role in the
# current project directory. If found, silently rejoins the project with
# the persisted role/specialty/name.
# Outputs JSON for the hook system. Produces a systemMessage on successful join.
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_ROLE_FILE="$PROJECT_DIR/.claude/bridge-role"

# No saved config — nothing to do
if [ ! -f "$BRIDGE_ROLE_FILE" ]; then
  echo '{"continue": true}'
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo '{"continue": true}'; exit 0; }

PROJECT_NAME=$(jq -r '.project // ""' "$BRIDGE_ROLE_FILE" 2>/dev/null)
if [ -z "$PROJECT_NAME" ]; then
  echo '{"continue": true}'
  exit 0
fi

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"

# Verify project still exists
if [ ! -d "$BRIDGE_DIR/projects/$PROJECT_NAME" ]; then
  echo '{"continue": true}'
  exit 0
fi

# Rejoin — project-join.sh reads role/specialty/name from bridge-role automatically
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/project-join.sh" "$PROJECT_NAME" 2>/dev/null) || {
  echo '{"continue": true}'
  exit 0
}

# Read back the manifest for the status message
ROLE=$(jq -r '.role // "specialist"' "$BRIDGE_ROLE_FILE")
SPECIALTY=$(jq -r '.specialty // ""' "$BRIDGE_ROLE_FILE")
SESSION_NAME=$(jq -r '.name // ""' "$BRIDGE_ROLE_FILE")

# Count active peers
PEER_COUNT=0
for MANIFEST in "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions"/*/manifest.json; do
  [ -f "$MANIFEST" ] || continue
  PEER_COUNT=$((PEER_COUNT + 1))
done
PEER_COUNT=$((PEER_COUNT - 1))  # Exclude self

MSG="=== BRIDGE AUTO-JOINED ===\nProject: ${PROJECT_NAME}\nSession: ${SESSION_ID} (${SESSION_NAME})\nRole: ${ROLE}"
if [ -n "$SPECIALTY" ]; then
  MSG="${MSG}\nSpecialty: ${SPECIALTY}"
fi
if [ "$PEER_COUNT" -gt 0 ]; then
  MSG="${MSG}\n${PEER_COUNT} peer(s) online"
fi
MSG="${MSG}\n=== END BRIDGE ==="

jq -n --arg msg "$MSG" '{continue: true, suppressOutput: false, systemMessage: $msg}'
