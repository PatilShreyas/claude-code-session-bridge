#!/usr/bin/env bash
# scripts/list-peers.sh — List all active bridge sessions.
# Env: BRIDGE_DIR (default: ~/.claude/bridge)
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
SESSIONS_DIR="$BRIDGE_DIR/sessions"

if [ ! -d "$SESSIONS_DIR" ]; then
  echo "No active bridge sessions."
  exit 0
fi

NOW_EPOCH=$(date -u +%s)
STALE_SECONDS=300  # 5 minutes
FOUND=0

printf "%-10s %-20s %-8s %s\n" "SESSION" "PROJECT" "STATUS" "PATH"
printf "%-10s %-20s %-8s %s\n" "-------" "-------" "------" "----"

for MANIFEST in "$SESSIONS_DIR"/*/manifest.json; do
  [ -f "$MANIFEST" ] || continue

  SID=$(jq -r '.sessionId' "$MANIFEST")
  PNAME=$(jq -r '.projectName' "$MANIFEST")
  PPATH=$(jq -r '.projectPath' "$MANIFEST")
  HB=$(jq -r '.lastHeartbeat' "$MANIFEST")

  # Calculate staleness (macOS date parsing — use -u to match UTC timestamps)
  HB_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$HB" +%s 2>/dev/null || date -u -d "$HB" +%s 2>/dev/null || echo "0")
  AGE=$((NOW_EPOCH - HB_EPOCH))

  if [ "$AGE" -gt "$STALE_SECONDS" ]; then
    STATUS="stale"
  else
    STATUS="active"
  fi

  printf "%-10s %-20s %-8s %s\n" "$SID" "$PNAME" "$STATUS" "$PPATH"
  FOUND=$((FOUND + 1))
done

if [ "$FOUND" -eq 0 ]; then
  echo "No active bridge sessions."
fi
