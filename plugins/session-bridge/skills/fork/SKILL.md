---
name: fork
description: Fork the current conversation into a new terminal tab with automatic bridge connection. The forked session gets the full conversation history and can communicate with the parent via /bridge.
argument-hint: "[session-name]"
allowed-tools:
  - Bash
---

# Fork Session

Fork this conversation into a new terminal tab. The forked session inherits the full conversation history and auto-connects to this session via the bridge.

## Steps

1. **Find the current session ID** from the most recently modified transcript file:
   ```bash
   CWD_ENCODED=$(echo "$PWD" | sed 's|/|-|g')
   PROJECT_DIR="$HOME/.claude/projects/$CWD_ENCODED"
   SESSION_ID=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1 | xargs basename | sed 's/\.jsonl$//')
   ```

2. **Register this session with the bridge** so the forked session can connect back:
   ```bash
   MY_BRIDGE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh" 2>/dev/null)
   ```

3. **Write a breadcrumb** for the child session's auto-connect hook:
   ```bash
   mkdir -p ~/.claude/session-bridge
   echo "$MY_BRIDGE" > ~/.claude/session-bridge/pending-connect
   ```

4. **Parse the optional name** from the user's argument. If provided, use `-n <name>`.

5. **Open a new terminal tab and launch the forked session.**

   For **Ghostty**:
   ```bash
   FORK_CMD="claude -r $SESSION_ID --fork-session"
   [ -n "$NAME" ] && FORK_CMD="$FORK_CMD -n \"$NAME\""

   osascript -e "
   tell application \"Ghostty\" to activate
   tell application \"System Events\"
     tell process \"ghostty\"
       keystroke \"t\" using command down
       delay 0.5
       keystroke \"$FORK_CMD\"
       keystroke return
     end tell
   end tell
   "
   ```

   For **iTerm2**:
   ```bash
   osascript -e "
   tell application \"iTerm2\"
     tell current window
       create tab with default profile
       tell current session
         write text \"$FORK_CMD\"
       end tell
     end tell
   end tell
   "
   ```

   For **Terminal.app**:
   ```bash
   osascript -e "
   tell application \"Terminal\"
     activate
     do script \"$FORK_CMD\"
   end tell
   "
   ```

6. **Confirm to the user:**
   ```
   Forked into a new tab. The child session will auto-connect to bridge ID: <MY_BRIDGE>.
   Use /bridge ask to query it once it's running.
   ```

## How it works

- `claude -r <session-id> --fork-session` creates a new Claude Code session with the full conversation history from the parent
- The bridge breadcrumb at `~/.claude/session-bridge/pending-connect` is read by the SessionStart hook in the child session, which auto-connects to the parent's bridge ID
- Both sessions can then use `/bridge ask` to query each other with full context
- The parent continues working uninterrupted

## Notes

- Works on macOS only (uses AppleScript for terminal tab creation)
- Detects the terminal from `$TERM_PROGRAM` or defaults to Ghostty
- If the session ID can't be found (e.g., running from a non-project directory), prompt the user to specify one
