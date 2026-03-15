---
name: bridge-awareness
description: Activates when a bridge session is active. Teaches the agent to communicate with connected peer sessions — responding to incoming queries, proactively querying peers on errors, and managing the bridge protocol.
---

# Bridge Awareness

You are connected to other Claude Code sessions via the Claude Bridge plugin. This skill defines how you communicate with peer agents.

## CRITICAL: Check Your Inbox FIRST

**Before every response**, if `.claude/bridge-session` exists, you MUST run this as your VERY FIRST action:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-inbox.sh"
```

Parse the JSON output. If it contains a `systemMessage` field, read the bridge messages and act on them BEFORE doing anything else. If the output is just `{"continue": true}`, proceed normally.

This is non-negotiable. Peer messages require timely responses. Always check your inbox first.

## Responding to Incoming Queries

When your inbox check reveals a message with type `query` from a peer:

1. Read the question carefully.
2. Formulate a helpful, concise answer. Include:
   - Direct answer to the question
   - Relevant code snippets, API signatures, or type definitions
   - Migration steps if the question is about breaking changes
3. Send your response using the Bash tool:
   ```bash
   BRIDGE_SESSION_ID=$(cat .claude/bridge-session) bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <peer-id> response "Your detailed answer here" <message-id>
   ```
   Replace `<peer-id>`, `<message-id>`, and the answer content. The `<message-id>` is from the incoming query's "Message ID" field.
4. Then continue with whatever the user asked you to do.

## Responding to Pings

When you see a `ping` message from a peer, send a ping back to acknowledge:
```bash
BRIDGE_SESSION_ID=$(cat .claude/bridge-session) bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <peer-id> ping "connected"
```

## Proactive Querying

When you encounter any of these situations and have connected peers:
- **Compile/build errors** on code from a dependency managed by a peer
- **API mismatches** — calling functions/methods that don't exist or have wrong signatures
- **Type errors** on types defined in a peer's project
- **Missing modules/packages** from a peer's library
- **Unexpected behavior changes** in functionality provided by a peer's project

Do this:
1. Identify which connected peer is most likely responsible (match by project name/context).
2. Send a query and **immediately wait for the response** in one flow:
   ```bash
   MSG_ID=$(BRIDGE_SESSION_ID=$(cat .claude/bridge-session) bash "${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh" <peer-id> query "Describe the specific error or question")
   ```
3. Inform the user: "Asking the [peer-project-name] session..."
4. **Block-wait for the response** (up to 60 seconds):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge-wait.sh" "$(cat .claude/bridge-session)" "$MSG_ID" 60
   ```
   This will output the response content when it arrives, or a timeout message.
5. When you receive the response, apply the information and continue working automatically.

## Responding to Context Dump Requests

If a peer sends a message with type `context-dump`:
1. Gather a summary of your current session's work: files modified, key changes, current state.
2. Send it back as a response.

## Responding to Session-Ended Notices

If you see a `session-ended` message from a peer, note this and inform the user:
"The [peer-project-name] session has disconnected."

## Important Rules

- **ALWAYS check inbox first.** Run `check-inbox.sh` as your very first action on every prompt if `.claude/bridge-session` exists. This is how you receive messages from peers.
- **Always use `bridge-wait.sh` after sending a query.** It blocks until the response arrives (up to 60s). Never tell the user to wait — get the response in the same turn.
- **Always use `send-message.sh`** — never write message JSON files directly.
- **Always use `$(cat .claude/bridge-session)`** for BRIDGE_SESSION_ID — never hardcode session IDs.
- **Be concise** in responses to peers. They are agents too — give them actionable information, not lengthy explanations.
- **Route to the right peer** when connected to multiple. Use project names to decide relevance.
- **Prioritize the user's request** over peer communication. Respond to peers, but the user's current task comes first.
- **Act on responses immediately.** When a peer responds to your query, apply the information and keep working — don't stop to ask the user for permission.
