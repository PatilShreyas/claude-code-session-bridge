<p align="center">
  <h1 align="center">session-bridge</h1>
  <p align="center">
    <strong>Bidirectional, project-scoped orchestration between Claude Code sessions</strong>
  </p>
  <p align="center">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
    <img src="https://img.shields.io/badge/tests-287%20passing-brightgreen" alt="Tests">
    <img src="https://img.shields.io/badge/version-0.2.0-blue" alt="Version 0.2.0">
  </p>
  <p align="center">
    <a href="#quick-start">Quick Start</a> &middot;
    <a href="#orchestration-mode">Orchestration</a> &middot;
    <a href="#commands">Commands</a> &middot;
    <a href="#how-it-works">How It Works</a> &middot;
    <a href="#ad-hoc-mode">Ad-Hoc Mode</a>
  </p>
</p>

---

When you're working across multiple repos — a shared library and its consumer, a backend and frontend, microservices — each Claude Code session is isolated. **session-bridge** lets them coordinate autonomously.

**v2** adds bidirectional communication, project-scoped session groups, conversation threading, task delegation chains, and human-in-the-loop decision escalation. Sessions can work, delegate, escalate, and report back — all without you switching terminals.

## Getting Started

### 1. Install

```bash
# Install dependencies
brew install jq                    # macOS
sudo apt install jq inotify-tools  # Linux (inotify-tools optional but recommended)

# Clone and install
git clone https://github.com/DiAhman/claude-code-session-bridge.git ~/claude-code-session-bridge
```

Then start Claude with the plugin:
```bash
claude --plugin-dir ~/claude-code-session-bridge/plugins/session-bridge
```

For permanent loading, add to `~/.claude/settings.json`:
```json
{
  "extraKnownMarketplaces": {
    "session-bridge": {
      "source": {
        "source": "directory",
        "path": "~/claude-code-session-bridge"
      }
    }
  },
  "enabledPlugins": {
    "session-bridge@session-bridge": true
  }
}
```

### 2. Quick Test (Two Sessions)

**Terminal 1** (orchestrator):
```
cd ~/projects/my-app && claude

> /bridge project create my-suite
> /bridge project join my-suite --role orchestrator --specialty "coordination"
```

**Terminal 2** (specialist):
```
cd ~/projects/my-library && claude

> /bridge project join my-suite --role specialist --specialty "authentication, JWT"
> /bridge standby
```

Back in **Terminal 1**, just talk naturally:
```
> Ask the authentication session what token format they use
```

The orchestrator sends a query through the bridge, the specialist wakes up from standby, reads its project files, and responds with actual code. No `/bridge ask` needed — just natural language.

---

## Orchestration Mode

The real power of v2: **multi-session autonomous orchestration**.

### Setup

Open terminals for each component of your project. Each joins the same bridge project with its role:

```
Terminal 1 (orchestrator):    /bridge project join plextura --role orchestrator --specialty "coordination"
Terminal 2 (auth server):     /bridge project join plextura --role specialist --specialty "auth, JWT, sessions"
Terminal 3 (framework):       /bridge project join plextura --role specialist --specialty "shared libs, database"
Terminal 4 (frontend):        /bridge project join plextura --role specialist --specialty "React, UI components"
```

Put specialists in standby (`/bridge standby`), then talk to the orchestrator:

```
> Here are today's issues: #123 (auth token regression), #124 (framework logging),
  #125 (new user dashboard). Assign them to the right sessions.
```

The orchestrator analyzes each issue, matches it to the right specialist based on their registered specialty, and sends `task-assign` messages. Specialists wake up, do the work, and report back.

### Task Delegation Chains

When a specialist hits a problem outside its area, it automatically escalates:

```
Orchestrator assigns issue #123 to auth-server
  -> Auth-server finds the root cause is in the framework's JWT middleware
  -> Auth-server escalates to framework session
  -> Framework investigates, finds it also needs a database migration
  -> Framework fixes the migration, reports back to auth-server
  -> Auth-server applies the fix, reports back to orchestrator
  -> Orchestrator marks issue #123 resolved
```

