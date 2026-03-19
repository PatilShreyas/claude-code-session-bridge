# Bidirectional Session Bridge with Project Orchestration

**Date:** 2026-03-19
**Status:** Approved (design phase)
**Scope:** Replace the one-directional listen/ask model with fully bidirectional, project-scoped, autonomous multi-session orchestration.

## Problem

The current session bridge has a fundamental limitation: `/bridge listen` puts a session into a blocking listener mode where it can only answer queries. Asking sessions can only ask. Communication is one-directional — one side must be dedicated to listening while the other asks. Two sessions cannot collaborate as equals, and there is no support for multi-session orchestration, task delegation chains, or autonomous inter-session coordination.

## Goal

Enable fully bidirectional communication between Claude Code sessions with:

- **Project-scoped session groups** — sessions belong to named projects, isolated from each other
- **Role-based routing** — sessions register with specialties, queries route to the right peer
- **Autonomous task delegation chains** — orchestrator assigns work, specialists escalate to each other, results roll back up
- **Minimal user intervention** — sessions coordinate autonomously; the user interacts through one cockpit session
- **Human-in-the-loop for decisions** — agents escalate design choices and ambiguous requirements to the user rather than guessing

### Target Scenario

User creates GitHub issues. Orchestrator session sees them and assigns each to the right specialist session. A specialist working on an issue discovers a bug in the shared framework. It hands off to the framework session. The framework session traces the root cause to the auth server. The auth server session fixes it and reports back. The fix cascades back up the chain — framework adapts, original specialist finishes the issue, orchestrator updates and closes the GitHub issue. All without the user switching terminals.

---

## Section 1: Project & Session Structure

### Directory Layout

Sessions are grouped under named projects instead of a flat global list:

```
~/.claude/session-bridge/
  projects/
    plextura-suite/
      project.json
      conversations/
        conv-<id>.json
      sessions/
        <session-id>/
          manifest.json
          inbox/
          outbox/
          watcher.pid
    website-redesign/
      project.json
      conversations/
      sessions/
        ...
  sessions/                            # Legacy flat structure for ad-hoc bridges
    ...
```

### project.json

Created by the first session (typically the orchestrator). Contains project metadata and optional topology routing hints.

```json
{
  "projectId": "plextura-suite",
  "name": "Plextura Suite Development",
  "createdAt": "2026-03-19T...",
  "createdBy": "q7w4r2",
  "topology": {
    "q7w4r2": { "routes": ["f8k2m1", "p3x9n7", "d5j8v3"] },
    "p3x9n7": { "routes": ["f8k2m1"] }
  }
}
```

The `topology` field provides orchestrator-defined routing hints. Optional — sessions without explicit routes fall back to specialty matching.

### Enhanced manifest.json

Each session registers with its role and specialty:

```json
{
  "sessionId": "f8k2m1",
  "projectId": "plextura-suite",
  "projectName": "auth-server",
  "projectPath": "/home/me/projects/auth-server",
  "role": "specialist",
  "specialty": "authentication, authorization, JWT, session management",
  "startedAt": "...",
  "lastHeartbeat": "...",
  "status": "active",
  "capabilities": ["query", "task-execution", "escalation"]
}
```

### Session States

| State | Meaning | How Set |
|-------|---------|---------|
| `active` | Agent is working (tools running, user interacting) | Any hook fires → set active |
| `idle` | Session open, in standby listen loop | Agent enters bridge-listen.sh standby |
| `offline` | Session ended or crashed | cleanup.sh or no heartbeat for 30+ minutes |

### Peer Discovery

Any session in a project can scan `projects/<projectId>/sessions/*/manifest.json` to see all peers and their specialties. Alternatively, a session can ask the orchestrator "who handles X?" via a `routing-query` message.

### Backward Compatibility

The old flat `sessions/` directory still works for ad-hoc two-session bridges that don't need project scoping. The project system is opt-in.

---

## Section 2: Conversation Protocol

Every exchange between sessions happens within a conversation — a threaded, stateful container that tracks participants, topic, and resolution status.

### Conversation File

Stored at `projects/<projectId>/conversations/conv-<id>.json`:

```json
{
  "conversationId": "conv-a1b2c3",
  "topic": "Bug in user auth flow - issue #123",
  "initiator": "q7w4r2",
  "responder": "f8k2m1",
  "parentConversation": null,
  "status": "open",
  "createdAt": "2026-03-19T...",
  "resolvedAt": null,
  "resolution": null
}
```

### Pairwise Conversations with Escalation Chains

Conversations are always between exactly two sessions. Escalation creates a new child conversation linked by `parentConversation`:

