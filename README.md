<p align="center">
  <h1 align="center">session-bridge</h1>
  <p align="center">
    <strong>Peer-to-peer communication between Claude Code sessions</strong>
  </p>
  <p align="center">
    <a href="https://github.com/PatilShreyas/claude-code-session-bridge/actions/workflows/test.yml"><img src="https://github.com/PatilShreyas/claude-code-session-bridge/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  </p>
  <p align="center">
    <a href="#quick-start">Quick Start</a> &middot;
    <a href="#commands">Commands</a> &middot;
    <a href="#how-it-works">How It Works</a> &middot;
    <a href="#known-limitations">Limitations</a>
  </p>
</p>

---

When you're working across multiple repos — a shared library and its consumer app, a backend and frontend, microservices — each Claude Code session is isolated. **session-bridge** lets them talk to each other.

The Library agent answers questions about breaking changes. The Consumer agent asks what API replaced a deprecated function. The agent responds with its **full context** — no approximation, no extra API cost.

https://github.com/user-attachments/assets/ce893322-5749-42be-9973-e36e60b969a6

## Getting Started

### 1. Install

```bash
# Install jq (required)
brew install jq        # macOS
sudo apt install jq    # Linux

# Install the plugin
claude plugin marketplace add PatilShreyas/claude-code-session-bridge
claude plugin install session-bridge
```

<details>
<summary>Alternative: install via git clone</summary>

```bash
git clone https://github.com/PatilShreyas/claude-code-session-bridge.git ~/claude-code-session-bridge
```

Then start Claude with:
```bash
claude --plugin-dir ~/claude-code-session-bridge/plugins/session-bridge
```

Or add to `~/.claude/settings.json` for permanent loading:
```json
{
  "plugins": ["~/claude-code-session-bridge/plugins/session-bridge"]
}
```

</details>

### 2. Use it

Open two terminals — one for each project.

**Terminal 1** (the project that has the answers):
```
cd ~/projects/my-library && claude

> /bridge listen
Session ID: a1b2c3
Listening for peer messages... (Ctrl+C to stop)
```

**Terminal 2** (the project that needs answers):
```
cd ~/projects/my-app && claude

> /bridge connect a1b2c3
Connected to 'my-library'

> /bridge ask "What breaking changes did you make?"

Response from my-library:
  3 breaking changes in v2.0:
  1. login() → authenticate() — takes a Config object
  2. getUser() → getCurrentUser() — returns UserProfile
  3. Removed refreshToken() — now automatic
```

That's it. The Library agent responds with its **full session context** — it knows what it changed, why, and how. No extra API calls, no approximation.

## Commands

| Command | Description |
|---------|-------------|
| `/bridge start` | Register this session as a bridge peer |
| `/bridge connect <id>` | Connect to a peer session (auto-starts if needed) |
| `/bridge listen` | Enter listening mode — answer peer queries continuously |
| `/bridge ask <question>` | Send a question and wait for the response |
| `/bridge peers` | List all active sessions on this machine |
| `/bridge status` | Show session ID, connected peers, pending messages |
| `/bridge stop` | Disconnect, notify peers, clean up |
| `/fork [name]` | Fork this conversation into a new terminal tab with bridge auto-connect |

> **Tip:** You don't always need explicit commands. Just tell your agent "ask the library about X" in natural language and it will use the bridge automatically.

### Fork: parallel sessions from one conversation

`/fork` opens a new terminal tab with a forked copy of your current conversation. The forked session automatically connects to the parent via the bridge — both sessions can query each other immediately.

```
> /fork experiment
Forked into a new tab. The child session will auto-connect.
```

Use it to branch off an experiment without losing your main thread, or to parallelize work across two agents that share context. Works with Ghostty, iTerm2, and Terminal.app on macOS.

## How It Works

### Listen mode

The key innovation: `/bridge listen` puts the agent into a **continuous listening loop**. When a query arrives, the agent itself responds — with its full conversation context, not an approximation.

- **No background process** — the agent IS the responder
- **No `claude -p` calls** — zero extra API cost for responses
- **Full context** — the agent that made the changes answers questions about them
- **Includes real code** — responses contain actual file contents, not just descriptions

**Design principles:**
- No shared mutable state — each session owns its manifest
- Atomic file writes — temp file + `mv` prevents partial reads
- UUID message IDs — no collision risk
- Connection via ping handshake — peers never mutate each other's manifests

---

## When To Use It

### Great for

> **Multi-repo coordination** — Library + consumer app, SDK + client, shared module + services

You make breaking changes in the library. Instead of context-switching to the consumer app and manually explaining what changed, the consumer agent asks the library agent directly.

> **Backend + Frontend** — API changes that affect both sides

Backend session changes an endpoint's response format. Frontend session asks "what does the new response look like?" and gets the actual schema, not a stale doc.

> **Microservices** — Service A depends on Service B's contract

Service B renames a field in its API. Service A's agent asks Service B's agent what changed and updates the client code automatically.

> **Monorepo modules** — Independent modules that depend on each other

Module X changes an internal interface. Module Y's agent queries Module X about the new type signatures and applies the fix.

> **Migration assistance** — Upgrading dependencies with breaking changes

Your agent can ask the dependency's agent: "I'm on v1.3. What do I need to change for v2.0?" and get a step-by-step migration with actual code.

### Not designed for

