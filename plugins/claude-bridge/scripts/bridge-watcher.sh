#!/usr/bin/env bash
# scripts/bridge-watcher.sh — Background watcher that auto-responds to peer queries.
# Usage: bridge-watcher.sh <session-id>
# Polls inbox every 5 seconds, responds to queries via claude -p, handles pings directly.
set -uo pipefail
# Note: -e is intentionally omitted. The watcher is a long-running loop
# and must be resilient to individual command failures (e.g. grep returning
# no matches, claude -p failing). Errors are handled explicitly.

SESSION_ID="${1:?Usage: bridge-watcher.sh <session-id>}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
INBOX="$SESSION_DIR/inbox"
MANIFEST="$SESSION_DIR/manifest.json"
PID_FILE="$SESSION_DIR/watcher.pid"
LOG_FILE="$SESSION_DIR/watcher.log"

# Validate session exists
if [ ! -f "$MANIFEST" ]; then
  echo "Error: Session $SESSION_ID not found" >&2
  exit 1
fi

PROJECT_PATH=$(jq -r '.projectPath' "$MANIFEST")
PROJECT_NAME=$(jq -r '.projectName' "$MANIFEST")

# Write PID file
echo $$ > "$PID_FILE"

# Cleanup on exit
cleanup() {
  rm -f "$PID_FILE"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Watcher stopped" >> "$LOG_FILE"
}
trap cleanup EXIT SIGTERM SIGINT

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Watcher started for session $SESSION_ID ($PROJECT_NAME)" >> "$LOG_FILE"
echo "Background watcher active for '$PROJECT_NAME' (session: $SESSION_ID)"
echo "Log: $LOG_FILE"

# Unset Claude env vars to prevent nested session detection
unset CLAUDECODE CLAUDE_CODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# Record parent PID so we can detect if Claude dies
PARENT_PID=$PPID

while true; do
  # Check if parent process (Claude) is still alive — exit if orphaned
  if ! kill -0 "$PARENT_PID" 2>/dev/null; then
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Parent process $PARENT_PID gone — exiting" >> "$LOG_FILE"
    exit 0
  fi

  # Update OWN heartbeat
  NOW_HB=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [ -f "$MANIFEST" ]; then
    TMP_HB=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
    jq --arg hb "$NOW_HB" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP_HB"
    mv "$TMP_HB" "$MANIFEST"
  fi

  # Check inbox for pending messages
  if [ ! -d "$INBOX" ]; then
    sleep 5
    continue
  fi

  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue

    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    MSG_ID=$(jq -r '.id' "$MSG_FILE")
    FROM_ID=$(jq -r '.from' "$MSG_FILE")
    MSG_TYPE=$(jq -r '.type' "$MSG_FILE")
    CONTENT=$(jq -r '.content' "$MSG_FILE")
    FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE")
    IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$MSG_FILE")

    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Received [$MSG_TYPE] from $FROM_PROJECT ($FROM_ID): $CONTENT" >> "$LOG_FILE"

    # Mark as being processed
    TMP=$(mktemp "$INBOX/${MSG_ID}.XXXXXX")
    jq '.status = "processing"' "$MSG_FILE" > "$TMP"
    mv "$TMP" "$MSG_FILE"

    case "$MSG_TYPE" in
      ping)
        # Just acknowledge — do NOT send a ping back (would cause infinite loop between two watchers)
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Received ping from $FROM_PROJECT ($FROM_ID) — acknowledged" >> "$LOG_FILE"
        ;;

      query)
        # Gather rich project context for the auto-responder
        PROJECT_CONTEXT=""
        if [ -d "$PROJECT_PATH" ]; then
          # Git diff (recent changes — this is what the session has been working on)
          GIT_DIFF=$(cd "$PROJECT_PATH" && git diff --stat 2>/dev/null || echo "(not a git repo)")
          GIT_DIFF_DETAIL=$(cd "$PROJECT_PATH" && git diff 2>/dev/null | head -200 || echo "")
          STAGED=$(cd "$PROJECT_PATH" && git diff --cached --stat 2>/dev/null || echo "")
          RECENT_COMMITS=$(cd "$PROJECT_PATH" && git log --oneline -10 2>/dev/null || echo "")
          CLAUDE_MD=""
          [ -f "$PROJECT_PATH/CLAUDE.md" ] && CLAUDE_MD=$(head -100 "$PROJECT_PATH/CLAUDE.md")

          PROJECT_CONTEXT="## Project Context

