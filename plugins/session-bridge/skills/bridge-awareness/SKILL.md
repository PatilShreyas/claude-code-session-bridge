---
name: bridge-awareness
description: Activates when a bridge session is active. Teaches the agent to participate in bidirectional, project-scoped multi-session orchestration — registering, routing messages, handling conversations, entering standby, and coordinating with peers autonomously.
---

# Bridge Awareness (v2 — Bidirectional Protocol)

You are connected to other Claude Code sessions via the Claude Bridge plugin. This skill defines how you communicate, coordinate, and collaborate with peer agents in a project-scoped bridge ecosystem.

## Session Lifecycle

Every session follows this lifecycle:

```
Register with role/specialty (project-join.sh)
        |
        v
Receive task (or user prompt)
        |
        v
   +--- Work on task <------------------+
   |        |                            |
   |        v                            |
   |  Need info/help from peer?          |
   |    YES -> open conversation         |
   |        -> send query/escalate       |
   |        -> DECISION POINT:           |
   |          Can proceed without answer?|
   |            YES -> continue working  |
   |              -> response arrives    |
   |                 via PostToolUse hook |
   |              -> integrate answer ---+
   |            NO  -> bridge-receive.sh |
   |              -> blocks up to 90s    |
   |              -> response arrives    |
   |              -> resume task --------+
   |    NO  |
   |        v
   |  Task complete
   |        -> send task-complete
   |        -> check inbox for queued messages
   |        -> handle any pending conversations
   |        v
   |  Enter standby (bridge-listen.sh loop)
   |        |
   |        v
   |  Message arrives
   |        |
   |        v
   |  Handle by type:
   |    task-assign    -> start new task -+
   |    query          -> answer, resume standby
   |    task-cancel    -> acknowledge, resume standby
   |    task-redirect  -> acknowledge, start new task
   |    escalate       -> take ownership, start work
   +-------------------------------------+
```

### 1. Register

Get your session ID. If you're in a project, use `project-join.sh`. Otherwise, fall back to legacy `register.sh`:

```bash
# Project-scoped registration (preferred)
MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-join.sh" "project-name" \
  --role specialist \
  --specialty "your area of expertise")

# Legacy ad-hoc registration
MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh" 2>/dev/null) \
  || MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh")
```

After registration, always set the environment variable for subsequent commands:
```bash
export BRIDGE_SESSION_ID="$MY_SESSION"
```

### 2. Work

Do your assigned task. While working, the `PostToolUse` hook fires `check-inbox.sh --rate-limited` after every tool call, so incoming messages are surfaced automatically. You don't need to poll manually during active work.

### 3. Standby

After finishing all work and sending results, **always** enter the standby listen loop. Never sit idle at the prompt.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-listen.sh" "$MY_SESSION" 60
```

This blocks until a message arrives (via `inotifywait` on Linux, `fswatch` on macOS, or polling fallback) or 60 seconds elapse. When it returns:
- If a message was received: handle it, then re-enter standby.
- If timeout: re-enter standby immediately (the loop continues).

**You MUST keep the standby loop going.** After handling every message, run `bridge-listen.sh` again. Never stop to ask what to do next. Never break the loop unless the user presses Ctrl+C.

---

## Getting Your Session ID

Always use `get-session-id.sh` — it works even if you've cd'd into a subdirectory:

```bash
MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh")
```

---

## Peer Routing Logic

When you need help from another session, follow this routing chain:

### Step 1: Check Topology Hints

Read `project.json` for routing hints keyed by project name:

```bash
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
jq -r ".topology.\"$(basename \"$PWD\")\" // empty" \
  "$BRIDGE_DIR/projects/$PROJECT_ID/project.json"
