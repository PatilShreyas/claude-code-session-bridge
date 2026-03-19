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

---

## Project Commands

### `project create <name>`

Create a new multi-session project.

1. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-create.sh" "<name>"
   ```
2. If successful, display:
   ```
   Project "<name>" created!
   Other sessions can join with: /bridge project join <name>
   ```
3. If it fails (project already exists), tell the user.

### `project join <name> [--role <role>] [--specialty "<desc>"] [--name "<name>"]`

Join a project and register this session.

1. Build the command with any provided flags:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-join.sh" "<name>" --role <role> --specialty "<desc>" --name "<name>"
   ```
   Defaults: `--role specialist`, `--specialty ""`, `--name` is the basename of the current working directory.
2. Capture the session ID from stdout.
3. Display:
   ```
   Joined project "<name>"!
   Session ID: <session-id>
   Role: <role>
   Use /bridge standby to start listening for messages.
   Use /bridge peers to see other sessions in this project.
   ```
4. If it fails (project doesn't exist), suggest `/bridge project create <name>` first.

### `project list`

List all projects on this machine.

1. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-list.sh"
   ```
2. Display the formatted table of projects, session counts, and creation dates.
3. If no projects exist, suggest `/bridge project create <name>`.

---

## Session Commands

### `peers`

List sessions in the current project (or all sessions if not in a project).

1. Check if this session belongs to a project:
   ```bash
   MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh" 2>/dev/null) || true
   ```
2. Run list-peers with project filter if applicable:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-peers.sh"
   ```
   Or with project filter:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-peers.sh" --project "<project-name>"
   ```
3. Display the formatted table. Highlight which session is "you" by matching against `MY_SESSION`.

### `status`

Show current bridge state including conversations, pending decisions, and message counts.

1. Get session ID:
   ```bash
   MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh")
   ```
   If it fails, say "Bridge is not active. Run `/bridge project join <name>` or `/bridge start` to begin."

2. Find the project and session directory. Check project-scoped paths first:
   ```bash
   # Find project membership
   PROJECT_INFO=$(find ~/.claude/session-bridge/projects/*/sessions/"$MY_SESSION"/manifest.json -exec jq -r '.projectId' {} \; 2>/dev/null | head -1)
   ```

3. Display session info:
   ```
   Bridge Status
   Session ID: <id>
   Project: <project-name> (or "none — ad-hoc mode")
   Role: <role>
   Specialty: <specialty>
   ```

4. Count pending (unread) messages in inbox.

5. Count messages in outbox (sent).

6. If in a project, list active conversations:
   ```bash
   # List conversations involving this session
   find ~/.claude/session-bridge/projects/<project>/conversations/ -name "conv-*.json" -exec jq -r 'select(.status != "resolved") | "\(.id) | \(.topic) | \(.status)"' {} \; 2>/dev/null
   ```

7. Display summary:
   ```
   Connected Peers:
   - auth-server (abc123) - specialist - active
   - framework (def456) - specialist - active

   Active Conversations: 3
   - conv-a1b2c3: "Fix JWT validation" (waiting)
   - conv-d4e5f6: "Database migration" (open)

   Inbox: 2 pending messages
   Outbox: 5 messages sent

   Pending Decisions: 1 (run /bridge decisions to see)
   ```

### `standby`

Enter standby mode — continuously wait for peer messages and handle them. This dedicates the session to handling bridge messages using YOUR FULL CONTEXT.

**This is a loop. You MUST keep listening until the user interrupts (Ctrl+C).**

**Auto-register:** First, check if this session has a bridge:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh"
```
If it exits with code 1, tell the user: "No active bridge session. Run `/bridge project join <name>` first, or `/bridge start` for ad-hoc mode." and stop.

Store the session ID in a variable (e.g., `MY_SESSION`) for use throughout the loop.

The loop:

1. Tell the user: "Standing by for messages... (Ctrl+C to stop)"
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

   **If TYPE=task-assign**: Read the task description. Acknowledge receipt, then begin working on the task. Send a progress update:
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> task-update "Acknowledged. Starting work on: <brief summary>" <MESSAGE_ID>
   ```
   Then do the work. When finished, send task-complete:
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> task-complete "Done. <summary of what was done>" <MESSAGE_ID>
   ```

   **If TYPE=escalate**: Another specialist is routing work to you. Handle like task-assign but note the escalation context. Work on the issue and send task-complete when done.

   **If TYPE=task-redirect**: The old task is cancelled. Read the new task details from the content and begin working on the new task. Create a new conversation for the new task via the send flow.

   **If TYPE=task-update**: Display the progress update to the user. Note the status and continue.

   **If TYPE=task-complete**: Display the result. The conversation is resolved. If this was a task you delegated, incorporate the result into your work.

   **If TYPE=task-cancel**: Stop work on the referenced task. Acknowledge to the user.

   **If TYPE=response**: Display the response content to the user.

   **If TYPE=human-input-needed**: Display the question to the user prominently. Show the proposed default if provided. Ask the user for their decision. When they respond, send it back:
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> human-response "User's decision here" <MESSAGE_ID>
   ```
   **Then immediately go back to the listen loop** — do NOT stop after handling a human-input-needed message.

   **If TYPE=human-response**: This is the user's answer to a decision you escalated. Apply the decision and continue your work.

   **If TYPE=routing-query**: Someone is asking "who handles X?". If you're the orchestrator, analyze the query and respond with the appropriate session ID. If you're not the orchestrator, respond that you don't handle routing.

   **If TYPE=ping**: Send a ping back:
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> ping "connected"
   ```

   **If TYPE=session-ended**: Note it and tell the user: "Peer [FROM_PROJECT] disconnected."

5. **IMMEDIATELY go back to step 2.** Run `bridge-listen.sh` again. Do NOT stop. Do NOT ask the user what to do next. Keep listening.

**CRITICAL:** After handling each message, you MUST immediately run `bridge-listen.sh` again to continue listening. This is a continuous loop. The only way to exit is the user pressing Ctrl+C. NEVER break the loop.

### `decisions`

Show pending human-input-needed messages that require the user's decision.

1. Get session ID and project:
   ```bash
   MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh")
   ```
   If it fails, say "Bridge is not active."

2. Find the project this session belongs to:
   ```bash
   PROJECT_ID=$(find ~/.claude/session-bridge/projects/*/sessions/"$MY_SESSION"/manifest.json -exec jq -r '.projectId' {} \; 2>/dev/null | head -1)
   ```

3. Scan all inboxes in the project for human-input-needed messages:
   ```bash
   find ~/.claude/session-bridge/projects/"$PROJECT_ID"/sessions/*/inbox/ -name "*.json" \
     -exec jq -r 'select(.type == "human-input-needed" and .status == "pending") | "[\(.id)] from \(.metadata.fromProject // .from): \(.content)"' {} \; 2>/dev/null
   ```

4. Display the decision queue:
   ```
   === DECISIONS AWAITING YOUR INPUT ===

   1. [msg-abc123def456] from auth-server:
      "Should we use RS256 or HS256 for JWT signing? RS256 is more secure but
       requires key management. Proposed default: RS256"

   2. [msg-xyz789abc012] from framework:
      "The database migration will drop the legacy_users table. 47 rows affected.
       Proceed? Proposed default: Yes, data has been migrated"

   Reply to a decision with:
   BRIDGE_SESSION_ID=<your-session> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <from-id> human-response "Your decision" <message-id>
   ```

5. If no decisions are pending, say "No pending decisions."

### `stop`

Unregister and clean up.

1. Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh"
   ```
2. Tell the user: "Bridge stopped. Connected peers have been notified."

---

## Legacy Commands (Shortcuts)

These still work for quick ad-hoc two-session bridges without project scoping.

### `start`

Register this session as a bridge peer (ad-hoc mode, no project).

1. Run the registration script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh"
   ```
2. Capture the session ID from stdout.
3. Display to the user:
   ```
   Bridge active! (ad-hoc mode)
   Session ID: <session-id>
   Share this ID with other Claude sessions to connect: /bridge connect <session-id>
   Use /bridge standby to start receiving and handling peer messages.

   Tip: For multi-session projects, use /bridge project create <name> instead.
   ```

### `connect <session-id>`

Connect to a peer session. Auto-starts this session's bridge if not already active.

1. Extract the session ID from the argument.
2. Check if this session has a bridge:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh"
   ```
   If it exits with code 1 (not found), auto-start the bridge first:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh"
   ```
   Capture the session ID from stdout and note it for the user.
3. Then connect to the peer:
   ```bash
   BRIDGE_SESSION_ID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh") bash "${CLAUDE_PLUGIN_ROOT}/scripts/connect-peer.sh" "<session-id>"
   ```
4. If successful, display the peer's project name and path. If you auto-started in step 2, also show this session's ID.
5. If it fails (peer not found), suggest `/bridge peers` to see available sessions.
6. Tell the user: "Connected! Use `/bridge standby` to start handling peer messages, or `/bridge ask <question>` to ask them something."

### `ask <question>`

Send a query to a connected peer and wait for the response.

1. Get session ID:
   ```bash
   MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh")
   ```
   If it fails, tell the user to run `/bridge start` or `/bridge project join` first.
2. Find connected peers:
   ```bash
   find ~/.claude/session-bridge/sessions/$MY_SESSION/inbox -name "*.json" -exec jq -r 'select(.type == "ping") | .from' {} \; 2>/dev/null | sort -u
   ```
   Also check project-scoped peers if in a project:
   ```bash
   PROJECT_ID=$(find ~/.claude/session-bridge/projects/*/sessions/"$MY_SESSION"/manifest.json -exec jq -r '.projectId' {} \; 2>/dev/null | head -1)
   if [ -n "$PROJECT_ID" ]; then
     find ~/.claude/session-bridge/projects/"$PROJECT_ID"/sessions/ -mindepth 1 -maxdepth 1 -type d ! -name "$MY_SESSION" -exec basename {} \;
   fi
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
8. If it times out, tell the user the peer may be inactive or not in standby mode.

### `listen`

Alias for `standby`. See the `standby` command above. Run it exactly the same way.

---

## No argument / unknown action

If no argument is given, show a brief help:
```
Bridge commands:

  Project:
    /bridge project create <name>     - Create a multi-session project
    /bridge project join <name>       - Join a project (with --role, --specialty, --name)
    /bridge project list              - List all projects

  Session:
    /bridge peers                     - List active sessions
    /bridge status                    - Show bridge state and conversations
    /bridge standby                   - Listen and handle peer messages (blocks)
    /bridge decisions                 - Show pending human-input-needed queue
    /bridge stop                      - Disconnect and clean up

  Legacy (ad-hoc):
    /bridge start                     - Register without a project
    /bridge connect <id>              - Connect to a peer session
    /bridge ask <question>            - Send a question to a peer
    /bridge listen                    - Alias for standby
```