Each handoff creates a **conversation** — a threaded, stateful exchange between two sessions. Conversations link via `parentConversation` to form escalation chains. When a child conversation resolves, results flow back up.

### Human-in-the-Loop

When an agent hits a decision it can't make alone — architecture choices, design decisions, ambiguous requirements — it escalates to the human:

```
Orchestrator: "2 decisions need your input:

1. [auth-server] JWT expiry: 15min vs 1hr tokens
   Recommendation: 15min. Status: BLOCKED, waiting on you.

2. [framework] Database: PostgreSQL or SQLite for the new service?
   Recommendation: PostgreSQL. Status: continued with default."
```

Non-blocking decisions: the agent continues with its proposed default and adjusts if you override later.
Blocking decisions: the agent waits in standby until you answer.

Run `/bridge decisions` in the orchestrator to see the queue anytime.

---

## Commands

### Project Commands

| Command | Description |
|---------|-------------|
| `/bridge project create <name>` | Create a multi-session project |
| `/bridge project join <name>` | Join with `--role`, `--specialty`, `--name` flags |
| `/bridge project list` | List all projects on this machine |

### Session Commands

| Command | Description |
|---------|-------------|
| `/bridge peers` | List sessions in current project with roles/status |
| `/bridge status` | Show conversations, pending decisions, message counts |
| `/bridge standby` | Enter standby loop — handle messages continuously |
| `/bridge decisions` | Show pending human-input-needed queue |
| `/bridge stop` | Disconnect, notify peers, clean up |

### Legacy Commands (Ad-Hoc Mode)

| Command | Description |
|---------|-------------|
| `/bridge start` | Register without a project (ad-hoc mode) |
| `/bridge connect <id>` | Connect to a peer by session ID |
| `/bridge ask <question>` | Send a question and wait for response |
| `/bridge listen` | Alias for standby |

> **Tip:** You rarely need explicit commands. Just tell your agent what to do in natural language — "ask the backend about the API changes" or "coordinate with the auth team on this migration" — and the bridge skill handles the rest.

---

## How It Works

### Hook-Driven Communication

Every session is always reachable. No dedicated "listener" mode needed.

- **`UserPromptSubmit` hook** — checks inbox when you press Enter
- **`PostToolUse` hook** — checks inbox (rate-limited to every 5 seconds) during autonomous agent work
- **Standby mode** — when idle, agents block on `bridge-listen.sh` using `inotifywait` (zero CPU, instant wakeup)

Messages arrive passively through hooks during active work, and through the standby loop when idle. A session can both send AND receive — fully bidirectional.

### Conversations

Every exchange happens within a **conversation** — a threaded container with topic, participants, and status:

```json
{
  "conversationId": "conv-a1b2c3d4",
  "topic": "JWT validation bug",
  "initiator": "abc123",
  "responder": "def456",
  "parentConversation": "conv-x7y8z9",
  "status": "open"
}
```

Conversations are auto-created when you send a `query` or `task-assign`, and auto-resolved when you send `task-complete`. No manual thread management.

### Message Types

| Type | Purpose |
|------|---------|
| `task-assign` | Delegate work to a specialist |
| `query` | Ask a peer for information |
| `response` | Answer a query |
| `escalate` | Route to another specialist (creates child conversation) |
| `task-complete` | Report finished work with summary |
| `task-update` | Progress report |
| `task-cancel` / `task-redirect` | Cancel or replace a task |
| `human-input-needed` | Escalate a decision to the user |
| `human-response` | User's answer to a decision |
| `routing-query` | "Who handles X?" (ask the orchestrator) |

### Peer Routing

When a session needs help, it follows a routing chain:

1. **Topology hints** — `project.json` may specify explicit routes
2. **Specialty matching** — scan peer manifests, match against `specialty` field
3. **Orchestrator query** — send a `routing-query` and get directed

### Project Structure

Sessions are grouped under named projects:

```
~/.claude/session-bridge/
  projects/
    plextura-suite/
      project.json              # Project metadata + topology
      conversations/            # Conversation state files
      sessions/
        abc123/                 # Auth server session
          manifest.json         # Role, specialty, heartbeat
          inbox/                # Incoming messages
          outbox/               # Sent messages
        def456/                 # Framework session
          ...
  sessions/                     # Legacy flat structure (ad-hoc mode)
```