```
conv-001: Orchestrator <-> Dev        (parent: null)
  conv-002: Dev <-> Framework         (parent: conv-001)
    conv-003: Framework <-> Auth      (parent: conv-002)
```

### Message Types

| Type | Purpose | Creates Conversation? |
|------|---------|----------------------|
| `task-assign` | Orchestrator delegates work | Yes |
| `query` | Need info or help from peer | Yes (or within existing) |
| `response` | Answer to a query | No (within existing) |
| `escalate` | Route to another specialist | Yes (child conversation) |
| `task-complete` | Work done, here's the result | No (resolves conversation) |
| `task-update` | Progress report | No (within existing) |
| `task-cancel` | Stop current task | No (resolves conversation) |
| `task-redirect` | Cancel + assign new task | No (resolves + creates new) |
| `human-input-needed` | Decision requires human judgment | No (within existing) |
| `human-response` | Human's answer to a decision | No (within existing) |
| `routing-query` | "Who handles X?" (ask orchestrator) | No |
| `ping` | Connection check | No |
| `session-ended` | Cleanup notification | No |

### Enhanced Message Format

```json
{
  "id": "msg-abc123def456",
  "conversationId": "conv-a1b2c3",
  "from": "f8k2m1",
  "to": "p3x9n7",
  "type": "task-complete",
  "timestamp": "...",
  "status": "pending",
  "content": "Fixed JWT validation. Changed validateToken() to reject expired refresh tokens.",
  "inReplyTo": "msg-xyz789",
  "metadata": {
    "urgency": "normal",
    "fromProject": "auth-server",
    "fromRole": "specialist"
  }
}
```

### Message Urgency Levels

| Urgency | Behavior |
|---------|----------|
| `normal` | Picked up on next hook cycle, handled after current work |
| `high` | Picked up on next hook cycle, agent prioritizes over current work |
| `critical` | Hook bypasses rate limiting, system message tells agent to stop and handle immediately |

### Resolution Rollup

When a conversation chain resolves, results flow back up:

1. Auth fixes bug → sends `task-complete` to Framework → conv-003 resolved
2. Framework adapts → sends `task-complete` to Dev → conv-002 resolved
3. Dev finishes issue → sends `task-complete` to Orchestrator → conv-001 resolved
4. Orchestrator updates GitHub issue

Each `task-complete` carries a summary of what was done so the receiving session has enough context to continue without follow-up questions.

### Multi-Turn Within a Conversation

If a response isn't sufficient, the receiver sends another `query` within the same `conversationId`. The conversation stays `open` until someone sends `task-complete` or both sides agree it's resolved.

---

## Section 3: Hook-Driven Communication

Replaces the blocking `/bridge listen` loop. Every session is always reachable — messages are picked up passively through hooks during active work, and through a standby listen loop during idle time.

### Two Hooks, Two Triggers

| Hook | Fires When | Purpose |
|------|-----------|---------|
| `UserPromptSubmit` | User presses Enter | Immediate inbox check |
| `PostToolUse` | Agent finishes any tool call | Catches messages during autonomous work |

### Rate Limiting for PostToolUse

A timestamp file prevents excessive scanning. The inbox is checked at most once every 5 seconds during autonomous work, and immediately on every user prompt:

```bash
LAST_CHECK_FILE="$BRIDGE_DIR/.last_inbox_check"
NOW=$(date +%s)
LAST=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)

# Always check immediately for critical messages
HAS_CRITICAL=$(find "$INBOX" -name "*.json" -newer "$LAST_CHECK_FILE" \
  -exec jq -r 'select(.status=="pending" and .metadata.urgency=="critical") | .id' {} \; \
  2>/dev/null | head -1)

if [ -n "$HAS_CRITICAL" ] || [ $((NOW - LAST)) -ge 5 ]; then
  echo "$NOW" > "$LAST_CHECK_FILE"
  # Proceed with full inbox scan...
fi
```

Critical-urgency messages bypass the rate limit entirely.

### Updated hooks.json

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-inbox.sh\"",
          "async": false
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-inbox.sh\" --rate-limited",
          "async": false
        }]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh\"",
          "async": false
        }]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-inbox.sh\" --summary-only",
          "async": false
        }]
      }
    ]
  }
}
```

### Standby Mode (Idle Sessions)

Sessions that are idle (no active work, waiting for tasks) enter a standby listen loop. The agent runs `bridge-listen.sh` as its last action after completing work. This blocks until a message arrives, then the agent handles it and re-enters standby.

```
Agent completes task
  → sends task-complete
  → checks inbox for queued messages
  → nothing pending? enters bridge-listen.sh (blocks)
  → message arrives → bridge-listen.sh returns
  → agent handles message
  → if new task: works on it, then back to standby
  → if query: answers it, then back to standby
