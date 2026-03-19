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

# Parse optional args — track which flags were explicitly provided
ROLE=""
SPECIALTY=""
CUSTOM_NAME=""
ROLE_SET=false
SPECIALTY_SET=false
NAME_SET=false
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; ROLE_SET=true; shift 2 ;;
    --specialty) SPECIALTY="$2"; SPECIALTY_SET=true; shift 2 ;;
    --name) CUSTOM_NAME="$2"; NAME_SET=true; shift 2 ;;
    *) shift ;;
  esac
done

BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"
BRIDGE_ROLE_FILE="$PROJECT_DIR/.claude/bridge-role"

# Load persisted role/specialty if no explicit flags provided
if [ "$ROLE_SET" = false ] && [ -f "$BRIDGE_ROLE_FILE" ]; then
  SAVED_ROLE=$(jq -r '.role // ""' "$BRIDGE_ROLE_FILE" 2>/dev/null)
  [ -n "$SAVED_ROLE" ] && ROLE="$SAVED_ROLE"
fi
if [ "$SPECIALTY_SET" = false ] && [ -f "$BRIDGE_ROLE_FILE" ]; then
  SAVED_SPEC=$(jq -r '.specialty // ""' "$BRIDGE_ROLE_FILE" 2>/dev/null)
  [ -n "$SAVED_SPEC" ] && SPECIALTY="$SAVED_SPEC"
fi
if [ "$NAME_SET" = false ] && [ -f "$BRIDGE_ROLE_FILE" ]; then
  SAVED_NAME=$(jq -r '.name // ""' "$BRIDGE_ROLE_FILE" 2>/dev/null)
  [ -n "$SAVED_NAME" ] && CUSTOM_NAME="$SAVED_NAME"
fi

# Apply defaults for anything still unset
[ -z "$ROLE" ] && ROLE="specialist"
SESSION_NAME="${CUSTOM_NAME:-$(basename "$PROJECT_DIR")}"

# Reuse existing session if bridge-session file points to a valid session in this project
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  EXISTING_ID=$(cat "$BRIDGE_SESSION_FILE")
  EXISTING_DIR="$PROJECT_PATH/sessions/$EXISTING_ID"
  if [ -d "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/manifest.json" ]; then
    # Verify it's in the same project
    EXISTING_PROJECT=$(jq -r '.projectId // ""' "$EXISTING_DIR/manifest.json")
    if [ "$EXISTING_PROJECT" = "$PROJECT_NAME" ]; then
      # Update heartbeat + apply any changed fields
      NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      TMP=$(mktemp "$EXISTING_DIR/manifest.XXXXXX")
      jq --arg hb "$NOW" --arg role "$ROLE" --arg spec "$SPECIALTY" --arg pname "$SESSION_NAME" \
        '.lastHeartbeat = $hb | .role = $role | .specialty = $spec | .projectName = $pname' \
        "$EXISTING_DIR/manifest.json" > "$TMP"
      mv "$TMP" "$EXISTING_DIR/manifest.json"
      # Persist role for future joins
      mkdir -p "$PROJECT_DIR/.claude"
      jq -n --arg role "$ROLE" --arg spec "$SPECIALTY" --arg name "$SESSION_NAME" --arg project "$PROJECT_NAME" \
        '{role: $role, specialty: $spec, name: $name, project: $project}' > "$BRIDGE_ROLE_FILE"
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

# Write bridge-session pointer and persist role
mkdir -p "$PROJECT_DIR/.claude"
echo -n "$SESSION_ID" > "$BRIDGE_SESSION_FILE"
jq -n --arg role "$ROLE" --arg spec "$SPECIALTY" --arg name "$SESSION_NAME" --arg project "$PROJECT_NAME" \
  '{role: $role, specialty: $spec, name: $name, project: $project}' > "$BRIDGE_ROLE_FILE"

# Set BRIDGE_SESSION_ID in env file if available
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "BRIDGE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
fi

# Start inbox watcher in background
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/inbox-watcher.sh"
if [ -f "$WATCHER_SCRIPT" ]; then
  BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER_SCRIPT" "$SESSION_ID" "$PROJECT_NAME" >/dev/null 2>&1 &
  echo $! > "$SESSION_DIR/watcher.pid"
  disown
fi

echo -n "$SESSION_ID"
