#!/usr/bin/env bash
# scripts/get-session-key.sh — Resolve a stable key identifying the CALLING agent
# session (not the project). Two agent sessions in the same repo get different
# keys; repeated calls from the same agent session get the same key.
#
# Priority:
# 1. $BRIDGE_SESSION_KEY env (explicit override — useful for tests and power users)
# 2. First non-shell ancestor process PID. Inside an agent CLI (e.g. Claude Code),
#    tool commands run as descendants of the CLI process, so this PID is stable
#    for the lifetime of that session and distinct across sessions.
# 3. Own PID as a last resort (no stable identity available).
#
# Outputs: session key to stdout (e.g. "pid12345" or the override verbatim)
set -euo pipefail

if [ -n "${BRIDGE_SESSION_KEY:-}" ]; then
  echo -n "$BRIDGE_SESSION_KEY"
  exit 0
fi

PID=$$
while true; do
  PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
  if [ -z "$PID" ] || [ "$PID" = "0" ] || [ "$PID" = "1" ]; then
    break
  fi
  COMM=$(ps -o comm= -p "$PID" 2>/dev/null || echo "")
  case "$(basename "$COMM")" in
    bash|zsh|sh|dash|fish|env) ;;  # skip shells — the agent CLI is above them
    *) echo -n "pid$PID"; exit 0 ;;
  esac
done

# Fallback: no identifiable ancestor
echo -n "pid$$"