```

`bridge-listen.sh` uses `inotifywait` (Linux) or `fswatch` (macOS) for zero-CPU blocking on filesystem events. Falls back to polling if neither is available. Called with ~60 second timeouts so the user can Ctrl+C between cycles if needed.

The agent is never truly idle at the prompt — it is either working or blocking on `bridge-listen.sh`. Sessions can sit in standby for hours with zero CPU usage and wake instantly when a message arrives.

### Message Flow During Active Work

```
Session A (Dev)                              Session B (Framework)
                                             [working on a task]

1. Sends query to B's inbox
2. Continues own work
                                             3. PostToolUse hook fires
                                             4. check-inbox.sh finds message
                                             5. Agent handles query inline
                                             6. Sends response to A's inbox
                                             7. Resumes its own work

8. Next hook fires
9. check-inbox.sh finds response
10. Agent acts on response, continues
```

### Message Flow to Idle Session

```
Session A (Dev)                              Session B (Framework)
                                             [standby: bridge-listen.sh blocking]

1. Sends query to B's inbox
2. Continues own work (or enters standby)
                                             3. inotifywait detects new file
                                             4. bridge-listen.sh returns message
                                             5. Agent handles query
                                             6. Sends response to A's inbox
                                             7. Re-enters bridge-listen.sh
```

### Interrupt Priority Chain

```
critical bridge message  →  bypasses rate limit, interrupts work
high bridge message      →  next hook cycle, agent reprioritizes
normal bridge message    →  next hook cycle, handled in order
user Ctrl+C              →  breaks current operation, direct interaction
```

### Background Inbox Watcher (Optional Enhancement)

A lightweight background process started by `register.sh` that uses `inotifywait` to watch the inbox directory. When a message arrives while the session is between states (e.g., the agent somehow returned to the prompt without entering standby), it prints a terminal notification:

```
>> Bridge: query from "auth-server" — press Enter to process.
```

Also handles periodic heartbeat updates so idle sessions aren't marked stale. PID stored in `session-dir/watcher.pid`, killed by `cleanup.sh`.

---

## Section 4: Skill & Agent Awareness

The SKILL.md that teaches every agent how to behave in the bridge ecosystem. Replaces the current `bridge-awareness` skill.

### Session Lifecycle

```
Register with role/specialty
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
   |        -> send query                |
   |        -> continue other work       |
   |        -> pick up response via hook |
   |        -> resume task --------------+
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

### Peer Routing Logic

```
Need help from another session?
        |
        v
  Check project.json topology hints
        |
  Found route? --YES--> Send to that peer
        |
        NO
        |
        v
  Scan sessions/*/manifest.json
  Match problem domain against peer specialties
        |
  Found match? --YES--> Send to best match
        |
        NO
        |
        v
  Ask orchestrator via routing-query
        --> Orchestrator responds with peer ID
        --> Send to that peer
```

### Key Agent Behaviors

1. **Always enter standby after finishing work.** Never return to the prompt idle. Run `bridge-listen.sh` in a loop.

2. **Handle incoming messages promptly.** If a hook surfaces a message while mid-task, address it first. For non-critical messages during complex work, send a "busy, will respond shortly" acknowledgment.

3. **Include real code in responses.** When answering a peer's query, read actual files and include relevant code — exact signatures, types, and implementations. Don't paraphrase.

4. **Track your conversations.** Before entering standby, check for open conversations waiting for responses. Mention them in standby messages so context survives compaction.

5. **Escalate, don't guess.** If a query is outside your specialty, escalate to the right peer or ask the orchestrator for routing.

6. **Resolution summaries flow up.** When sending `task-complete`, include enough detail — what changed, which files, what the new API looks like — so the receiver can continue without follow-ups.

### Human-in-the-Loop: Decision Escalation

When an agent hits a decision that requires human judgment (design choices, architecture, feature details, ambiguous requirements), it sends a `human-input-needed` message.

```json
{
  "type": "human-input-needed",
  "urgency": "high",
  "content": "API response format: nested resources (richer, slower) or flat IDs with separate endpoints (faster, more requests)?",
  "metadata": {
    "proposedDefault": "flat IDs — matches existing codebase patterns",
    "blocksWork": false,
    "context": "Working on issue #123, building GET /users/{id}/projects"
  }
}
```

Two fields control the flow:

