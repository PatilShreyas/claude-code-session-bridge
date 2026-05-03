#!/usr/bin/env bash
# scripts/get-session-id.sh — Reliably find this session's bridge session ID.
# Works even if the agent cd'd into a subdirectory.
#
# Strategy:
# 1. Check BRIDGE_SESSION_ID env var (per-process, always correct)
# 2. Try .claude/bridge-session file (convenience pointer, may belong to another session)
# 3. Scan all session manifests for one whose projectPath is a parent of $(pwd)
#
# Outputs: session ID to stdout, or exits 1 if not found.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
CURRENT_DIR="${PROJECT_DIR:-$(pwd)}"

# Fast path: env var set by register.sh via CLAUDE_ENV_FILE (per-process, no collisions)
if [ -n "${BRIDGE_SESSION_ID:-}" ]; then
  SESSION_DIR="$BRIDGE_DIR/sessions/$BRIDGE_SESSION_ID"
  if [ -d "$SESSION_DIR" ] && [ -f "$SESSION_DIR/manifest.json" ]; then
    echo -n "$BRIDGE_SESSION_ID"
    exit 0
  fi
fi

# Fallback: .claude/bridge-session file (may point to a different session in the same repo)
if [ -f "$CURRENT_DIR/.claude/bridge-session" ]; then
  FILE_ID=$(cat "$CURRENT_DIR/.claude/bridge-session")
  SESSION_DIR="$BRIDGE_DIR/sessions/$FILE_ID"
  if [ -d "$SESSION_DIR" ] && [ -f "$SESSION_DIR/manifest.json" ]; then
    echo -n "$FILE_ID"
    exit 0
  fi
fi

# Last resort: scan all session manifests for one whose projectPath is a parent of current dir.
for MANIFEST in "$BRIDGE_DIR"/sessions/*/manifest.json; do
  [ -f "$MANIFEST" ] || continue
  PROJ_PATH=$(jq -r '.projectPath // ""' "$MANIFEST" 2>/dev/null)
  [ -n "$PROJ_PATH" ] || continue

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
