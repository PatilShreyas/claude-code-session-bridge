---
name: bridge
description: Peer-to-peer communication between Claude Code sessions - start, connect, listen, ask, peers, status, stop
argument-hint: "<action> [args]"
allowed-tools:
  - Bash
  - Read
  - Write
---

# Bridge Command

Manage cross-session communication with other Claude Code instances on this machine.

**IMPORTANT:** To get your session ID, always use:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh"
```
This works even if you've cd'd into a subdirectory. NEVER use `$(cat .claude/bridge-session)` directly — it's a relative path and breaks when the working directory changes.

## Actions

Parse the user's argument to determine the action:

### `start`

Register this session as a bridge peer.

1. Run the registration script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh"
   ```
2. Capture the session ID from stdout.
3. Display to the user:
   ```
   Bridge active!
   Session ID: <session-id>
   Share this ID with other Claude sessions to connect: /bridge connect <session-id>
   Use /bridge listen to start receiving and answering peer queries.
   ```

### `connect <session-id>`

Connect to a peer session. Always ensures this session has its own bridge first.

1. Extract the target session ID from the argument.
2. **Always register first** to guarantee this session has its own unique bridge identity.
   `register.sh` is idempotent — if `BRIDGE_SESSION_ID` env var is already set (from a
   prior `/bridge start` in this process), it reuses that session. Otherwise it creates a new one:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh"
   ```
   Capture the returned session ID — this is YOUR session's ID.
3. Then connect to the peer using YOUR session ID from step 2:
   ```bash
   BRIDGE_SESSION_ID=<your-session-id-from-step-2> bash "${CLAUDE_PLUGIN_ROOT}/scripts/connect-peer.sh" "<target-session-id>"
   ```
4. If successful, display the peer's project name and path, and show this session's ID.
5. If it fails (peer not found), suggest `/bridge peers` to see available sessions.
6. Tell the user: "Connected! Use `/bridge listen` to start answering peer queries, or `/bridge ask <question>` to ask them something."

### `listen`

Enter listening mode — continuously wait for peer messages and respond to them. This dedicates the session to answering peer queries using YOUR FULL CONTEXT.

**This is a loop. You MUST keep listening until the user interrupts (Ctrl+C).**

**Auto-start:** Always register first to ensure this session has its own bridge:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh"
```
Capture the returned session ID. If this session was already registered (via `BRIDGE_SESSION_ID`
env var), `register.sh` reuses it. Otherwise it creates a new one.
Display: "Bridge active! Session ID: <id>". Then proceed to the loop.

Store the session ID in a variable (e.g., `MY_SESSION`) for use throughout the loop.

The loop:

1. Tell the user: "Listening for peer messages... (Ctrl+C to stop)"
2. Run the listen script with YOUR session ID (this BLOCKS until a message arrives in YOUR inbox only):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-listen.sh" "$MY_SESSION"
   ```
3. When a message arrives, parse the output:
   - Lines before `---` are metadata (MESSAGE_ID, FROM_ID, TO_ID, FROM_PROJECT, TYPE, IN_REPLY_TO)
   - Lines after `---` are the message content

4. Handle by message type. **Use `TO_ID` from the message metadata as your session ID** when sending responses. This is always correct regardless of working directory.

   **If TYPE=query**: Read the question. Formulate a helpful, concise answer using your full knowledge of this project. Send it:
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> response "Your answer here" <MESSAGE_ID>
   ```

   **If TYPE=ping**: Send a ping back:
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> ping "connected"
   ```

   **If TYPE=session-ended**: Note it and tell the user: "Peer [FROM_PROJECT] disconnected."

   **If TYPE=response**: Display the response content to the user.

5. **IMMEDIATELY go back to step 2.** Run `bridge-listen.sh` again. Do NOT stop. Do NOT ask the user what to do next. Keep listening.

**CRITICAL:** After responding to each message, you MUST immediately run `bridge-listen.sh` again to continue listening. This is a continuous loop. The only way to exit is the user pressing Ctrl+C.

### `ask <question>`

Send a query to a connected peer and wait for the response.

1. Get session ID — register first to ensure this session has its own bridge:
   ```bash
   MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh")
   ```
   This is idempotent — reuses the existing session if `BRIDGE_SESSION_ID` env var is set.
2. Find connected peers:
   ```bash
   find ~/.claude/session-bridge/sessions/$MY_SESSION/inbox -name "*.json" -exec jq -r 'select(.type == "ping") | .from' {} \; 2>/dev/null | sort -u
   ```
3. If multiple peers, ask which one to query.
4. Send the query and capture the message ID:
   ```bash
   MSG_ID=$(BRIDGE_SESSION_ID=$MY_SESSION bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" "<peer-id>" query "<question>")
   ```
5. Tell the user: "Asking [peer-project-name]... waiting for response."
6. **Immediately wait for the response** (blocks up to 90 seconds):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-receive.sh" "$MY_SESSION" "$MSG_ID" 90
   ```
7. When the response arrives, display it and continue working with the information.
8. If it times out, tell the user the peer may be inactive or not in listening mode.

### `peers`

List all active bridge sessions on this machine.

1. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-peers.sh"
   ```
2. Display the formatted table.
3. To highlight which one is "you", run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh"
   ```

### `status`

Show current bridge state.

1. Get session ID:
   ```bash
   MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh")
   ```
   If it exits with code 1, say "Bridge is not active. Run `/bridge start` to begin."
2. Display the session ID.
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

### `stop`

Unregister and clean up.

1. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh"
   ```
2. Tell the user: "Bridge stopped. Connected peers have been notified."

## No argument / unknown action

If no argument is given, show a brief help:
```
Bridge commands:
  /bridge start              - Register this session
  /bridge connect <id>       - Connect to a peer session
  /bridge listen             - Listen and answer peer queries (blocks)
  /bridge ask <question>     - Send a question to a peer
  /bridge peers              - List active sessions
  /bridge status             - Show bridge state
  /bridge stop               - Disconnect and clean up
```
