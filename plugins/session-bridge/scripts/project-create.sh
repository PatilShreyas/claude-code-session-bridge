#!/usr/bin/env bash
# scripts/project-create.sh — Create a new multi-session project.
# Usage: project-create.sh <project-name>
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Outputs: project name to stdout
# Errors: exit 1 if project already exists
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_NAME="${1:?Usage: project-create.sh <project-name>}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME"

if [ -d "$PROJECT_DIR" ]; then
  echo "Error: Project '$PROJECT_NAME' already exists." >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/conversations" "$PROJECT_DIR/sessions"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$PROJECT_DIR/project.XXXXXX")
jq -n \
  --arg pid "$PROJECT_NAME" \
  --arg now "$NOW" \
  '{
    projectId: $pid,
    name: $pid,
    createdAt: $now,
    createdBy: null,
    topology: {}
  }' > "$TMP"
mv "$TMP" "$PROJECT_DIR/project.json"

echo -n "$PROJECT_NAME"