- **Real-time chat** between humans (it's agent-to-agent communication)
- **Remote collaboration** across machines (local-only via filesystem)
- **CI/CD pipelines** (sessions are tied to interactive Claude Code)
- **Persistent messaging** (messages don't survive session cleanup)

## Example Scenarios

### Scenario 1: Dependency upgrade with breaking changes

```
Consumer: "Update our app to use auth-sdk v2.0"
  Agent detects version bump → proactively queries library peer
  Agent: "Asking auth-sdk about breaking changes..."
  Library responds with changes + migration steps
  Agent applies all changes automatically
  Agent: "Done. Updated 4 files, ran tests, all passing."
```

### Scenario 2: Back-and-forth clarification

```
Consumer: /bridge ask "How should I handle the new error types?"
  Library: "What error types are you currently catching? Send me your error handler."
  Consumer: (reads its own code, sends the relevant function)
  Library: "Replace AuthError with AuthException. Here's the new hierarchy: ..."
  Consumer: applies the fix
```

### Scenario 3: Natural language (no /bridge command needed)

```
Consumer user: "Ask the backend team what the new API response format looks like
               for the /users endpoint and update our models accordingly"
  Agent queries the backend peer
  Agent gets the response with actual schema
  Agent updates the model classes
  Agent: "Updated UserResponse model to match new schema."
```

### Scenario 4: Multiple peers

```
> /bridge peers
SESSION    PROJECT              STATUS   PATH
-------    -------              ------   ----
a1b2c3     auth-sdk             active   ~/projects/auth-sdk
d4e5f6     payments-service     active   ~/projects/payments
g7h8i9     my-app               active   ~/projects/my-app  (you)

> /bridge ask "What config format does the payments service expect?"
  Routes to payments-service peer automatically based on question context
```

## Dos and Don'ts

### Do

- **Use `/bridge listen` on the session that has the knowledge** — the one that made the changes, built the feature, or owns the API. It responds with full context.
- **Use natural language** — "ask the backend what changed" works just as well as `/bridge ask`.
- **Let agents share real code** — responses include actual file contents, type definitions, and function signatures. Ask for them specifically if the agent gives you prose instead.
- **Use for version upgrades** — "update to v2.0" will proactively query the peer about breaking changes before even trying to build.
- **Use back-and-forth** — if the listener needs more info, it'll ask a follow-up question. The consumer answers and re-queries automatically.
- **Clean up** — run `/bridge stop` when done, or stale sessions accumulate.

### Don't

- **Don't use it as a chat app** — it's designed for agent-to-agent coordination, not human conversation. The agents talk; you give them tasks.
- **Don't send secrets** — messages are plain JSON on the local filesystem. No encryption. Don't ask a peer to "send me the API keys."
- **Don't expect remote access** — both sessions must be on the same machine. It uses the local filesystem (`~/.claude/session-bridge/`), not a network protocol.
- **Don't run `/bridge listen` on both sides simultaneously** and expect them to talk — one side listens, the other asks. If both listen, neither asks.
- **Don't use it for large file transfers** — message content is passed as shell arguments. Share file paths or describe locations instead of pasting entire files into queries.
- **Don't leave sessions running forever** — stale sessions from killed terminals persist until manually cleaned up with `/bridge stop` or `/bridge peers` + cleanup.
- **Don't expect instant responses** — the listen script polls every 3 seconds, plus the agent needs time to formulate its answer. Round-trip is typically 5-15 seconds.

## Known Limitations

### Session is occupied while listening

When a session is in `/bridge listen` mode, it's dedicated to answering peer queries. The user can't use it for other work until they press Ctrl+C. This is by design — it's the trade-off for getting full-context responses at zero extra cost.

### Platform support

| Platform | Status |
|----------|--------|
| macOS | Tested |
| Linux | Should work (GNU `date` fallback) |
| Windows | Not supported yet |

### Other considerations

- **Polling interval** — `bridge-listen.sh` checks every 3 seconds. Responses are as fast as the agent can formulate them.
- **No encryption** — Messages are plain JSON, protected by Unix file permissions.
- **Session accumulation** — Crashed sessions may persist. Use `/bridge peers` to check, `/bridge stop` to clean up.
- **Single machine only** — Communication is via local filesystem. No network/remote support.

## Plugin Structure

<details>
<summary>Click to expand</summary>

```
plugins/session-bridge/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   └── bridge.md                # /bridge command (all subcommands)
├── hooks/
│   └── hooks.json               # SessionEnd cleanup, PreCompact preservation
├── skills/
│   ├── bridge-awareness/
│   │   └── SKILL.md             # Teaches agent the bridge protocol
│   └── fork/
│       └── SKILL.md             # /fork — parallel sessions from one conversation
├── scripts/
│   ├── register.sh              # Create session directory and manifest
│   ├── send-message.sh          # Send message to peer's inbox
│   ├── check-inbox.sh           # Scan inboxes for pending messages
│   ├── list-peers.sh            # List active sessions
│   ├── connect-peer.sh          # Ping to establish connection
│   ├── heartbeat.sh             # Update session heartbeat
│   ├── cleanup.sh               # Remove session, notify peers
│   ├── bridge-listen.sh         # Block until message arrives
│   └── bridge-receive.sh        # Block until specific response arrives
├── test.sh                      # Run all tests
└── tests/
    ├── test-helpers.sh           # Shared assertions
    ├── test-register.sh
    ├── test-send-message.sh
    ├── test-check-inbox.sh
    ├── test-list-peers.sh
    ├── test-connect-peer.sh
    ├── test-cleanup.sh
    ├── test-heartbeat.sh
    ├── test-bridge-listen.sh
    ├── test-bridge-receive.sh
    └── test-integration.sh       # End-to-end two-session test
```

</details>

## Running Tests

```bash
cd plugins/session-bridge
bash test.sh
```

## Contributing

Contributions are welcome! Please open an issue or PR.

## License

[MIT](LICENSE)