```

If your project name appears in the topology and has routes, send to the indicated peer.

### Step 2: Match Against Peer Specialties

Scan all peer manifests and match the problem domain against their `specialty` field:

```bash
for MANIFEST in "$BRIDGE_DIR/projects/$PROJECT_ID/sessions"/*/manifest.json; do
  [ -f "$MANIFEST" ] || continue
  jq -r '"\(.sessionId) | \(.projectName) | \(.role) | \(.specialty) | \(.status)"' "$MANIFEST"
done
```

Pick the peer whose specialty best matches your need. Prefer `active` or `idle` peers over `offline` ones.

### Step 3: Ask the Orchestrator

If no match found, send a `routing-query` to the orchestrator:

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$ORCHESTRATOR_ID" routing-query "Who handles database migrations?"
```

The orchestrator responds with a `response` message containing the target session ID and project name. `routing-query` messages do not require a `conversationId`.

---

## Sending Messages

All messages go through `send-message.sh`. Never write message JSON files directly.

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  <target-id> <type> "<content>" \
  [--conversation <conv-id>] \
  [--reply-to <msg-id>] \
  [--urgency normal|high|critical]
```

The script outputs the message ID to stdout. Conversations are auto-created for `task-assign`, `query` (without existing conversation), and `escalate` messages. Conversations are auto-resolved for `task-complete` and `task-cancel` messages.

### Examples

**Send a query (auto-creates conversation):**
```bash
MSG_ID=$(BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$PEER_ID" query "What is the signature of validateToken()?")
```

**Reply within an existing conversation:**
```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$PEER_ID" response "Here is the signature: func validateToken(token string) (Claims, error)" \
  --conversation "$CONV_ID" --reply-to "$ORIG_MSG_ID"
```

**Complete a task:**
```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$REQUESTER_ID" task-complete \
  "Fixed JWT validation. Changed validateToken() to reject expired refresh tokens. Files: auth/jwt.go lines 45-72." \
  --conversation "$CONV_ID" --reply-to "$TASK_MSG_ID"
```

**Escalate to another specialist (creates child conversation):**
```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$AUTH_SESSION_ID" escalate \
  "Bug traced to JWT expiry handling. Can you investigate validateToken() in auth/jwt.go?" \
  --urgency high
```

---

## Receiving Messages

### During Active Work (Hook-Driven)

The `PostToolUse` hook runs `check-inbox.sh --rate-limited` after every tool call. The `UserPromptSubmit` hook runs `check-inbox.sh` when the user presses Enter. Messages are surfaced automatically as system messages — you don't need to poll.

When a message appears mid-task:
- **Critical urgency**: Stop current work and handle immediately.
- **High urgency**: Finish your current step, then handle before continuing.
- **Normal urgency**: Handle at a natural break point. If busy with complex work, send an acknowledgment: "Received, will respond shortly."

### Blocking Wait (bridge-receive.sh)

When you sent a query and **cannot proceed** without the answer, block on it:

```bash
RESPONSE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-receive.sh" "$MY_SESSION" "$MSG_ID" 90)
```

This polls the inbox for up to 90 seconds looking for a reply with `inReplyTo` matching your message ID. Use this only when you truly cannot continue without the response.

### In Standby (bridge-listen.sh)

When idle in the standby loop, `bridge-listen.sh` blocks until a message arrives:

```bash
OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-listen.sh" "$MY_SESSION" 60)
```

The output contains the message details including `FROM=`, `FROM_PROJECT=`, `TO_ID=`, `TYPE=`, `CONTENT=`, `MESSAGE_ID=`, `CONVERSATION_ID=`, and `IN_REPLY_TO=` fields. Parse these to determine how to handle the message.

---

## Message Type Handling

### task-assign

You received a task from the orchestrator or a peer.

1. Read the task content carefully.
2. Check the `conversationId` — you'll use this for all replies.
3. Start working on the task.
4. Send `task-update` messages for significant progress milestones.
5. When done, send `task-complete` with a detailed summary.

```bash
# Acknowledge and begin work (no explicit ack needed — just start working)
# When complete:
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$FROM_ID" task-complete \
  "Completed: <detailed summary of what changed, which files, new APIs>" \
  --conversation "$CONV_ID" --reply-to "$MSG_ID"
```

### query

A peer is asking you a question.

1. Read the question.
2. Use your full context — you are the expert on this project.
3. **Read actual files and include real code** in your response. Don't paraphrase — paste exact signatures, types, implementations.
4. If you can answer fully, send a `response`.
5. If you need more info, send a `response` asking for clarification (the peer will follow up within the same conversation).

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$FROM_ID" response \
  "The validateToken function is at auth/jwt.go:45:
\`\`\`go
func validateToken(token string) (Claims, error) {
    // ... actual code from the file ...
}
\`\`\`" \
  --conversation "$CONV_ID" --reply-to "$MSG_ID"
```

### response

A peer answered your query.

1. Read the response content.
2. If it answers your question, use the information to continue your work.
3. If it's insufficient, send another `query` within the same conversation.
4. **Act on responses** — don't just display them. Use them to update code, fix errors, apply changes.

### escalate

A peer is handing off work to you because it's in your area of expertise.

1. A new child conversation was created with you as the responder.
2. Take ownership of the problem.
3. Work on it as if it were a `task-assign`.
4. When done, send `task-complete` — the result flows back up the escalation chain.

### task-complete

A peer finished work you requested.

1. Read the resolution summary.
2. Integrate the results into your own work.
3. If this was an escalation you made, the child conversation is now resolved. Continue with your parent task using the results.
4. If all your work is done, send `task-complete` to your own requester (results flow up the chain).

### task-cancel

Your current task has been cancelled.

1. Stop work on the cancelled task.
2. Clean up any partial state if needed.
3. Return to standby.

### task-redirect

Your current task is being replaced with a new one.

1. The old conversation is resolved by this message.
2. Read the new task details in `content`.
3. Create a new conversation for the new task:
   ```bash
   NEW_CONV=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/conversation-create.sh" \
     "$PROJECT_ID" "$FROM_ID" "$MY_SESSION" "Redirected: <new task topic>")
   ```
4. Begin working on the new task using the new conversation.

### human-input-needed

A peer (usually a specialist) needs a human decision. If you are the orchestrator, add it to your decision queue. If you are a specialist and receive this, forward it to the orchestrator.

### human-response

The human answered a decision you escalated. Read the response and adjust your work accordingly. If you were blocked on this decision (`blocksWork: true`), resume your task now.

### routing-query

A peer is asking "who handles X?" Only orchestrators handle these.

1. Read the query.
2. Match the problem domain against your known topology and peer specialties.
3. Respond with the target session ID and project name.

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$FROM_ID" response \
  "Route to session $TARGET_ID (project: $TARGET_NAME) — they handle $DOMAIN" \
  --reply-to "$MSG_ID"
```

### ping

Connection check. Respond with a ping back:

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$FROM_ID" ping "connected"
```

---

## Decision Point: Block or Continue?

When you send a query or escalation and are waiting for a response, ask yourself:

**Can I proceed with other work while waiting?**

- **YES** — Continue working. The response will arrive via the `PostToolUse` hook. When it appears in a system message, integrate the answer and continue.

- **NO** — You are blocked. Use `bridge-receive.sh` to wait synchronously:
  ```bash
  RESPONSE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-receive.sh" "$MY_SESSION" "$MSG_ID" 90)
  ```
  If it times out after 90 seconds, check if the peer is still active. If so, re-enter standby — the response will arrive eventually. If the peer is offline, consider escalating to another peer or the orchestrator.

---

## Include Real Code in Responses

When a peer asks about your project, **read actual files and include the code**. Don't describe code from memory — read it fresh and paste the relevant sections.

Good response:
> "The `validateToken` function is in `auth/jwt.go`:
> ```go
> func validateToken(token string) (Claims, error) {
>     parsed, err := jwt.Parse(token, keyFunc)
>     if err != nil { return Claims{}, err }
>     claims := parsed.Claims.(jwt.MapClaims)
>     if claims.ExpiresAt < time.Now().Unix() {
>         return Claims{}, ErrTokenExpired
>     }
>     return toClaims(claims), nil
> }
> ```
> Changed in commit abc123 — it now rejects expired refresh tokens too."

Bad response:
> "The validateToken function checks the JWT and returns claims. I think it takes a string."

---

## Escalate, Don't Guess

If a query or task is outside your specialty:

1. Don't attempt work you're not qualified for.
2. Route to the right peer using the routing logic above.
3. Send an `escalate` message with full context about the problem.

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$BETTER_PEER_ID" escalate \
  "This query about database connection pooling is outside my area (I handle frontend). Context: <full details from the original query>"
```

If you're unsure who handles it, ask the orchestrator via `routing-query`.

---

## Resolution Summaries Flow Up

When sending `task-complete`, include enough detail so the receiver can continue without follow-up questions:

- **What changed**: specific files, functions, lines
- **What the new behavior is**: API signatures, return types, config changes
- **What the receiver needs to do**: migration steps, dependency updates, code changes on their side

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$REQUESTER_ID" task-complete \
  "Fixed auth bug. Changes:
- auth/jwt.go:45-72: validateToken() now rejects expired refresh tokens
- auth/middleware.go:23: Added RefreshTokenExpired error type
- New API: validateToken(token string, opts ...ValidateOption) (Claims, error)
  The second variadic param is new — callers using validateToken(token) still work.
You may need to update your error handling to catch RefreshTokenExpired." \
  --conversation "$CONV_ID" --reply-to "$TASK_MSG_ID"
```

---

## Human-in-the-Loop: Decision Escalation

When you hit a decision that requires human judgment — design choices, architecture questions, ambiguous requirements — send a `human-input-needed` message.

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$ORCHESTRATOR_ID" human-input-needed \
  "API response format: nested resources (richer, slower) or flat IDs with separate endpoints (faster, more requests)?" \
  --conversation "$CONV_ID" --urgency high
```

Two fields in the message metadata control the flow:
- **`proposedDefault`** — Your best guess with reasoning.
- **`blocksWork`** — Whether you can continue with your default or must wait.

### Non-Blocking Decision (blocksWork: false)

Continue working with your proposed default. Flag the assumption in a code comment:
```
// ASSUMPTION: Using flat IDs per default — pending human decision (conv-xxx)
```

If the human later overrides via `human-response`, adjust your work.

### Blocking Decision (blocksWork: true)

You cannot continue. Enter standby and wait for a `human-response` message:

```bash
# After sending human-input-needed with blocksWork: true
# Enter standby — the response will arrive as a human-response message
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-listen.sh" "$MY_SESSION" 60
```

When the `human-response` arrives, read the decision and resume your task.

---

## Orchestrator-Specific Behaviors

If your role is `orchestrator`, you have additional responsibilities:

### Task Decomposition

When the user gives you a high-level task (e.g., "Fix issues #123, #124, #125"):

1. Analyze each task and determine which specialist handles it.
2. Create `task-assign` messages for each specialist.
3. Track which tasks are pending, in-progress, and complete.

```bash
# Assign task to the auth specialist
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$AUTH_SESSION_ID" task-assign \
  "Fix issue #123: JWT tokens expire too quickly. See github.com/org/repo/issues/123" \
  --urgency normal
```

### Routing-Query Handling

When a peer sends a `routing-query`, match the problem domain against your known topology and peer specialties, then respond:

```bash
# Peer asked: "Who handles database migrations?"
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$FROM_ID" response \
  "Route to $FRAMEWORK_ID (framework) — they handle database layer and migrations" \
  --reply-to "$MSG_ID"
```

### Decision Queue

Collect `human-input-needed` messages from all specialists. Surface them when the user interacts:

- The `UserPromptSubmit` hook includes pending decisions in the system message under `=== DECISIONS AWAITING YOUR INPUT ===`.
- The user can run `/bridge decisions` to see the full queue.
- When the user provides an answer, send `human-response` back to the originating session.

```bash
BRIDGE_SESSION_ID="$MY_SESSION" bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" \
  "$SPECIALIST_ID" human-response \
  "Use flat IDs with separate endpoints. Performance is the priority for this API." \
  --conversation "$CONV_ID" --reply-to "$DECISION_MSG_ID"
```

### Conversation Tree Tracking

Track the full tree of conversations:

```
conv-001: Orchestrator <-> Dev        (parent: null)     — status: open
  conv-002: Dev <-> Framework         (parent: conv-001) — status: resolved
    conv-003: Framework <-> Auth      (parent: conv-002) — status: resolved
```

When all child conversations in a chain resolve, the parent task can complete. Monitor conversation files to know when work is done:

```bash
# Check all conversations in the project
for CONV in "$BRIDGE_DIR/projects/$PROJECT_ID/conversations"/conv-*.json; do
  [ -f "$CONV" ] || continue
  jq -r '"\(.conversationId) | \(.status) | \(.topic) | initiator=\(.initiator) responder=\(.responder)"' "$CONV"
done
```

When all subtasks in a chain resolve, synthesize results and report to the user.

---

## Orchestrator Failure Detection

If you are a specialist, monitor the orchestrator's health before sending `task-complete` messages:

```bash
# Check orchestrator heartbeat
ORCH_MANIFEST="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$ORCHESTRATOR_ID/manifest.json"
LAST_HB=$(jq -r '.lastHeartbeat' "$ORCH_MANIFEST")
```

If the orchestrator's `lastHeartbeat` is older than 5 minutes:

1. **Pause non-critical work.** Don't pick up new tasks.
2. **Continue in-progress work** that doesn't require orchestrator interaction.
3. **Queue `task-complete` messages** — don't send them to a dead session.
4. **Print a notification:** "Orchestrator appears offline. Pausing task reporting. Current work saved."
5. **Wait for recovery.** When the orchestrator re-joins (heartbeat resumes), flush queued messages.

Do **not** promote yourself to orchestrator. Wait for the user to restart the orchestrator session.

---

## Conversations

Conversations are the threading mechanism for all exchanges. They track topic, participants, and resolution status.

### Checking for Existing Conversations

Before creating a new conversation with a peer, check if you already have an open one on the same topic:

```bash
for CONV in "$BRIDGE_DIR/projects/$PROJECT_ID/conversations"/conv-*.json; do
  [ -f "$CONV" ] || continue
  STATUS=$(jq -r '.status' "$CONV")
  [ "$STATUS" = "resolved" ] && continue
  PEER=$(jq -r "if .initiator == \"$MY_SESSION\" then .responder else .initiator end" "$CONV")
  [ "$PEER" = "$TARGET_PEER" ] || continue
  TOPIC=$(jq -r '.topic' "$CONV")
  echo "Open conversation with $TARGET_PEER: $(jq -r '.conversationId' "$CONV") — $TOPIC"
done
```

Reuse an existing open conversation rather than creating a duplicate.

### Before Entering Standby

Check for open conversations that are waiting for responses. Mention them so context survives compaction:

```bash
echo "Open conversations awaiting responses:"
for CONV in "$BRIDGE_DIR/projects/$PROJECT_ID/conversations"/conv-*.json; do
  [ -f "$CONV" ] || continue
  STATUS=$(jq -r '.status' "$CONV")
  [ "$STATUS" = "waiting" ] || continue
  jq -r '"\(.conversationId): \(.topic) (waiting since \(.createdAt))"' "$CONV"
done
```

---

## When to Query Peers Proactively

**Query immediately** (don't wait for errors):
- User says to update/upgrade a dependency managed by a peer
- User mentions breaking changes, migration, or version bump involving a peer's project
- User asks about a peer's project ("what does the library expose?", "what API should I use?")

**Query on errors:**
- Compile/build errors on dependency code from a peer
- API mismatches — functions that don't exist or have wrong signatures
- Type errors on types defined in a peer's project
- Missing modules/packages from a peer's library

---

## Viewing Peers

List all sessions in your project:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-peers.sh" --project "$PROJECT_ID"
```

This shows session ID, project name, role, status, and specialty for each peer.

---

## Important Rules

1. **Always enter standby after finishing work.** Never idle at the prompt. Run `bridge-listen.sh` in a loop.
2. **Always use `send-message.sh`** — never write message JSON files directly.
3. **Always use `get-session-id.sh`** to get your session ID — never read `.claude/bridge-session` directly (relative path breaks when working directory changes).
4. **Include real code in responses** — read actual files and paste relevant sections.
5. **Escalate, don't guess** — if outside your specialty, route to the right peer.
6. **Resolution summaries flow up** — `task-complete` carries enough detail for the receiver to continue.
7. **Handle follow-up questions** — if a peer's response asks for clarification, answer and continue the conversation.
8. **Act on responses** — don't just display them. Use them to update code, fix errors, apply changes.
9. **Track conversations** — before standby, check for pending conversations so context survives compaction.
10. **Route to the right peer** when connected to multiple. Use topology hints, then specialty matching, then orchestrator query.
