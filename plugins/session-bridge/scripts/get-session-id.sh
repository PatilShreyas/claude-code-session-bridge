#!/usr/bin/env bash
# scripts/get-session-id.sh — Reliably find THIS agent session's bridge session ID.
# Works even if the agent cd'd into a subdirectory.
#
# Strategy:
# 1. $BRIDGE_SESSION_ID env, if it points to a live session
# 2. Per-session pointer .claude/bridge-sessions/<session-key>, walking up from cwd
# 3. Legacy single pointer .claude/bridge-session in cwd (pre-multisession installs)
# 4. Scan all session manifests for one whose projectPath is a parent of $(pwd)
#    (ambiguous when several sessions share a repo — used only as a last resort)
#
# Outputs: session ID to stdout, or exits 1 if not found.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
CURRENT_DIR="${PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Env override (written to CLAUDE_ENV_FILE at register time)
if [ -n "${BRIDGE_SESSION_ID:-}" ] && [ -f "$BRIDGE_DIR/sessions/$BRIDGE_SESSION_ID/manifest.json" ]; then
  echo -n "$BRIDGE_SESSION_ID"
  exit 0
fi

# 2. Per-session pointer, walking up from cwd to find the project root
SESSION_KEY=$(bash "$SCRIPT_DIR/get-session-key.sh")
DIR="$CURRENT_DIR"
while true; do
  POINTER="$DIR/.claude/bridge-sessions/$SESSION_KEY"
  if [ -f "$POINTER" ]; then
    SID=$(cat "$POINTER")
    if [ -f "$BRIDGE_DIR/sessions/$SID/manifest.json" ]; then
      echo -n "$SID"
      exit 0
    fi
  fi
  [ "$DIR" = "/" ] && break
  DIR=$(dirname "$DIR")
done

# 3. Legacy single pointer in cwd (backwards compatibility)
if [ -f "$CURRENT_DIR/.claude/bridge-session" ]; then
  SID=$(cat "$CURRENT_DIR/.claude/bridge-session")
  if [ -f "$BRIDGE_DIR/sessions/$SID/manifest.json" ]; then
    echo -n "$SID"
    exit 0
  fi
fi

# 4. Fallback: scan all session manifests for one whose projectPath is a parent
# of current dir. With multiple sessions in one repo this is ambiguous — the
# per-session pointer above is the reliable path.
for MANIFEST in "$BRIDGE_DIR"/sessions/*/manifest.json; do
  [ -f "$MANIFEST" ] || continue
  PROJ_PATH=$(jq -r '.projectPath // ""' "$MANIFEST" 2>/dev/null)
  [ -n "$PROJ_PATH" ] || continue

  # Check: is our current directory inside (or equal to) this project's path?
  case "$CURRENT_DIR" in
    "$PROJ_PATH"|"$PROJ_PATH"/*)
      jq -r '.sessionId' "$MANIFEST"
      exit 0
      ;;
  esac
done

# Not found
echo "NO_BRIDGE_SESSION" >&2
exit 1
