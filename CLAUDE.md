# Claude Code Session Bridge

Fork of `PatilShreyas/claude-code-session-bridge` — peer-to-peer communication between Claude Code sessions.

## Project Structure

```
plugins/session-bridge/
  .claude-plugin/plugin.json     # Plugin manifest (currently v0.1.1)
  commands/bridge.md             # /bridge command definition
  hooks/hooks.json               # UserPromptSubmit, SessionEnd, PreCompact hooks
  skills/bridge-awareness/SKILL.md  # Agent behavior skill
  scripts/                       # Core bash scripts (10 scripts, ~584 lines)
  tests/                         # Test suite (11 test files, ~1175 lines, 132 tests)
  test.sh                        # Test runner
```

## Development

### Running Tests

```bash
cd plugins/session-bridge && bash test.sh
```

All tests must pass before committing. Tests use isolated temp directories and clean up after themselves.

### Key Patterns

- Scripts use `set -euo pipefail` and require `jq`
- Atomic file writes: write to temp file + `mv` (prevents partial reads)
- Session IDs: 6-char alphanumeric from `/dev/urandom`
- Message IDs: `msg-` prefix + 12-char alphanumeric
- Date format: ISO 8601 UTC (`date -u +"%Y-%m-%dT%H:%M:%SZ"`)
- macOS + Linux compat: try BSD `date` first, GNU fallback
- Tests source `tests/test-helpers.sh` for assertions
- Each test file is standalone, uses `TEST_TMPDIR` with trap cleanup

### Bridge Directory

Runtime data lives at `~/.claude/session-bridge/` (not in the repo). Tests override with `BRIDGE_DIR` env var pointing to temp dirs.

### Git Remotes

- `origin`: `DiAhman/claude-code-session-bridge` (our fork)
- `upstream`: `PatilShreyas/claude-code-session-bridge` (original)

## Current Work: Bidirectional Bridge v2

We are implementing bidirectional, project-scoped, autonomous multi-session orchestration.

- **Spec**: `docs/superpowers/specs/2026-03-19-bidirectional-bridge-design.md`
- **Plan**: `docs/superpowers/plans/2026-03-19-bidirectional-bridge.md`
- **Protocol version**: 2.0

### v2 Key Concepts

- **Projects** group sessions (`~/.claude/session-bridge/projects/<name>/`)
- **Conversations** thread messages with state tracking (open/waiting/resolved)
- **Hook-driven async**: `UserPromptSubmit` + rate-limited `PostToolUse` replace blocking listen
- **Auto-join**: `SessionStart` hook reads `.claude/bridge-role` and rejoins project automatically
- **Standby mode**: agent runs `bridge-listen.sh` loop when idle (not at prompt)
- **Escalation chains**: conversations link via `parentConversation`
- **Human-in-the-loop**: `human-input-needed` messages with `proposedDefault` and `blocksWork`

### v2 Backward Compatibility

Legacy ad-hoc bridges (`/bridge start` + `/bridge connect`) still work via the flat `sessions/` directory. The project system is opt-in.

## Prerequisites

- `jq` (JSON processing)
- `inotify-tools` (provides `inotifywait` for zero-CPU filesystem watching on Linux)
  - Install: `sudo apt install inotify-tools`
  - macOS alternative: `fswatch`
  - Fallback: polling with `sleep` if neither available