### Recent commits:
$RECENT_COMMITS

### Uncommitted changes (what's being worked on):
$GIT_DIFF
$STAGED

### Diff detail (first 200 lines):
$GIT_DIFF_DETAIL"

          [ -n "$CLAUDE_MD" ] && PROJECT_CONTEXT="${PROJECT_CONTEXT}

### CLAUDE.md:
$CLAUDE_MD"
        fi

        # Active session conversation from Claude's session JSONL
        # Use history.jsonl to find the exact active session ID for this project
        ENCODED_PATH=$(echo "$PROJECT_PATH" | sed 's|/|-|g')
        SESSION_DIR_CLAUDE="$HOME/.claude/projects/$ENCODED_PATH"
        if [ -d "$SESSION_DIR_CLAUDE" ]; then
          # Look up the most recent session ID for this project from history.jsonl
          ACTIVE_SESSION_ID=$(grep "\"project\":\"$PROJECT_PATH\"" "$HOME/.claude/history.jsonl" 2>/dev/null | tail -1 | jq -r '.sessionId // ""' 2>/dev/null)
          LATEST_SESSION=""
          if [ -n "$ACTIVE_SESSION_ID" ] && [ -f "$SESSION_DIR_CLAUDE/$ACTIVE_SESSION_ID.jsonl" ]; then
            LATEST_SESSION="$SESSION_DIR_CLAUDE/$ACTIVE_SESSION_ID.jsonl"
          fi
          if [ -n "$LATEST_SESSION" ] && [ -f "$LATEST_SESSION" ]; then
            # Extract user messages sampled across the FULL session timeline
            # Get total count, then sample: first 5, every Nth from middle, last 10
            TOTAL_USER=$(grep -c '"type":"user"' "$LATEST_SESSION" 2>/dev/null || echo "0")

            if [ "$TOTAL_USER" -gt 0 ]; then
              # Extract ALL user text messages (filter out tool results and system tags)
              ALL_USER_TEXTS=$(grep '"type":"user"' "$LATEST_SESSION" 2>/dev/null | jq -r '
                (.message.content // .content // "") |
                if type == "array" then
                  map(select(.type == "text") | .text) | join("\n")
                elif type == "string" then .
                else ""
                end
              ' 2>/dev/null | grep -v '^$' | grep -v '^<' || true)

              TOTAL_LINES=$(echo "$ALL_USER_TEXTS" | wc -l | tr -d ' ')

              if [ "$TOTAL_LINES" -le 30 ]; then
                # Small session — use everything
                SAMPLED_USER="$ALL_USER_TEXTS"
              else
                # Large session — sample: first 5, evenly spaced middle 10, last 10
                FIRST=$(echo "$ALL_USER_TEXTS" | head -5)
                LAST=$(echo "$ALL_USER_TEXTS" | tail -10)
                # Sample 10 evenly spaced lines from the middle
                MIDDLE_START=6
                MIDDLE_END=$((TOTAL_LINES - 10))
                MIDDLE_RANGE=$((MIDDLE_END - MIDDLE_START))
                if [ "$MIDDLE_RANGE" -gt 10 ]; then
                  STEP=$((MIDDLE_RANGE / 10))
                  MIDDLE=$(echo "$ALL_USER_TEXTS" | sed -n "${MIDDLE_START},${MIDDLE_END}p" | awk "NR % $STEP == 1" | head -10)
                else
                  MIDDLE=$(echo "$ALL_USER_TEXTS" | sed -n "${MIDDLE_START},${MIDDLE_END}p")
                fi
                SAMPLED_USER=$(printf "%s\n--- [middle of session] ---\n%s\n--- [recent] ---\n%s" "$FIRST" "$MIDDLE" "$LAST")
              fi
            fi

            # Extract assistant messages — same sampling strategy
            TOTAL_ASST=$(grep -c '"type":"assistant"' "$LATEST_SESSION" 2>/dev/null || echo "0")

            if [ "$TOTAL_ASST" -gt 0 ]; then
              ALL_ASST_TEXTS=$(grep '"type":"assistant"' "$LATEST_SESSION" 2>/dev/null | jq -r '
                .message.content // .content // [] |
                if type == "array" then
                  map(select(.type == "text") | .text[:200]) | join("\n")
                elif type == "string" then .[:200]
                else ""
                end
              ' 2>/dev/null | grep -v '^$' || true)

              TOTAL_ASST_LINES=$(echo "$ALL_ASST_TEXTS" | wc -l | tr -d ' ')

              if [ "$TOTAL_ASST_LINES" -le 30 ]; then
                SAMPLED_ASST="$ALL_ASST_TEXTS"
              else
                FIRST_A=$(echo "$ALL_ASST_TEXTS" | head -5)
                LAST_A=$(echo "$ALL_ASST_TEXTS" | tail -10)
                MIDDLE_START_A=6
                MIDDLE_END_A=$((TOTAL_ASST_LINES - 10))
                MIDDLE_RANGE_A=$((MIDDLE_END_A - MIDDLE_START_A))
                if [ "$MIDDLE_RANGE_A" -gt 10 ]; then
                  STEP_A=$((MIDDLE_RANGE_A / 10))
                  MIDDLE_A=$(echo "$ALL_ASST_TEXTS" | sed -n "${MIDDLE_START_A},${MIDDLE_END_A}p" | awk "NR % $STEP_A == 1" | head -10)
                else
                  MIDDLE_A=$(echo "$ALL_ASST_TEXTS" | sed -n "${MIDDLE_START_A},${MIDDLE_END_A}p")
                fi
                SAMPLED_ASST=$(printf "%s\n--- [middle of session] ---\n%s\n--- [recent] ---\n%s" "$FIRST_A" "$MIDDLE_A" "$LAST_A")
              fi
            fi

            if [ -n "${SAMPLED_USER:-}" ] || [ -n "${SAMPLED_ASST:-}" ]; then
              PROJECT_CONTEXT="${PROJECT_CONTEXT}

### Session conversation (sampled across full timeline — $TOTAL_USER user msgs, $TOTAL_ASST assistant msgs):

User has been asking (sampled):
${SAMPLED_USER:-  (none)}

Agent has been responding (sampled):
${SAMPLED_ASST:-  (none)}"
            fi
          fi
        fi

        # Use claude -p to generate a response with full project + session context
        PROMPT="You are a Claude Code agent working on the project '$PROJECT_NAME' at $PROJECT_PATH. A peer Claude agent from the '$FROM_PROJECT' project is asking you a question. Answer concisely and helpfully based on the project context below, the session history, and the project's code.

$PROJECT_CONTEXT

## Question from $FROM_PROJECT:
$CONTENT"

        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Generating response via claude -p (with project context)..." >> "$LOG_FILE"

        RESPONSE=$(cd "$PROJECT_PATH" && claude -p --model haiku "$PROMPT" 2>/dev/null) || RESPONSE="Sorry, I couldn't generate a response automatically. The user may need to answer manually."

        # Send response back
        BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" \
          bash "$SCRIPT_DIR/send-message.sh" "$FROM_ID" response "$RESPONSE" "$MSG_ID" > /dev/null 2>&1 || true

        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Sent response to $FROM_ID (${#RESPONSE} chars)" >> "$LOG_FILE"
        ;;

      response)
        # Responses are for the interactive session to pick up — just log
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Response received (for interactive session)" >> "$LOG_FILE"
        ;;

      session-ended)
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Peer $FROM_PROJECT ($FROM_ID) disconnected" >> "$LOG_FILE"
        ;;

      context-dump)
        # Auto-generate a context dump
        DUMP="Project: $PROJECT_NAME\nPath: $PROJECT_PATH\n"
        if [ -d "$PROJECT_PATH" ]; then
          FILE_LIST=$(cd "$PROJECT_PATH" && find . -maxdepth 3 -type f ! -path './.git/*' ! -path './node_modules/*' ! -path './.claude/*' 2>/dev/null | head -50)
          DUMP="${DUMP}\nFiles:\n${FILE_LIST}"
        fi
        BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" \
          bash "$SCRIPT_DIR/send-message.sh" "$FROM_ID" response "$DUMP" "$MSG_ID" > /dev/null 2>&1 || true
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Sent context dump to $FROM_ID" >> "$LOG_FILE"
        ;;
    esac

    # Mark as answered
    TMP=$(mktemp "$INBOX/${MSG_ID}.XXXXXX")
    jq '.status = "answered"' "$MSG_FILE" > "$TMP"
    mv "$TMP" "$MSG_FILE"

  done

  sleep 5
done
