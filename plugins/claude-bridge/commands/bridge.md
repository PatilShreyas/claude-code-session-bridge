---
name: bridge
description: Peer-to-peer communication between Claude Code sessions - start, connect, peers, ask, status, stop
argument-hint: "<action> [args]"
allowed-tools:
  - Bash
  - Read
  - Write
---

# Bridge Command

Manage cross-session communication with other Claude Code instances on this machine.

## Actions

Parse the user's argument to determine the action:

### `start`

Register this session as a bridge peer. If a bridge is already active for this project, reuses it.

1. Run the registration script and capture BOTH stdout (session ID) and stderr (status):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh"
   ```
   Stderr will say one of:
   - `EXISTING:<id>` — another session already has an active watcher for this project
   - `RECLAIMED:<id>` — session existed but watcher was dead, reclaimed it
   - `NEW:<id>` — fresh session created

2. If **EXISTING**: the watcher is already running from another Claude session. Tell the user:
   ```
   Bridge already active for this project!
   Session ID: <session-id>
   A watcher is already running from another Claude session.
   ```
   Do NOT start another watcher.

3. If **RECLAIMED** or **NEW**: start the background watcher using Bash with `run_in_background: true`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-watcher.sh" "$(cat .claude/bridge-session)"
   ```
   **IMPORTANT:** You MUST use `run_in_background: true` on this Bash tool call.
   Tell the user:
   ```
   Bridge active!
   Session ID: <session-id>
   Background watcher running — peer queries will be auto-answered.
   Share this ID with other Claude sessions to connect: /bridge connect <session-id>
   ```

### `connect <session-id>`

Connect to a peer session. Auto-starts this session's bridge if not already active.

1. Extract the session ID from the argument.
2. Check if `.claude/bridge-session` exists. If NOT, auto-start the bridge first:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh"
   ```
   Capture the session ID from stdout and note it for the user.
3. Then connect to the peer:
   ```bash
   BRIDGE_SESSION_ID=$(cat .claude/bridge-session) bash "${CLAUDE_PLUGIN_ROOT}/scripts/connect-peer.sh" "<session-id>"
   ```
4. If successful, display the peer's project name and path. If you auto-started in step 2, also show this session's ID.
5. If it fails (peer not found), suggest `/bridge peers` to see available sessions.
6. Tell the user: "Connected! The peer will see the connection on their next prompt. Communication is now automatic."

### `peers`

List all active bridge sessions on this machine.

1. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-peers.sh"
   ```
2. Display the formatted table.
3. If this session has a bridge active (`.claude/bridge-session` exists), highlight which one is "you".

### `ask <question>`

Send a query to a connected peer and wait for the response.

1. Read session ID from `.claude/bridge-session`. If not found, tell user to run `/bridge start` first.
2. Find connected peers:
   ```bash
   find ~/.claude/bridge/sessions/$(cat .claude/bridge-session)/inbox -name "*.json" -exec jq -r 'select(.type == "ping") | .from' {} \; 2>/dev/null | sort -u
   ```
3. If multiple peers, ask which one to query.
4. Send the query and capture the message ID:
   ```bash
   MSG_ID=$(BRIDGE_SESSION_ID=$(cat .claude/bridge-session) bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" "<peer-id>" query "<question>")
   ```
5. Tell the user: "Asking [peer-project-name]... waiting for response."
6. **Immediately wait for the response** (blocks up to 60 seconds):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-wait.sh" "$(cat .claude/bridge-session)" "$MSG_ID" 60
   ```
7. When the response arrives, display it and continue working with the information.
8. If it times out, tell the user the peer may be inactive.

### `status`

Show current bridge state.

1. Check if bridge is active by reading `.claude/bridge-session`. If not found, say "Bridge is not active. Run `/bridge start` to begin."
2. Read and display the session ID.
3. List connected peers (from ping messages in inbox).
4. Count pending (unread) messages in inbox.
5. Count messages in outbox (sent).
6. Display a summary:
   ```
   Bridge Status
   Session ID: abc123
   Project: my-app

   Connected Peers:
   - my-library (def456) - active

   Inbox: 2 pending messages
   Outbox: 5 messages sent
   ```

### `watch`

Start the background watcher that auto-responds to peer queries without user input. Uses Claude Code's built-in background task feature (Bash with `run_in_background: true`).

1. Read session ID from `.claude/bridge-session`. If not found, run `/bridge start` first.
2. Check if a watcher is already running:
   ```bash
   SESSION_ID=$(cat .claude/bridge-session) && [ -f ~/.claude/bridge/sessions/$SESSION_ID/watcher.pid ] && kill -0 $(cat ~/.claude/bridge/sessions/$SESSION_ID/watcher.pid) 2>/dev/null && echo "already running"
   ```
3. If not running, start the watcher **as a background Bash command** using `run_in_background: true`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-watcher.sh" "$(cat .claude/bridge-session)"
   ```
   **IMPORTANT:** You MUST use `run_in_background: true` on the Bash tool call. This runs it as a Claude Code background task that stays alive for the session.
4. Tell the user: "Background watcher active. Peer queries will be auto-answered. Use `/bridge unwatch` to stop."

### `unwatch`

Stop the background watcher.

1. Read session ID from `.claude/bridge-session`.
2. Kill the watcher process:
   ```bash
   SESSION_ID=$(cat .claude/bridge-session) && [ -f ~/.claude/bridge/sessions/$SESSION_ID/watcher.pid ] && kill $(cat ~/.claude/bridge/sessions/$SESSION_ID/watcher.pid) 2>/dev/null
   ```
3. Tell the user: "Background watcher stopped."

### `stop`

Unregister and clean up.

1. First stop the watcher if running:
   ```bash
   SESSION_ID=$(cat .claude/bridge-session 2>/dev/null) && [ -n "$SESSION_ID" ] && [ -f ~/.claude/bridge/sessions/$SESSION_ID/watcher.pid ] && kill $(cat ~/.claude/bridge/sessions/$SESSION_ID/watcher.pid) 2>/dev/null; true
   ```
2. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh"
   ```
3. Tell the user: "Bridge stopped. Connected peers have been notified."

## No argument / unknown action

If no argument is given, show a brief help:
```
Bridge commands:
  /bridge start              - Register this session
  /bridge connect <id>       - Connect to a peer session
  /bridge peers              - List active sessions
  /bridge ask <question>     - Send a question to a peer
  /bridge watch              - Auto-respond to peers in background
  /bridge unwatch            - Stop auto-responding
  /bridge status             - Show bridge state
  /bridge stop               - Disconnect and clean up
```