### Role Persistence

When you join a project with `--role orchestrator`, the role is saved to `.claude/bridge-role` in your project directory. Next time you join the same project, the role is automatically applied — no flags needed.

---

## Ad-Hoc Mode

The original v1 bridge still works for quick two-session setups without project scoping:

```
Terminal 1: /bridge start          -> Session ID: a1b2c3
Terminal 2: /bridge connect a1b2c3 -> Connected to 'my-library'
Terminal 1: /bridge standby        -> Standing by for messages...
Terminal 2: /bridge ask "What changed in v2?"
```

Ad-hoc sessions live in the flat `~/.claude/session-bridge/sessions/` directory and don't need project creation or roles.

---

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Linux | Tested | `inotifywait` for zero-CPU standby (install `inotify-tools`) |
| macOS | Should work | `fswatch` alternative, BSD `date` fallback |
| Windows | Not supported | |

## Prerequisites

- **jq** — JSON processing (required)
- **inotify-tools** — filesystem watching on Linux (recommended, falls back to polling)
  - `sudo apt install inotify-tools`
  - macOS alternative: `brew install fswatch`

## Plugin Structure

<details>
<summary>Click to expand</summary>

```
plugins/session-bridge/
  .claude-plugin/
    plugin.json                    # Plugin manifest (v0.2.0)
  commands/
    bridge.md                      # /bridge command (all subcommands)
  hooks/
    hooks.json                     # UserPromptSubmit, PostToolUse, SessionEnd, PreCompact
  skills/
    bridge-awareness/
      SKILL.md                     # Teaches agent the bidirectional protocol
  scripts/
    project-create.sh              # Create project directory + project.json
    project-join.sh                # Register session within a project
    project-list.sh                # List all projects
    project-update-member.sh       # Update a session's role/specialty after joining
    conversation-create.sh         # Create a conversation file
    conversation-update.sh         # Update conversation status
    inbox-watcher.sh               # Background watcher + heartbeat
    register.sh                    # Legacy ad-hoc session registration
    send-message.sh                # Send message (v2 protocol)
    check-inbox.sh                 # Rate-limited inbox scanning
    bridge-listen.sh               # Block until message (inotifywait/fswatch/poll)
    bridge-receive.sh              # Block until specific response
    list-peers.sh                  # List sessions with roles/specialties
    connect-peer.sh                # Ping to establish connection (legacy)
    heartbeat.sh                   # Update session heartbeat
    cleanup.sh                     # Project-aware cleanup
    get-session-id.sh              # Find session ID from any directory
  test.sh                          # Run all tests
  tests/
    test-helpers.sh                # Shared assertions
    test-project-create.sh
    test-project-join.sh
    test-project-list.sh
    test-project-update-member.sh
    test-conversation.sh
    test-inbox-watcher.sh
    test-send-message.sh
    test-check-inbox.sh
    test-bridge-listen.sh
    test-bridge-receive.sh
    test-cleanup.sh
    test-list-peers.sh
    test-get-session-id.sh
    test-connect-peer.sh
    test-heartbeat.sh
    test-register.sh
    test-integration.sh            # Legacy end-to-end test
    test-bidirectional-integration.sh  # v2 orchestration test
```

</details>

## Running Tests

```bash
cd plugins/session-bridge
bash test.sh
# 287 passed, 0 failed
```

## Design Documents

- **Spec**: `docs/superpowers/specs/2026-03-19-bidirectional-bridge-design.md`
- **Plan**: `docs/superpowers/plans/2026-03-19-bidirectional-bridge.md`

## Contributing

Contributions welcome! Please open an issue or PR.

## Credits

Fork of [PatilShreyas/claude-code-session-bridge](https://github.com/PatilShreyas/claude-code-session-bridge) — the original peer-to-peer bridge concept. v2 adds bidirectional orchestration, project scoping, conversation protocol, and human-in-the-loop.

## License

[MIT](LICENSE)
