#!/usr/bin/env bash
# scripts/register.sh — Register this session as a bridge peer.
# Usage: register.sh [--as <label>]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), PROJECT_DIR (default: pwd)
#      BRIDGE_SESSION_KEY (override session identity), BRIDGE_LABEL (peer label)
# Outputs: session ID to stdout
#
# Sessions are keyed by AGENT SESSION, not by project directory: each agent
# session gets its own pointer in .claude/bridge-sessions/<session-key>, so two
# agents working in the same repo register as distinct peers. Re-registering
# from the same agent session reuses its existing bridge session.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install with: brew install jq (macOS) or apt install jq (Linux)" >&2; exit 1; }

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --as) LABEL="${2:?--as requires a label}"; shift 2 ;;
    --as=*) LABEL="${1#--as=}"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
LABEL="${LABEL:-${BRIDGE_LABEL:-}}"

SESSION_KEY=$(bash "$SCRIPT_DIR/get-session-key.sh")
POINTERS_DIR="$PROJECT_DIR/.claude/bridge-sessions"
POINTER_FILE="$POINTERS_DIR/$SESSION_KEY"

# Reuse existing session if THIS agent session already has a valid one
if [ -f "$POINTER_FILE" ]; then
  EXISTING_ID=$(cat "$POINTER_FILE")
  EXISTING_DIR="$BRIDGE_DIR/sessions/$EXISTING_ID"

  if [ -d "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/manifest.json" ]; then
    # Update heartbeat (and label if a new one was given) and reuse
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TMP=$(mktemp "$EXISTING_DIR/manifest.XXXXXX")
    if [ -n "$LABEL" ]; then
      jq --arg hb "$NOW" --arg lb "$LABEL" '.lastHeartbeat = $hb | .label = $lb' "$EXISTING_DIR/manifest.json" > "$TMP"
    else
      jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$EXISTING_DIR/manifest.json" > "$TMP"
    fi
    mv "$TMP" "$EXISTING_DIR/manifest.json"
    echo -n "$EXISTING_ID"
    exit 0
  fi
fi

# Default label: current git branch (same-repo sessions are usually on different branches)
if [ -z "$LABEL" ]; then
  LABEL=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

# Create new session
SESSION_ID=$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)

SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR/inbox" "$SESSION_DIR/outbox"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MANIFEST_TMP=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
jq -n \
  --arg sid "$SESSION_ID" \
  --arg pname "$PROJECT_NAME" \
  --arg ppath "$PROJECT_DIR" \
  --arg label "$LABEL" \
  --arg now "$NOW" \
  '{
    sessionId: $sid,
    projectName: $pname,
    projectPath: $ppath,
    label: $label,
    startedAt: $now,
    lastHeartbeat: $now,
    status: "active",
    capabilities: ["query", "context-dump", "conversation"]
  }' > "$MANIFEST_TMP"
mv "$MANIFEST_TMP" "$SESSION_DIR/manifest.json"

mkdir -p "$POINTERS_DIR"
echo -n "$SESSION_ID" > "$POINTER_FILE"

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "BRIDGE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
  echo "BRIDGE_SESSION_KEY=$SESSION_KEY" >> "$CLAUDE_ENV_FILE"
fi

echo -n "$SESSION_ID"