- **`proposedDefault`** — The agent's best guess with reasoning.
- **`blocksWork`** — Whether the agent can continue with its default or must wait.

Non-blocking decisions: agent continues with its proposed default, flags the assumption in code. If the human later overrides, the agent adjusts.

Blocking decisions: agent enters standby and waits for a `human-response` message before resuming.

The orchestrator collects `human-input-needed` messages and presents them as a decision queue when the user interacts:

```
3 decisions need your input:

1. [framework] API response format — flat IDs vs nested
   Recommendation: flat IDs. Status: continued with default.

2. [auth-server] JWT expiry — 15min vs 1hr tokens
   Recommendation: none. Status: BLOCKED, waiting on you.

3. [dev] Add rate limiting to new endpoint?
   Recommendation: yes, 100 req/min. Status: continued with default.
```

### Orchestrator-Specific Behaviors

Additional guidance for sessions with the `orchestrator` role:

- Parse incoming task requests (from user or external sources) and decompose into subtasks
- Match subtasks to specialist sessions based on topology + specialties
- Track the full conversation tree — know which tasks are pending, blocked, or complete
- When all subtasks in a chain resolve, synthesize results and report to the user
- Handle `routing-query` messages — peers ask "who handles X?" and the orchestrator answers
- Maintain the human decision queue and surface it when the user interacts

---

## Section 5: Commands

Commands handle setup and status. Actual communication happens through natural language processed by the skill.

### Command Set

| Command | Purpose |
|---------|---------|
| `/bridge project create <name>` | Create a multi-session project |
| `/bridge project join <name>` | Join a project with role/specialty |
| `/bridge project list` | List all projects on this machine |
| `/bridge peers` | List sessions in current project with roles/status |
| `/bridge status` | Conversations, pending decisions, message counts |
| `/bridge standby` | Explicitly enter the standby listen loop |
| `/bridge stop` | Disconnect, notify peers, cleanup |

### Removed/Replaced Commands

| Old | New |
|-----|-----|
| `/bridge listen` | `/bridge standby` (+ automatic standby via skill) |
| `/bridge connect <id>` | Unnecessary — project members see each other |
| `/bridge start` | `/bridge project join` for project use |
| `/bridge ask <question>` | Natural language via skill (still works as shortcut) |

### Typical Setup Flow

```
Terminal 1 (orchestrator):
> /bridge project create plextura-suite
> /bridge project join plextura-suite --role orchestrator \
    --specialty "task coordination, issue triage"

Terminal 2 (auth server):
> /bridge project join plextura-suite --role specialist \
    --specialty "authentication, JWT, authorization"
> /bridge standby

Terminal 3 (framework):
> /bridge project join plextura-suite --role specialist \
    --specialty "shared libraries, core utilities, database layer"
> /bridge standby

Terminal 1 (user talks to orchestrator):
> Here are today's issues: #123, #124, #125. Assign to the right sessions.
  [Orchestrator analyzes, routes, sends task-assign messages]
  [User walks away — sessions coordinate autonomously]
```

### Backward Compatibility

The old flat `/bridge start` + `/bridge connect <id>` commands still work for quick ad-hoc two-session bridges without project scoping.

---

## Scripts: New and Modified

### New Scripts

| Script | Purpose |
|--------|---------|
| `project-create.sh` | Create project directory structure and project.json |
| `project-join.sh` | Register session within a project (enhanced register.sh) |
| `project-list.sh` | List all projects |
| `conversation-create.sh` | Create a conversation file |
| `conversation-update.sh` | Update conversation status (open/waiting/resolved) |
| `inbox-watcher.sh` | Background inotifywait watcher for idle notifications + heartbeat |

### Modified Scripts

| Script | Changes |
|--------|---------|
| `register.sh` | Support project-scoped registration, role/specialty fields |
| `send-message.sh` | Add conversationId, urgency, new message types |
| `check-inbox.sh` | Rate limiting (--rate-limited flag), project-scoped inbox scanning, urgency-aware |
| `bridge-listen.sh` | Use inotifywait/fswatch instead of polling, project-scoped inbox path |
| `cleanup.sh` | Handle project-scoped sessions, conversation cleanup |
| `list-peers.sh` | Show roles, specialties, project grouping |
| `connect-peer.sh` | Adapt for project-scoped sessions (still used for ad-hoc bridges) |

### Unchanged Scripts

| Script | Notes |
|--------|-------|
| `bridge-receive.sh` | Still works as optional sync wait fallback |
| `heartbeat.sh` | Still works, also supplemented by inbox-watcher.sh |
| `get-session-id.sh` | Still works, extended to check project-scoped paths |
