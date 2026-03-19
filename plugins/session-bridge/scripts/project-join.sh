#!/usr/bin/env bash
# scripts/project-join.sh — Register a session within a project.
# Usage: project-join.sh <project-name> [--role <role>] [--specialty "<desc>"] [--name "<name>"]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), PROJECT_DIR (default: pwd)
# Outputs: session ID to stdout
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_NAME="${1:?Usage: project-join.sh <project-name> [--role <role>] [--specialty \"<desc>\"] [--name \"<name>\"]}"
shift

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_PATH="$BRIDGE_DIR/projects/$PROJECT_NAME"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: Project '$PROJECT_NAME' does not exist. Create it first with project-create.sh." >&2
  exit 1
fi

# Parse optional args
ROLE="specialist"
SPECIALTY=""
CUSTOM_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --specialty) SPECIALTY="$2"; shift 2 ;;
    --name) CUSTOM_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SESSION_NAME="${CUSTOM_NAME:-$(basename "$PROJECT_DIR")}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"

# Reuse existing session if bridge-session file points to a valid session in this project
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  EXISTING_ID=$(cat "$BRIDGE_SESSION_FILE")
  EXISTING_DIR="$PROJECT_PATH/sessions/$EXISTING_ID"
  if [ -d "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/manifest.json" ]; then
    # Verify it's in the same project
    EXISTING_PROJECT=$(jq -r '.projectId // ""' "$EXISTING_DIR/manifest.json")
    if [ "$EXISTING_PROJECT" = "$PROJECT_NAME" ]; then
      NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      TMP=$(mktemp "$EXISTING_DIR/manifest.XXXXXX")
      jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$EXISTING_DIR/manifest.json" > "$TMP"
      mv "$TMP" "$EXISTING_DIR/manifest.json"
      echo -n "$EXISTING_ID"
      exit 0
    fi
  fi
fi

# Create new session
SESSION_ID=$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
SESSION_DIR="$PROJECT_PATH/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR/inbox" "$SESSION_DIR/outbox"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
jq -n \
  --arg sid "$SESSION_ID" \
  --arg pid "$PROJECT_NAME" \
  --arg pname "$SESSION_NAME" \
  --arg ppath "$PROJECT_DIR" \
  --arg role "$ROLE" \
  --arg spec "$SPECIALTY" \
  --arg now "$NOW" \
  '{
    sessionId: $sid,
    projectId: $pid,
    projectName: $pname,
    projectPath: $ppath,
    role: $role,
    specialty: $spec,
    startedAt: $now,
    lastHeartbeat: $now,
    status: "active"
  }' > "$TMP"
mv "$TMP" "$SESSION_DIR/manifest.json"

# Write bridge-session pointer
mkdir -p "$PROJECT_DIR/.claude"
echo -n "$SESSION_ID" > "$BRIDGE_SESSION_FILE"

# Set BRIDGE_SESSION_ID in env file if available
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "BRIDGE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
fi

echo -n "$SESSION_ID"
