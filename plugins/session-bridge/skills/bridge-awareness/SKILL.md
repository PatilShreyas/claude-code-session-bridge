---
name: bridge-awareness
description: Activates when a bridge session is active. Teaches the agent to communicate with connected peer sessions — listening for queries, responding with full context, and querying peers when needed.
---

# Bridge Awareness

You are connected to other Claude Code sessions via the Claude Bridge plugin. This skill defines how you communicate with peer agents.

**Getting your session ID:** Always register first to ensure you have your own bridge identity:
```bash
MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh")
```
This is idempotent — if `BRIDGE_SESSION_ID` env var is set (from a prior registration), it reuses that session. In listen mode, use `TO_ID` from the message output instead (even more reliable).

## Querying Peers

When the user asks you to communicate with a peer — whether via `/bridge ask`, or in natural language like "ask the library about...", "check with the peer", "what did the other session change", etc. — do this:

1. Get your session ID. If no bridge exists yet, auto-register first:
   ```bash
   MY_SESSION=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh")
   ```
   Then find connected peers:
   ```bash
   find ~/.claude/session-bridge/sessions/$MY_SESSION/inbox -name "*.json" -exec jq -r 'select(.type == "ping") | "\(.metadata.fromProject) (\(.from))"' {} \; 2>/dev/null | sort -u
   ```
   If no connected peers found but the user specified a peer by name or session ID, connect first:
   ```bash
   BRIDGE_SESSION_ID=$MY_SESSION bash "${CLAUDE_PLUGIN_ROOT}/scripts/connect-peer.sh" "<peer-id>"
   ```
2. If multiple peers, pick the most relevant one (by project name) or ask the user.
3. Send the query and capture the message ID:
   ```bash
   MSG_ID=$(BRIDGE_SESSION_ID=$MY_SESSION bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <peer-id> query "Your question here")
   ```
4. Tell the user: "Asking [peer-project-name]..."
5. Wait for the response (blocks up to 90 seconds):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-receive.sh" "$MY_SESSION" "$MSG_ID" 90
   ```
6. When the response arrives, read it carefully:
   - If it's a direct answer, **use it to continue the user's task** — update code, fix errors, apply migrations, etc.
   - If the peer is **asking a follow-up question** (they need more info from you), answer their question and send a new query with your answer + the original question. Then wait again with `bridge-receive.sh`.
7. Continue this back-and-forth until you get a final answer, then apply it.

## When to Query Peers Proactively

**Query immediately** (don't wait for errors) when:
- User says to **update/upgrade a dependency** managed by a connected peer
- User mentions **breaking changes**, **migration**, or **version bump** involving a peer's project
- User asks about a peer's project ("what does the library expose?", "what API should I use?")

**Query on errors** when you encounter:
- Compile/build errors on dependency code from a peer
- API mismatches — functions that don't exist or have wrong signatures
- Type errors on types defined in a peer's project
- Missing modules/packages from a peer's library

## Sharing File Contents

When responding to peer queries (in listen mode), **include actual code** — don't just describe it. Read the relevant source files in your project and paste the important parts. For example, if a peer asks about a type or function signature, read the file and include the actual definition — not just a description of it.

When querying a peer, if you need their actual file content, ask specifically — e.g., "Send me the contents of your config file" or "What does the function signature look like? Include the actual code."

## Listening Mode (`/bridge listen`)

When the user runs `/bridge listen`, you enter a **continuous listening loop**:

1. Run `bridge-listen.sh` (blocks until a message arrives)
2. Read and respond to the message using `TO_ID` from the output as your session ID
3. **Immediately** run `bridge-listen.sh` again
4. Repeat forever until user presses Ctrl+C

**You MUST keep the loop going.** After every response, immediately call `bridge-listen.sh` again. Never stop to ask the user what to do. Never break the loop.

## Responding to Queries

When a `query` message arrives (in listen mode or otherwise):

1. Read the question carefully.
2. Use your **full context** — you are the agent that has been working on this project. You know what changed, why, and how.
3. **Include actual code and file contents** in your response — not just descriptions. Read the relevant files and paste the important parts. This helps the peer agent make accurate changes.
4. If you can answer fully, send your response. Use `TO_ID` from the message as your session ID:
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> response "Your answer" <MESSAGE_ID>
   ```
5. If you **need more information** from the peer to answer properly, send your question as a response (with `inReplyTo` set so the peer's `bridge-receive.sh` picks it up):
   ```bash
   BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> response "I need more info: <your question>. Please clarify and ask again." <MESSAGE_ID>
   ```
   The peer will receive this via `bridge-receive.sh`, see it's a question, answer it, and send a new query. Your listen loop will pick up the follow-up.
6. Be concise but complete — include code snippets, API signatures, type definitions, migration steps.

## Responding to Pings

When a `ping` message arrives, acknowledge using `TO_ID`:
```bash
BRIDGE_SESSION_ID=<TO_ID> bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <FROM_ID> ping "connected"
```

## Important Rules

- **In listen mode, NEVER break the loop.** Respond, then immediately listen again.
- **Always use `send-message.sh`** — never write message JSON files directly.
- **In listen mode, use `TO_ID`** from the message output as BRIDGE_SESSION_ID.
- **Outside listen mode, use `register.sh`** to get your session ID (idempotent — reuses existing via env var).
- **Never use `$(cat .claude/bridge-session)` directly** — it's a relative path that breaks when the working directory changes.
- **Include real code in responses** — read actual files and paste relevant sections. Don't just describe changes in prose.
- **Route to the right peer** when connected to multiple. Use project names to decide relevance.
- **Act on responses.** When you get a response from a peer, don't just display it — use it to continue the user's task.
- **Handle follow-up questions.** If a peer's response asks you a question back, answer it and re-query. Continue the back-and-forth until you get a final answer.
- **Query proactively on upgrades.** Don't wait for compile errors — ask the peer immediately when the user mentions upgrading a dependency.
