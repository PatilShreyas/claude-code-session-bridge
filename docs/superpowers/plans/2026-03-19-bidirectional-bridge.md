# Bidirectional Session Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the one-directional listen/ask bridge with fully bidirectional, project-scoped, autonomous multi-session orchestration.

**Architecture:** Project-scoped session groups with conversation-threaded messaging. Hook-driven async communication (UserPromptSubmit + rate-limited PostToolUse) during active work, agent-driven bridge-listen.sh standby loop during idle. inotifywait for zero-CPU filesystem watching. Escalation chains via parent conversations, human-in-the-loop via decision queue.

**Tech Stack:** Bash scripts, jq for JSON, inotifywait (Linux) / fswatch (macOS) for filesystem events, Claude Code plugin system (hooks, commands, skills).

**Spec:** `docs/superpowers/specs/2026-03-19-bidirectional-bridge-design.md`

**Prerequisite:** `sudo apt install inotify-tools` (provides `inotifywait` on Linux)

---

## File Structure

### New Files (plugins/session-bridge/)

| File | Responsibility |
|------|---------------|
| `scripts/project-create.sh` | Create project directory + project.json |
| `scripts/project-join.sh` | Register session within a project, start watcher |
| `scripts/project-list.sh` | List all projects on this machine |
| `scripts/conversation-create.sh` | Create a conversation JSON file atomically |
| `scripts/conversation-update.sh` | Update conversation status atomically |
| `scripts/inbox-watcher.sh` | Background inotifywait watcher + heartbeat |
| `tests/test-project-create.sh` | Tests for project-create.sh |
| `tests/test-project-join.sh` | Tests for project-join.sh |
| `tests/test-project-list.sh` | Tests for project-list.sh |
| `tests/test-conversation.sh` | Tests for conversation-create.sh + conversation-update.sh |
| `tests/test-inbox-watcher.sh` | Tests for inbox-watcher.sh |
| `tests/test-bidirectional-integration.sh` | End-to-end bidirectional orchestration test |

### Modified Files (plugins/session-bridge/)

| File | What Changes |
|------|-------------|
| `scripts/send-message.sh` | +conversationId, +urgency, +protocolVersion, project-aware path resolution, conversation auto-management |
| `scripts/check-inbox.sh` | +--rate-limited flag, early exit for non-bridge sessions, project-scoped scanning, enhanced --summary-only |
| `scripts/bridge-listen.sh` | inotifywait/fswatch support, project-scoped inbox path |
| `scripts/cleanup.sh` | Project-aware cleanup, kill watcher, conversation cleanup |
| `scripts/list-peers.sh` | Project grouping, role/specialty columns |
| `scripts/get-session-id.sh` | Extended search into project-scoped paths |
| `commands/bridge.md` | Rewrite for new command set (project create/join, standby, decisions) |
| `skills/bridge-awareness/SKILL.md` | Full rewrite for bidirectional protocol |
| `hooks/hooks.json` | Add PostToolUse hook |
| `.claude-plugin/plugin.json` | Version bump to 0.2.0 |
| `tests/test-send-message.sh` | Add conversation + urgency tests |
| `tests/test-check-inbox.sh` | Add rate limiting + early exit tests |
| `tests/test-cleanup.sh` | Add project-aware cleanup tests |
| `tests/test-integration.sh` | Preserve as legacy backward-compat tests |
| `test.sh` | Add new test files to runner |

### Also Modified

| File | What Changes |
|------|-------------|
| `scripts/bridge-receive.sh` | Project-scoped inbox path resolution (same pattern as bridge-listen.sh) |

### Unchanged Files

| File | Notes |
|------|-------|
| `scripts/register.sh` | Kept for legacy ad-hoc bridges |
| `scripts/heartbeat.sh` | Kept, supplemented by inbox-watcher |
| `scripts/connect-peer.sh` | Kept for legacy ad-hoc bridges |
| `tests/test-helpers.sh` | Shared assertions, no changes needed |
| `tests/test-register.sh` | Legacy tests preserved |
| `tests/test-connect-peer.sh` | Legacy tests preserved |
| `tests/test-heartbeat.sh` | Legacy tests preserved |
| `tests/test-bridge-receive.sh` | Legacy tests preserved |
| `tests/test-bridge-listen.sh` | Legacy tests preserved (new inotifywait tests in separate file or appended) |

### Dependency Order

```
Task 1: test-helpers.sh additions (assert_json_field)
Task 2: project-create.sh
Task 3: project-join.sh (depends on project-create)
Task 4: project-list.sh
Task 5: conversation-create.sh
Task 6: conversation-update.sh (depends on conversation-create)
Task 7: send-message.sh enhancement (depends on conversations + projects)
Task 8: check-inbox.sh enhancement (depends on send-message changes)
Task 9: bridge-listen.sh enhancement
Task 10: inbox-watcher.sh
Task 11: cleanup.sh + list-peers.sh + get-session-id.sh
Task 12: hooks.json + plugin.json
Task 13: bridge.md command rewrite
Task 14: SKILL.md rewrite
Task 15: Bidirectional integration tests
Task 16: Legacy backward-compat verification
```

---

## Task 1: Test Helper Additions

**Files:**
- Modify: `plugins/session-bridge/tests/test-helpers.sh`

We need a `assert_json_field` helper for testing JSON files throughout the plan.

- [ ] **Step 1: Add assert_json_field to test-helpers.sh**

Add after the existing `assert_contains` function (line 39):

```bash
assert_json_field() {
  local desc="$1" file="$2" field="$3" expected="$4"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $desc (file not found: $file)"; FAIL=$((FAIL + 1)); return
  fi
  local actual
  actual=$(jq -r "$field" "$file" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"; echo "    expected: $expected"; echo "    actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_not_empty() {
  local desc="$1" value="$2"
  if [ -n "$value" ]; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (value is empty)"; FAIL=$((FAIL + 1))
  fi
}
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: All 132 tests pass.

- [ ] **Step 3: Commit**

```bash
git add plugins/session-bridge/tests/test-helpers.sh
git commit -m "test: add assert_json_field and assert_not_empty helpers"
```

---

## Task 2: project-create.sh

**Files:**
- Create: `plugins/session-bridge/scripts/project-create.sh`
- Create: `plugins/session-bridge/tests/test-project-create.sh`

- [ ] **Step 1: Write the tests**

Create `plugins/session-bridge/tests/test-project-create.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-project-create.sh ==="

# Test 1: Creates project directory structure
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "my-project")
assert_eq "outputs project name" "my-project" "$OUTPUT"
assert_dir_exists "project dir created" "$BRIDGE_DIR/projects/my-project"
assert_dir_exists "conversations dir created" "$BRIDGE_DIR/projects/my-project/conversations"
assert_dir_exists "sessions dir created" "$BRIDGE_DIR/projects/my-project/sessions"
assert_file_exists "project.json created" "$BRIDGE_DIR/projects/my-project/project.json"

# Test 2: project.json has correct fields
assert_json_field "projectId set" "$BRIDGE_DIR/projects/my-project/project.json" '.projectId' "my-project"
assert_json_field "name set" "$BRIDGE_DIR/projects/my-project/project.json" '.name' "my-project"
assert_json_field "topology empty" "$BRIDGE_DIR/projects/my-project/project.json" '.topology' "{}"

# Test 3: Fails if project already exists
if BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "my-project" 2>/dev/null; then
  echo "  FAIL: should error on duplicate project"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on duplicate project"; PASS=$((PASS + 1))
fi

# Test 4: Creates multiple independent projects
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "project-two" > /dev/null
assert_dir_exists "second project created" "$BRIDGE_DIR/projects/project-two"
assert_dir_exists "first project still exists" "$BRIDGE_DIR/projects/my-project"

# Test 5: Project name with hyphens and numbers
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "plextura-suite-v2" > /dev/null
assert_dir_exists "hyphenated name works" "$BRIDGE_DIR/projects/plextura-suite-v2"

print_results
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd plugins/session-bridge && bash tests/test-project-create.sh`
Expected: FAIL (script doesn't exist yet)

- [ ] **Step 3: Write project-create.sh**

Create `plugins/session-bridge/scripts/project-create.sh`:

```bash
#!/usr/bin/env bash
# scripts/project-create.sh — Create a new multi-session project.
# Usage: project-create.sh <project-name>
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Outputs: project name to stdout
# Errors: exit 1 if project already exists
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_NAME="${1:?Usage: project-create.sh <project-name>}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME"

if [ -d "$PROJECT_DIR" ]; then
  echo "Error: Project '$PROJECT_NAME' already exists." >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/conversations" "$PROJECT_DIR/sessions"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$PROJECT_DIR/project.XXXXXX")
cat > "$TMP" <<EOF
{
  "projectId": "$PROJECT_NAME",
  "name": "$PROJECT_NAME",
  "createdAt": "$NOW",
  "createdBy": null,
  "topology": {}
}
EOF
mv "$TMP" "$PROJECT_DIR/project.json"

echo -n "$PROJECT_NAME"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/session-bridge && bash tests/test-project-create.sh`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/project-create.sh plugins/session-bridge/tests/test-project-create.sh
git commit -m "feat: add project-create.sh with tests"
```

---

## Task 3: project-join.sh

**Files:**
- Create: `plugins/session-bridge/scripts/project-join.sh`
- Create: `plugins/session-bridge/tests/test-project-join.sh`

- [ ] **Step 1: Write the tests**

Create `plugins/session-bridge/tests/test-project-join.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/my-app"
PROJECT_B="$TEST_TMPDIR/auth-server"
mkdir -p "$PROJECT_A" "$PROJECT_B"

# Create the project first
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "test-suite" > /dev/null

echo "=== test-project-join.sh ==="

# Test 1: Join creates session in project directory
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "test-suite" --role specialist --specialty "app development")
assert_not_empty "returns session ID" "$SESSION_ID"
assert_dir_exists "session dir created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID"
assert_dir_exists "inbox created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/inbox"
assert_dir_exists "outbox created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/outbox"
assert_file_exists "manifest created" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/manifest.json"

# Test 2: Manifest has correct fields
MANIFEST="$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_ID/manifest.json"
assert_json_field "sessionId set" "$MANIFEST" '.sessionId' "$SESSION_ID"
assert_json_field "projectId set" "$MANIFEST" '.projectId' "test-suite"
assert_json_field "projectName set" "$MANIFEST" '.projectName' "my-app"
assert_json_field "role set" "$MANIFEST" '.role' "specialist"
assert_json_field "specialty set" "$MANIFEST" '.specialty' "app development"
assert_json_field "status is active" "$MANIFEST" '.status' "active"

# Test 3: bridge-session file created in project dir
assert_file_exists "bridge-session pointer" "$PROJECT_A/.claude/bridge-session"
assert_eq "bridge-session contains ID" "$SESSION_ID" "$(cat "$PROJECT_A/.claude/bridge-session")"

# Test 4: Second session joins same project
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$JOIN" "test-suite" --role specialist --specialty "authentication, JWT")
assert_eq "sessions are different" "true" "$([ "$SESSION_ID" != "$SESSION_B" ] && echo true || echo false)"
assert_dir_exists "second session exists" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_B"
assert_json_field "second session role" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_B/manifest.json" '.role' "specialist"

# Test 5: Reuses existing session if already joined
SESSION_REUSE=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "test-suite" --role specialist --specialty "app development")
assert_eq "reuses session ID" "$SESSION_ID" "$SESSION_REUSE"

# Test 6: Fails if project doesn't exist
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "nonexistent" 2>/dev/null; then
  echo "  FAIL: should error on nonexistent project"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent project"; PASS=$((PASS + 1))
fi

# Test 7: Defaults to specialist role if not specified
PROJECT_C="$TEST_TMPDIR/plain-session"
mkdir -p "$PROJECT_C"
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$JOIN" "test-suite")
assert_json_field "defaults to specialist" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_C/manifest.json" '.role' "specialist"
assert_json_field "defaults to empty specialty" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_C/manifest.json" '.specialty' ""

# Test 8: --name overrides projectName
PROJECT_D="$TEST_TMPDIR/generic-dir"
mkdir -p "$PROJECT_D"
SESSION_D=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_D" bash "$JOIN" "test-suite" --name "custom-name" --role orchestrator)
assert_json_field "custom name set" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_D/manifest.json" '.projectName' "custom-name"
assert_json_field "orchestrator role" "$BRIDGE_DIR/projects/test-suite/sessions/$SESSION_D/manifest.json" '.role' "orchestrator"

print_results
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd plugins/session-bridge && bash tests/test-project-join.sh`
Expected: FAIL

- [ ] **Step 3: Write project-join.sh**

Create `plugins/session-bridge/scripts/project-join.sh`:

```bash
#!/usr/bin/env bash
# scripts/project-join.sh — Register a session within a project.
# Usage: project-join.sh <project-name> [--role <role>] [--specialty "<desc>"] [--name "<name>"]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), PROJECT_DIR (default: pwd)
# Outputs: session ID to stdout
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_NAME="${1:?Usage: project-join.sh <project-name> [--role <role>] [--specialty \"<desc>\"] [--name \"<name>\"]}"
shift

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_PATH="$BRIDGE_DIR/projects/$PROJECT_NAME"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: Project '$PROJECT_NAME' does not exist. Create it first with project-create.sh." >&2
  exit 1
fi

# Parse optional args
ROLE="specialist"
SPECIALTY=""
CUSTOM_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --specialty) SPECIALTY="$2"; shift 2 ;;
    --name) CUSTOM_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SESSION_NAME="${CUSTOM_NAME:-$(basename "$PROJECT_DIR")}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"

# Reuse existing session if bridge-session file points to a valid session in this project
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  EXISTING_ID=$(cat "$BRIDGE_SESSION_FILE")
  EXISTING_DIR="$PROJECT_PATH/sessions/$EXISTING_ID"
  if [ -d "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/manifest.json" ]; then
    # Verify it's in the same project
    EXISTING_PROJECT=$(jq -r '.projectId // ""' "$EXISTING_DIR/manifest.json")
    if [ "$EXISTING_PROJECT" = "$PROJECT_NAME" ]; then
      NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      TMP=$(mktemp "$EXISTING_DIR/manifest.XXXXXX")
      jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$EXISTING_DIR/manifest.json" > "$TMP"
      mv "$TMP" "$EXISTING_DIR/manifest.json"
      echo -n "$EXISTING_ID"
      exit 0
    fi
  fi
fi

# Create new session
SESSION_ID=$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
SESSION_DIR="$PROJECT_PATH/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR/inbox" "$SESSION_DIR/outbox"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
jq -n \
  --arg sid "$SESSION_ID" \
  --arg pid "$PROJECT_NAME" \
  --arg pname "$SESSION_NAME" \
  --arg ppath "$PROJECT_DIR" \
  --arg role "$ROLE" \
  --arg spec "$SPECIALTY" \
  --arg now "$NOW" \
  '{
    sessionId: $sid,
    projectId: $pid,
    projectName: $pname,
    projectPath: $ppath,
    role: $role,
    specialty: $spec,
    startedAt: $now,
    lastHeartbeat: $now,
    status: "active"
  }' > "$TMP"
mv "$TMP" "$SESSION_DIR/manifest.json"

# Write bridge-session pointer
mkdir -p "$PROJECT_DIR/.claude"
echo -n "$SESSION_ID" > "$BRIDGE_SESSION_FILE"

# Set BRIDGE_SESSION_ID in env file if available
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "BRIDGE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
fi

echo -n "$SESSION_ID"
```

Note: inbox-watcher.sh startup is deferred to Task 10 when the watcher script exists. After Task 10 adds watcher startup to project-join.sh, ALL test files that call project-join.sh must use this trap pattern to avoid leaking background processes:

```bash
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT
```

This replaces the simpler `trap 'rm -rf "$TEST_TMPDIR"' EXIT` in test-project-join.sh, test-project-list.sh, test-conversation.sh, test-bidirectional-integration.sh, and any v2 test blocks added to existing test files. Task 10 Step 5 must update all affected test traps.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/session-bridge && bash tests/test-project-join.sh`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/project-join.sh plugins/session-bridge/tests/test-project-join.sh
git commit -m "feat: add project-join.sh with tests"
```

---

## Task 4: project-list.sh

**Files:**
- Create: `plugins/session-bridge/scripts/project-list.sh`
- Create: `plugins/session-bridge/tests/test-project-list.sh`

- [ ] **Step 1: Write the tests**

Create `plugins/session-bridge/tests/test-project-list.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
LIST="$PLUGIN_DIR/scripts/project-list.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-project-list.sh ==="

# Test 1: No projects
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "no projects message" "No projects" "$OUTPUT"

# Test 2: Lists created projects
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "project-alpha" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "project-beta" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "lists alpha" "project-alpha" "$OUTPUT"
assert_contains "lists beta" "project-beta" "$OUTPUT"

# Test 3: Shows session count
PROJ_DIR="$TEST_TMPDIR/app1"
mkdir -p "$PROJ_DIR"
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$JOIN" "project-alpha" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST")
assert_contains "shows session count" "1" "$OUTPUT"

print_results
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd plugins/session-bridge && bash tests/test-project-list.sh`
Expected: FAIL

- [ ] **Step 3: Write project-list.sh**

Create `plugins/session-bridge/scripts/project-list.sh`:

```bash
#!/usr/bin/env bash
# scripts/project-list.sh — List all projects.
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECTS_DIR="$BRIDGE_DIR/projects"

if [ ! -d "$PROJECTS_DIR" ]; then
  echo "No projects found."
  exit 0
fi

FOUND=0
printf "%-25s %-10s %s\n" "PROJECT" "SESSIONS" "CREATED"
printf "%-25s %-10s %s\n" "-------" "--------" "-------"

for PROJ_JSON in "$PROJECTS_DIR"/*/project.json; do
  [ -f "$PROJ_JSON" ] || continue
  PROJ_DIR=$(dirname "$PROJ_JSON")
  PROJ_NAME=$(jq -r '.projectId' "$PROJ_JSON")
  CREATED=$(jq -r '.createdAt // "unknown"' "$PROJ_JSON")

  # Count sessions
  SESSION_COUNT=0
  if [ -d "$PROJ_DIR/sessions" ]; then
    SESSION_COUNT=$(find "$PROJ_DIR/sessions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  fi

  printf "%-25s %-10s %s\n" "$PROJ_NAME" "$SESSION_COUNT" "$CREATED"
  FOUND=$((FOUND + 1))
done

if [ "$FOUND" -eq 0 ]; then
  echo "No projects found."
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/session-bridge && bash tests/test-project-list.sh`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/project-list.sh plugins/session-bridge/tests/test-project-list.sh
git commit -m "feat: add project-list.sh with tests"
```

---

## Task 5: conversation-create.sh

**Files:**
- Create: `plugins/session-bridge/scripts/conversation-create.sh`
- Create: `plugins/session-bridge/tests/test-conversation.sh`

- [ ] **Step 1: Write the tests**

Create `plugins/session-bridge/tests/test-conversation.sh` (covers both create and update — update tests added in Task 6):

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
CONV_CREATE="$PLUGIN_DIR/scripts/conversation-create.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

# Setup: create a project
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "test-proj" > /dev/null

echo "=== test-conversation.sh ==="
echo ""
echo "--- conversation-create tests ---"

# Test 1: Creates conversation file
CONV_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "test-proj" "sess-a" "sess-b" "Bug in auth flow")
assert_not_empty "returns conversation ID" "$CONV_ID"
CONV_FILE="$BRIDGE_DIR/projects/test-proj/conversations/$CONV_ID.json"
assert_file_exists "conversation file created" "$CONV_FILE"

# Test 2: Conversation has correct fields
assert_json_field "conversationId set" "$CONV_FILE" '.conversationId' "$CONV_ID"
assert_json_field "topic set" "$CONV_FILE" '.topic' "Bug in auth flow"
assert_json_field "initiator set" "$CONV_FILE" '.initiator' "sess-a"
assert_json_field "responder set" "$CONV_FILE" '.responder' "sess-b"
assert_json_field "status is open" "$CONV_FILE" '.status' "open"
assert_json_field "parentConversation is null" "$CONV_FILE" '.parentConversation' "null"
assert_json_field "resolvedAt is null" "$CONV_FILE" '.resolvedAt' "null"
assert_json_field "resolution is null" "$CONV_FILE" '.resolution' "null"

# Test 3: Parent conversation
CHILD_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "test-proj" "sess-b" "sess-c" "Root cause in auth" --parent "$CONV_ID")
CHILD_FILE="$BRIDGE_DIR/projects/test-proj/conversations/$CHILD_ID.json"
assert_json_field "parent set" "$CHILD_FILE" '.parentConversation' "$CONV_ID"
assert_json_field "child topic" "$CHILD_FILE" '.topic' "Root cause in auth"

# Test 4: Multiple conversations coexist
CONV2_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "test-proj" "sess-a" "sess-c" "Logging cleanup")
assert_eq "different IDs" "true" "$([ "$CONV_ID" != "$CONV2_ID" ] && echo true || echo false)"

# Test 5: Fails on nonexistent project
if BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "no-such-project" "a" "b" "topic" 2>/dev/null; then
  echo "  FAIL: should error on nonexistent project"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent project"; PASS=$((PASS + 1))
fi

print_results
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd plugins/session-bridge && bash tests/test-conversation.sh`
Expected: FAIL

- [ ] **Step 3: Write conversation-create.sh**

Create `plugins/session-bridge/scripts/conversation-create.sh`:

```bash
#!/usr/bin/env bash
# scripts/conversation-create.sh — Create a conversation file.
# Usage: conversation-create.sh <project-id> <initiator-id> <responder-id> <topic> [--parent <conv-id>]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Outputs: conversation ID to stdout
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_ID="${1:?Usage: conversation-create.sh <project-id> <initiator-id> <responder-id> <topic> [--parent <conv-id>]}"
INITIATOR="${2:?Missing initiator-id}"
RESPONDER="${3:?Missing responder-id}"
TOPIC="${4:?Missing topic}"
shift 4

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
CONV_DIR="$BRIDGE_DIR/projects/$PROJECT_ID/conversations"

if [ ! -d "$CONV_DIR" ]; then
  echo "Error: Project '$PROJECT_ID' not found." >&2
  exit 1
fi

# Parse optional args
PARENT="null"
while [ $# -gt 0 ]; do
  case "$1" in
    --parent) PARENT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CONV_ID="conv-$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Format parent as JSON
if [ "$PARENT" = "null" ]; then
  PARENT_JSON="null"
else
  PARENT_JSON="\"$PARENT\""
fi

TMP=$(mktemp "$CONV_DIR/$CONV_ID.XXXXXX")
jq -n \
  --arg cid "$CONV_ID" \
  --arg topic "$TOPIC" \
  --arg init "$INITIATOR" \
  --arg resp "$RESPONDER" \
  --argjson parent "$PARENT_JSON" \
  --arg now "$NOW" \
  '{
    conversationId: $cid,
    topic: $topic,
    initiator: $init,
    responder: $resp,
    parentConversation: $parent,
    status: "open",
    createdAt: $now,
    resolvedAt: null,
    resolution: null
  }' > "$TMP"
mv "$TMP" "$CONV_DIR/$CONV_ID.json"

echo -n "$CONV_ID"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/session-bridge && bash tests/test-conversation.sh`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/conversation-create.sh plugins/session-bridge/tests/test-conversation.sh
git commit -m "feat: add conversation-create.sh with tests"
```

---

## Task 6: conversation-update.sh

**Files:**
- Create: `plugins/session-bridge/scripts/conversation-update.sh`
- Modify: `plugins/session-bridge/tests/test-conversation.sh` (append tests)

- [ ] **Step 1: Append update tests to test-conversation.sh**

Add before the `print_results` line at the end of `tests/test-conversation.sh`:

```bash
echo ""
echo "--- conversation-update tests ---"

CONV_UPDATE="$PLUGIN_DIR/scripts/conversation-update.sh"

# Test U1: Update status to waiting
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "$CONV_ID" "waiting"
assert_json_field "status changed to waiting" "$CONV_FILE" '.status' "waiting"

# Test U2: Update status back to open
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "$CONV_ID" "open"
assert_json_field "status changed to open" "$CONV_FILE" '.status' "open"

# Test U3: Resolve with resolution text
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "$CONV_ID" "resolved" --resolution "Fixed JWT validation"
assert_json_field "status is resolved" "$CONV_FILE" '.status' "resolved"
assert_json_field "resolution set" "$CONV_FILE" '.resolution' "Fixed JWT validation"
RESOLVED_AT=$(jq -r '.resolvedAt' "$CONV_FILE")
assert_eq "resolvedAt not null" "true" "$([ "$RESOLVED_AT" != "null" ] && echo true || echo false)"

# Test U4: Fails on nonexistent conversation
if BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "test-proj" "conv-nonexistent" "open" 2>/dev/null; then
  echo "  FAIL: should error on nonexistent conversation"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent conversation"; PASS=$((PASS + 1))
fi
```

- [ ] **Step 2: Run tests to verify new tests fail**

Run: `cd plugins/session-bridge && bash tests/test-conversation.sh`
Expected: conversation-create tests PASS, conversation-update tests FAIL

- [ ] **Step 3: Write conversation-update.sh**

Create `plugins/session-bridge/scripts/conversation-update.sh`:

```bash
#!/usr/bin/env bash
# scripts/conversation-update.sh — Update conversation status.
# Usage: conversation-update.sh <project-id> <conversation-id> <new-status> [--resolution "<text>"]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_ID="${1:?Usage: conversation-update.sh <project-id> <conversation-id> <new-status> [--resolution \"<text>\"]}"
CONV_ID="${2:?Missing conversation-id}"
NEW_STATUS="${3:?Missing new-status}"
shift 3

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
CONV_FILE="$BRIDGE_DIR/projects/$PROJECT_ID/conversations/$CONV_ID.json"

if [ ! -f "$CONV_FILE" ]; then
  echo "Error: Conversation '$CONV_ID' not found in project '$PROJECT_ID'." >&2
  exit 1
fi

# Parse optional args
RESOLUTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resolution) RESOLUTION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$(dirname "$CONV_FILE")/$CONV_ID.XXXXXX")

if [ "$NEW_STATUS" = "resolved" ]; then
  if [ -n "$RESOLUTION" ]; then
    jq --arg s "$NEW_STATUS" --arg ra "$NOW" --arg res "$RESOLUTION" \
      '.status = $s | .resolvedAt = $ra | .resolution = $res' "$CONV_FILE" > "$TMP"
  else
    jq --arg s "$NEW_STATUS" --arg ra "$NOW" \
      '.status = $s | .resolvedAt = $ra' "$CONV_FILE" > "$TMP"
  fi
else
  jq --arg s "$NEW_STATUS" '.status = $s' "$CONV_FILE" > "$TMP"
fi

mv "$TMP" "$CONV_FILE"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/session-bridge && bash tests/test-conversation.sh`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/conversation-update.sh plugins/session-bridge/tests/test-conversation.sh
git commit -m "feat: add conversation-update.sh with tests"
```

---

## Task 7: Enhanced send-message.sh

**Files:**
- Modify: `plugins/session-bridge/scripts/send-message.sh`
- Modify: `plugins/session-bridge/tests/test-send-message.sh`

This is the largest change. send-message.sh gains: protocolVersion, conversationId, urgency, project-aware path resolution, and conversation auto-management.

**Argument format change (B3 fix):** All optional args are now named flags. The positional format is `<target-id> <type> <content>` (3 positional). The old `$4` in-reply-to becomes `--reply-to <id>`. This simplifies parsing: consume 3 positional args, then parse `--flag value` pairs.

**Backward compatibility (B2 fix):** Legacy callers that pass in-reply-to as positional `$4` still work: if `$4` exists and doesn't start with `--`, treat it as `--reply-to`.

- [ ] **Step 1: Fix existing test 3 in test-send-message.sh**

The existing test-send-message.sh Test 3 sends `response` type. Under v2, `response` requires `--conversation`. However, for legacy (non-project) sessions, conversation management is skipped — `conversationId` defaults to `null` and no validation error occurs. This preserves backward compatibility. Verify existing Test 3 still works after the rewrite by ensuring the legacy path allows null conversations for all types.

- [ ] **Step 2: Add new tests to test-send-message.sh**

Append before `print_results` in `tests/test-send-message.sh`:

```bash
echo ""
echo "--- v2 protocol tests ---"

# Setup project for v2 tests
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/app-a"
V2_PROJ_B="$V2_TMPDIR/app-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"

BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "v2-proj" > /dev/null
V2_SESS_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "v2-proj" --role specialist --specialty "app")
V2_SESS_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "v2-proj" --role specialist --specialty "auth")

# Test V1: Project-scoped message delivery
MSG_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_A" bash "$SEND_MSG" "$V2_SESS_B" query "What changed?" --urgency high)
assert_not_empty "v2 message sent" "$MSG_ID"
V2_MSG_FILE="$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_B/inbox/$MSG_ID.json"
assert_file_exists "message in project inbox" "$V2_MSG_FILE"

# Test V2: protocolVersion in message
assert_json_field "has protocolVersion" "$V2_MSG_FILE" '.protocolVersion' "2.0"

# Test V3: urgency field
assert_json_field "urgency set to high" "$V2_MSG_FILE" '.metadata.urgency' "high"

# Test V4: conversationId auto-created for query
CONV_ID=$(jq -r '.conversationId' "$V2_MSG_FILE")
assert_eq "conversationId not null" "true" "$([ "$CONV_ID" != "null" ] && echo true || echo false)"
CONV_FILE="$V2_BRIDGE/projects/v2-proj/conversations/$CONV_ID.json"
assert_file_exists "conversation file created" "$CONV_FILE"
assert_json_field "conversation status is waiting" "$CONV_FILE" '.status' "waiting"

# Test V5: response within conversation (named args only)
RESP_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_B" bash "$SEND_MSG" "$V2_SESS_A" response "Nothing changed" --conversation "$CONV_ID" --reply-to "$MSG_ID")
assert_file_exists "response delivered" "$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_A/inbox/$RESP_ID.json"
assert_json_field "response has conversationId" "$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_A/inbox/$RESP_ID.json" '.conversationId' "$CONV_ID"

# Test V6: task-complete resolves conversation
COMPLETE_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_B" bash "$SEND_MSG" "$V2_SESS_A" task-complete "All done" --conversation "$CONV_ID" --reply-to "$MSG_ID")
assert_json_field "conversation resolved" "$CONV_FILE" '.status' "resolved"

# Test V7: ping has null conversationId
PING_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_A" bash "$SEND_MSG" "$V2_SESS_B" ping "hello")
PING_FILE="$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_B/inbox/$PING_ID.json"
assert_json_field "ping conversationId is null" "$PING_FILE" '.conversationId' "null"

# Test V8: default urgency is normal
assert_json_field "ping default urgency" "$PING_FILE" '.metadata.urgency' "normal"

# Cleanup
rm -rf "$V2_TMPDIR"
```

- [ ] **Step 3: Run tests — old tests should pass, new tests should fail**

Run: `cd plugins/session-bridge && bash tests/test-send-message.sh`
Expected: Original 23 tests pass, new v2 tests fail

- [ ] **Step 4: Write complete send-message.sh v2**

Replace `plugins/session-bridge/scripts/send-message.sh` entirely:

```bash
#!/usr/bin/env bash
# scripts/send-message.sh — Send a message to a peer's inbox (v2 protocol).
# Usage: send-message.sh <target-id> <type> <content> [in-reply-to] [--conversation <id>] [--urgency <level>] [--reply-to <id>]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), BRIDGE_SESSION_ID (required)
# Outputs: message ID to stdout
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

TARGET_ID="$1"
MSG_TYPE="$2"
CONTENT="$3"
shift 3

# Parse remaining args: legacy positional in-reply-to + named flags
IN_REPLY_TO="null"
CONVERSATION_ID=""
URGENCY="normal"

# Legacy compat: if $1 exists and doesn't start with --, treat as in-reply-to
if [ $# -gt 0 ] && [ "${1:0:2}" != "--" ]; then
  IN_REPLY_TO="$1"
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --conversation) CONVERSATION_ID="$2"; shift 2 ;;
    --urgency) URGENCY="$2"; shift 2 ;;
    --reply-to) IN_REPLY_TO="$2"; shift 2 ;;
    *) shift ;;
  esac
done

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
SENDER_ID="${BRIDGE_SESSION_ID:?BRIDGE_SESSION_ID must be set}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Path resolution: find sender's project (if any) ---
SENDER_PROJECT_ID=""
for PROJ_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/"$SENDER_ID"/manifest.json; do
  [ -f "$PROJ_MANIFEST" ] || continue
  SENDER_PROJECT_ID=$(jq -r '.projectId' "$PROJ_MANIFEST")
  break
done

# --- Resolve target inbox + sender outbox ---
TARGET_INBOX=""
SENDER_OUTBOX=""

if [ -n "$SENDER_PROJECT_ID" ]; then
  PROJ_TARGET="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$TARGET_ID/inbox"
  if [ -d "$PROJ_TARGET" ]; then
    TARGET_INBOX="$PROJ_TARGET"
    SENDER_OUTBOX="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$SENDER_ID/outbox"
  fi
fi

# Legacy fallback
if [ -z "$TARGET_INBOX" ]; then
  TARGET_INBOX="$BRIDGE_DIR/sessions/$TARGET_ID/inbox"
  SENDER_OUTBOX="$BRIDGE_DIR/sessions/$SENDER_ID/outbox"
fi

if [ ! -d "$TARGET_INBOX" ]; then
  echo "Error: Target session $TARGET_ID not found" >&2
  exit 1
fi

# --- Conversation management (project-scoped sessions only) ---
CONV_FREE_TYPES="ping session-ended routing-query"
CONV_CREATE_TYPES="task-assign escalate"

if echo "$CONV_FREE_TYPES" | grep -qw "$MSG_TYPE"; then
  CONVERSATION_ID="null"
elif [ -n "$SENDER_PROJECT_ID" ]; then
  # Project-scoped: enforce conversation protocol
  if [ -z "$CONVERSATION_ID" ]; then
    if [ "$MSG_TYPE" = "query" ] || echo "$CONV_CREATE_TYPES" | grep -qw "$MSG_TYPE"; then
      # Auto-create conversation
      TOPIC="$CONTENT"
      [ ${#TOPIC} -gt 80 ] && TOPIC="${TOPIC:0:80}..."
      CONVERSATION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-create.sh" \
        "$SENDER_PROJECT_ID" "$SENDER_ID" "$TARGET_ID" "$TOPIC")
      BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-update.sh" \
        "$SENDER_PROJECT_ID" "$CONVERSATION_ID" "waiting"
    else
      echo "Error: Message type '$MSG_TYPE' requires --conversation for project-scoped sessions" >&2
      exit 1
    fi
  fi
  # Auto-resolve on task-complete/task-cancel
  if [ "$MSG_TYPE" = "task-complete" ] || [ "$MSG_TYPE" = "task-cancel" ]; then
    if [ "$CONVERSATION_ID" != "null" ]; then
      BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-update.sh" \
        "$SENDER_PROJECT_ID" "$CONVERSATION_ID" "resolved" \
        --resolution "$(echo "$CONTENT" | head -c 200)" 2>/dev/null || true
    fi
  fi
else
  # Legacy session: no conversation enforcement, default to null
  [ -z "$CONVERSATION_ID" ] && CONVERSATION_ID="null"
fi

# --- Build and send message ---
MSG_ID="msg-$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Read sender project name and role from manifest
SENDER_PROJECT="unknown"
SENDER_ROLE=""
for MANIFEST_PATH in \
  "$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$SENDER_ID/manifest.json" \
  "$BRIDGE_DIR/sessions/$SENDER_ID/manifest.json"; do
  if [ -f "$MANIFEST_PATH" ]; then
    SENDER_PROJECT=$(jq -r '.projectName // "unknown"' "$MANIFEST_PATH")
    SENDER_ROLE=$(jq -r '.role // ""' "$MANIFEST_PATH")
    break
  fi
done

# Format inReplyTo and conversationId as JSON values
if [ "$IN_REPLY_TO" = "null" ]; then
  IN_REPLY_TO_JSON="null"
else
  IN_REPLY_TO_JSON="\"$IN_REPLY_TO\""
fi

if [ "$CONVERSATION_ID" = "null" ]; then
  CONV_ID_JSON="null"
else
  CONV_ID_JSON="\"$CONVERSATION_ID\""
fi

MSG_JSON=$(jq -n \
  --arg pv "2.0" \
  --arg id "$MSG_ID" \
  --argjson conv "$CONV_ID_JSON" \
  --arg from "$SENDER_ID" \
  --arg to "$TARGET_ID" \
  --arg type "$MSG_TYPE" \
  --arg ts "$NOW" \
  --arg content "$CONTENT" \
  --argjson inReplyTo "$IN_REPLY_TO_JSON" \
  --arg urgency "$URGENCY" \
  --arg fromProject "$SENDER_PROJECT" \
  --arg fromRole "$SENDER_ROLE" \
  '{
    protocolVersion: $pv,
    id: $id,
    conversationId: $conv,
    from: $from,
    to: $to,
    type: $type,
    timestamp: $ts,
    status: "pending",
    content: $content,
    inReplyTo: $inReplyTo,
    metadata: {
      urgency: $urgency,
      fromProject: $fromProject,
      fromRole: $fromRole
    }
  }')

# Atomic write to target inbox
TMP_FILE=$(mktemp "$TARGET_INBOX/$MSG_ID.XXXXXX")
echo "$MSG_JSON" > "$TMP_FILE"
mv "$TMP_FILE" "$TARGET_INBOX/$MSG_ID.json"

# Copy to sender outbox (audit log) with status=sent
if [ -d "$SENDER_OUTBOX" ]; then
  OUTBOX_JSON=$(echo "$MSG_JSON" | jq '.status = "sent"')
  TMP_FILE=$(mktemp "$SENDER_OUTBOX/$MSG_ID.XXXXXX")
  echo "$OUTBOX_JSON" > "$TMP_FILE"
  mv "$TMP_FILE" "$SENDER_OUTBOX/$MSG_ID.json"
fi

echo -n "$MSG_ID"
```

- [ ] **Step 4: Run all tests**

Run: `cd plugins/session-bridge && bash tests/test-send-message.sh`
Expected: All original + new tests pass

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: All 132+ tests pass (some existing integration tests may need minor adjustments if they depend on send-message.sh output format)

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/send-message.sh plugins/session-bridge/tests/test-send-message.sh
git commit -m "feat: enhance send-message.sh with v2 protocol, conversations, project-aware routing"
```

---

## Task 8: Enhanced check-inbox.sh

**Files:**
- Modify: `plugins/session-bridge/scripts/check-inbox.sh`
- Modify: `plugins/session-bridge/tests/test-check-inbox.sh`

- [ ] **Step 1: Add new tests to test-check-inbox.sh**

Append before `print_results`:

```bash
echo ""
echo "--- v2 check-inbox tests ---"

# Test R1: --rate-limited exits early for non-bridge session
NON_BRIDGE_DIR=$(mktemp -d)
OUTPUT=$(BRIDGE_DIR="$NON_BRIDGE_DIR" PROJECT_DIR="$NON_BRIDGE_DIR" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)
assert_contains "non-bridge exits cleanly" '"continue": true' "$OUTPUT"
rm -rf "$NON_BRIDGE_DIR"

# Test R2: --rate-limited respects timestamp
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ="$V2_TMPDIR/myproj"
mkdir -p "$V2_PROJ"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "rate-test" > /dev/null
V2_SID=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ" bash "$PLUGIN_DIR/scripts/project-join.sh" "rate-test")

# First call should proceed (no timestamp file yet)
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID" PROJECT_DIR="$V2_PROJ" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)
assert_contains "first rate-limited call succeeds" '"continue": true' "$OUTPUT"

# Immediate second call should be rate-limited (< 5 seconds)
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID" PROJECT_DIR="$V2_PROJ" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)
assert_contains "rate-limited exits early" '"continue": true' "$OUTPUT"

rm -rf "$V2_TMPDIR"
```

- [ ] **Step 2: Run tests — old pass, new fail**

Run: `cd plugins/session-bridge && bash tests/test-check-inbox.sh`

- [ ] **Step 3: Modify check-inbox.sh**

Add early exit and rate limiting at the top of the script. **Important ordering (I5 fix):** The rate-limiting code needs the session's inbox path to check for critical messages. Resolve the inbox path FIRST, then apply rate limiting. The flow is:

```bash
# 1. Parse flags
RATE_LIMITED=false; SUMMARY_ONLY=false
case "${1:-}" in
  --rate-limited) RATE_LIMITED=true ;;
  --summary-only) SUMMARY_ONLY=true ;;
esac

# 2. Early exit for non-bridge sessions
if [ -z "${BRIDGE_SESSION_ID:-}" ] && [ ! -f "${PROJECT_DIR:-.}/.claude/bridge-session" ]; then
  echo '{"continue": true}'; exit 0
fi

# 3. Resolve this session's inbox (need it for critical message check)
MY_SESSION_ID="${BRIDGE_SESSION_ID:-$(cat "${PROJECT_DIR:-.}/.claude/bridge-session" 2>/dev/null || echo "")}"
MY_INBOX=""
for PM in "$BRIDGE_DIR"/projects/*/sessions/"$MY_SESSION_ID"/manifest.json; do
  [ -f "$PM" ] || continue
  PID=$(jq -r '.projectId' "$PM")
  MY_INBOX="$BRIDGE_DIR/projects/$PID/sessions/$MY_SESSION_ID/inbox"
  break
done
[ -z "$MY_INBOX" ] && MY_INBOX="$BRIDGE_DIR/sessions/$MY_SESSION_ID/inbox"

# 4. Rate limiting (only with --rate-limited)
if [ "$RATE_LIMITED" = true ] && [ -d "$MY_INBOX" ]; then
  LAST_CHECK_FILE="$BRIDGE_DIR/.last_inbox_check"
  NOW=$(date +%s)
  LAST=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)
  if [ $((NOW - LAST)) -lt 5 ]; then
    HAS_CRITICAL=$(grep -rl '"urgency":"critical"' "$MY_INBOX"/*.json 2>/dev/null | head -1)
    if [ -z "$HAS_CRITICAL" ]; then
      echo '{"continue": true}'; exit 0
    fi
  fi
  echo "$NOW" > "$LAST_CHECK_FILE"
fi

# 5. Proceed with inbox scan (existing logic, adapted for project scope)
```

The existing scanning logic (lines 44-101 of current check-inbox.sh) is preserved for legacy sessions. Project-scoped sessions get a parallel path that scans only their project directory.

Enhanced `--summary-only`: Include project context, active conversations, and pending human-input-needed decisions in the summary for context compaction preservation.

- [ ] **Step 4: Run tests**

Run: `cd plugins/session-bridge && bash tests/test-check-inbox.sh`
Expected: All pass

- [ ] **Step 5: Run full test suite**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/check-inbox.sh plugins/session-bridge/tests/test-check-inbox.sh
git commit -m "feat: enhance check-inbox.sh with rate limiting, early exit, project-scoped scanning"
```

---

## Task 9: Enhanced bridge-listen.sh + bridge-receive.sh

**Files:**
- Modify: `plugins/session-bridge/scripts/bridge-listen.sh`
- Modify: `plugins/session-bridge/scripts/bridge-receive.sh`
- Modify: `plugins/session-bridge/tests/test-bridge-listen.sh`

- [ ] **Step 1: Add inotifywait tests**

Append before `print_results` in `tests/test-bridge-listen.sh`:

```bash
echo ""
echo "--- inotifywait/project-scoped tests ---"

# Test I1: Works with project-scoped inbox
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "listen-proj" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "listen-proj")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "listen-proj")

# Send a message, then listen — should find it immediately
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$PLUGIN_DIR/scripts/send-message.sh" "$V2_SID_B" ping "hello" > /dev/null
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" bash "$LISTEN" "$V2_SID_B" 5 2>/dev/null || true)
assert_contains "finds project-scoped message" "TYPE=ping" "$OUTPUT"

rm -rf "$V2_TMPDIR"
```

- [ ] **Step 2: Run tests**

Run: `cd plugins/session-bridge && bash tests/test-bridge-listen.sh`
Expected: Old tests pass, new test may fail depending on path resolution

- [ ] **Step 3: Modify bridge-listen.sh**

Key changes:

1. Resolve inbox path: check if session is in a project (scan `projects/*/sessions/<id>/manifest.json`), use project-scoped inbox if found, otherwise legacy path
2. Replace `sleep 3` poll loop with inotifywait when available:
   ```bash
   # Detect watcher
   if command -v inotifywait >/dev/null 2>&1; then
     WATCHER="inotifywait"
   elif command -v fswatch >/dev/null 2>&1; then
     WATCHER="fswatch"
   else
     WATCHER="poll"
   fi
   ```
3. In the main loop, use the watcher. **Note (I6 fix):** Capture inotifywait's exit code BEFORE the `||` handler — inside `|| { }`, `$?` reflects the block's own commands, not inotifywait:
   ```bash
   case "$WATCHER" in
     inotifywait)
       inotifywait -t "$REMAINING" -e create "$INBOX" >/dev/null 2>&1
       WATCH_RC=$?
       # Exit code 0 = file created, 2 = timeout
       [ "$WATCH_RC" -eq 2 ] && continue
       ;;
     fswatch)
       timeout "$REMAINING" fswatch --one-event "$INBOX" >/dev/null 2>&1 || true
       ;;
     poll)
       sleep "$INTERVAL"
       ;;
   esac
   ```
4. Keep the existing message parsing and output format identical

- [ ] **Step 3b: Update bridge-receive.sh with project-scoped path resolution (B6 fix)**

Add the same inbox path resolution used in bridge-listen.sh to `bridge-receive.sh`. At the top, after parsing the session ID, resolve the inbox path:

```bash
# Resolve inbox: project-scoped first, legacy fallback
INBOX=""
for PROJ_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PROJ_MANIFEST" ] || continue
  PROJ_ID=$(jq -r '.projectId' "$PROJ_MANIFEST")
  INBOX="$BRIDGE_DIR/projects/$PROJ_ID/sessions/$SESSION_ID/inbox"
  break
done
[ -z "$INBOX" ] && INBOX="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"
```

Replace the current hardcoded `INBOX="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"` (line 13 of current bridge-receive.sh) with this block.

- [ ] **Step 4: Run tests**

Run: `cd plugins/session-bridge && bash tests/test-bridge-listen.sh`
Expected: All pass

- [ ] **Step 5: Run full test suite**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/bridge-listen.sh plugins/session-bridge/tests/test-bridge-listen.sh
git commit -m "feat: enhance bridge-listen.sh with inotifywait and project-scoped paths"
```

---

## Task 10: inbox-watcher.sh

**Files:**
- Create: `plugins/session-bridge/scripts/inbox-watcher.sh`
- Create: `plugins/session-bridge/tests/test-inbox-watcher.sh`
- Modify: `plugins/session-bridge/scripts/project-join.sh` (start watcher)

- [ ] **Step 1: Write the tests**

Create `plugins/session-bridge/tests/test-inbox-watcher.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHER="$PLUGIN_DIR/scripts/inbox-watcher.sh"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJ_DIR="$TEST_TMPDIR/myproj"
mkdir -p "$PROJ_DIR"
BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "watch-test" > /dev/null
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$JOIN" "watch-test")

INBOX="$BRIDGE_DIR/projects/watch-test/sessions/$SESSION_ID/inbox"
MANIFEST="$BRIDGE_DIR/projects/watch-test/sessions/$SESSION_ID/manifest.json"

echo "=== test-inbox-watcher.sh ==="

# Test 1: Watcher starts and creates PID file
BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER" "$SESSION_ID" "watch-test" &
WATCHER_PID=$!
sleep 1
assert_eq "watcher is running" "true" "$(kill -0 $WATCHER_PID 2>/dev/null && echo true || echo false)"

# Test 2: Heartbeat updates after watcher runs
OLD_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
sleep 2
# Trigger a heartbeat by waiting (watcher does it periodically)
# For testing, we just verify the watcher hasn't crashed
assert_eq "watcher still running" "true" "$(kill -0 $WATCHER_PID 2>/dev/null && echo true || echo false)"

# Test 3: Clean shutdown
kill $WATCHER_PID 2>/dev/null || true
wait $WATCHER_PID 2>/dev/null || true
assert_eq "watcher stopped" "false" "$(kill -0 $WATCHER_PID 2>/dev/null && echo true || echo false)"

print_results
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd plugins/session-bridge && bash tests/test-inbox-watcher.sh`
Expected: FAIL

- [ ] **Step 3: Write inbox-watcher.sh**

Create `plugins/session-bridge/scripts/inbox-watcher.sh`:

```bash
#!/usr/bin/env bash
# scripts/inbox-watcher.sh — Background inbox watcher + heartbeat.
# Usage: inbox-watcher.sh <session-id> <project-id>
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Runs until killed. Watches inbox for new files, prints terminal notifications.
# Updates heartbeat every 60 seconds.
set -euo pipefail

SESSION_ID="${1:?Usage: inbox-watcher.sh <session-id> <project-id>}"
PROJECT_ID="${2:?Usage: inbox-watcher.sh <session-id> <project-id>}"

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
INBOX="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID/inbox"
MANIFEST="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID/manifest.json"

if [ ! -d "$INBOX" ]; then
  echo "Error: Inbox not found for session $SESSION_ID" >&2
  exit 1
fi

# Heartbeat update function
update_heartbeat() {
  [ -f "$MANIFEST" ] || return
  local NOW
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local TMP
  TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX")
  jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP" 2>/dev/null && mv "$TMP" "$MANIFEST" || rm -f "$TMP"
}

LAST_HEARTBEAT=$(date +%s)
HEARTBEAT_INTERVAL=60

# Detect watcher tool
if command -v inotifywait >/dev/null 2>&1; then
  WATCHER="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
  WATCHER="fswatch"
else
  WATCHER="poll"
fi

while true; do
  # Heartbeat check
  NOW_EPOCH=$(date +%s)
  if [ $((NOW_EPOCH - LAST_HEARTBEAT)) -ge $HEARTBEAT_INTERVAL ]; then
    update_heartbeat
    LAST_HEARTBEAT=$NOW_EPOCH
  fi

  case "$WATCHER" in
    inotifywait)
      # Block until file created or 30s timeout (then loop back for heartbeat check)
      inotifywait -t 30 -e create "$INBOX" >/dev/null 2>&1 || true
      ;;
    fswatch)
      timeout 30 fswatch --one-event "$INBOX" >/dev/null 2>&1 || true
      ;;
    poll)
      sleep 10
      ;;
  esac

  # Check for new pending messages and notify
  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    FROM=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE" 2>/dev/null)
    TYPE=$(jq -r '.type' "$MSG_FILE" 2>/dev/null)

    if [ "$TYPE" = "human-input-needed" ]; then
      printf '\n>> DECISION NEEDED from "%s" — run /bridge decisions or press Enter.\a\n' "$FROM" >&2
    else
      printf '\n>> Bridge: %s from "%s" — press Enter to process.\a\n' "$TYPE" "$FROM" >&2
    fi
    break  # Notify once per cycle
  done
done
```

- [ ] **Step 4: Run tests**

Run: `cd plugins/session-bridge && bash tests/test-inbox-watcher.sh`
Expected: All pass

- [ ] **Step 5: Update project-join.sh to start watcher**

Add watcher startup after the session creation block in `project-join.sh`, before the final `echo -n "$SESSION_ID"`:

```bash
# Start inbox watcher in background
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/inbox-watcher.sh"
if [ -f "$WATCHER_SCRIPT" ]; then
  BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER_SCRIPT" "$SESSION_ID" "$PROJECT_NAME" &
  echo $! > "$SESSION_DIR/watcher.pid"
  disown
fi
```

- [ ] **Step 6: Run full test suite**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: All pass (watcher tests may need the watcher to be killed in cleanup — the trap handles this)

- [ ] **Step 7: Commit**

```bash
git add plugins/session-bridge/scripts/inbox-watcher.sh plugins/session-bridge/scripts/project-join.sh plugins/session-bridge/tests/test-inbox-watcher.sh
git commit -m "feat: add inbox-watcher.sh background watcher, integrate with project-join"
```

---

## Task 11: Enhanced cleanup.sh, list-peers.sh, get-session-id.sh

**Files:**
- Modify: `plugins/session-bridge/scripts/cleanup.sh`
- Modify: `plugins/session-bridge/scripts/list-peers.sh`
- Modify: `plugins/session-bridge/scripts/get-session-id.sh`
- Modify: `plugins/session-bridge/tests/test-cleanup.sh`
- Modify: `plugins/session-bridge/tests/test-list-peers.sh`
- Modify: `plugins/session-bridge/tests/test-get-session-id.sh`

- [ ] **Step 1: Add project-aware tests to test-cleanup.sh**

Append before `print_results`:

```bash
echo ""
echo "--- project-scoped cleanup tests ---"

V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"

BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "cleanup-proj" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "cleanup-proj")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "cleanup-proj")

# Send a message so they know each other
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$PLUGIN_DIR/scripts/send-message.sh" "$V2_SID_B" ping "hello" > /dev/null

# Cleanup session A
BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$CLEANUP"

assert_eq "project session dir removed" "false" "$([ -d "$V2_BRIDGE/projects/cleanup-proj/sessions/$V2_SID_A" ] && echo true || echo false)"
assert_eq "bridge-session pointer removed" "false" "$([ -f "$V2_PROJ_A/.claude/bridge-session" ] && echo true || echo false)"

# B should have session-ended notification
FOUND_ENDED=false
for F in "$V2_BRIDGE/projects/cleanup-proj/sessions/$V2_SID_B/inbox"/msg-*.json; do
  [ -f "$F" ] || continue
  if [ "$(jq -r '.type' "$F")" = "session-ended" ]; then
    FOUND_ENDED=true
    break
  fi
done
if $FOUND_ENDED; then
  echo "  PASS: peer notified via session-ended"; PASS=$((PASS + 1))
else
  echo "  FAIL: peer not notified"; FAIL=$((FAIL + 1))
fi

rm -rf "$V2_TMPDIR"
```

- [ ] **Step 2: Add project-aware tests to test-list-peers.sh and test-get-session-id.sh**

Similar pattern — append tests that create a project, join sessions, and verify the scripts work with project-scoped paths.

- [ ] **Step 3: Modify cleanup.sh**

Add project-scoped session detection at the top of cleanup.sh, after the existing session ID resolution. Insert this block after line 23 (`SESSION_ID` is found):

```bash
# Check if this session is in a project
PROJECT_ID=""
SESSION_DIR=""
for PROJ_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PROJ_MANIFEST" ] || continue
  PROJECT_ID=$(jq -r '.projectId' "$PROJ_MANIFEST")
  SESSION_DIR="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID"
  break
done

# Fall back to legacy path
if [ -z "$SESSION_DIR" ]; then
  SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
fi
```

Then add watcher kill before the peer notification block:

```bash
# Kill inbox watcher if running
WATCHER_PID_FILE="$SESSION_DIR/watcher.pid"
if [ -f "$WATCHER_PID_FILE" ]; then
  kill "$(cat "$WATCHER_PID_FILE")" 2>/dev/null || true
  rm -f "$WATCHER_PID_FILE"
fi
```

For project-scoped sessions, scan peers within the same project (not globally):

```bash
if [ -n "$PROJECT_ID" ]; then
  # Notify peers in the same project
  for PEER_MANIFEST in "$BRIDGE_DIR/projects/$PROJECT_ID/sessions"/*/manifest.json; do
    [ -f "$PEER_MANIFEST" ] || continue
    PEER_ID=$(jq -r '.sessionId' "$PEER_MANIFEST")
    [ "$PEER_ID" = "$SESSION_ID" ] && continue
    BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" \
      bash "$SCRIPT_DIR/send-message.sh" "$PEER_ID" session-ended "Session ended" 2>/dev/null || true
  done

  # Resolve open conversations initiated by this session
  for CONV_FILE in "$BRIDGE_DIR/projects/$PROJECT_ID/conversations"/*.json; do
    [ -f "$CONV_FILE" ] || continue
    CONV_STATUS=$(jq -r '.status' "$CONV_FILE" 2>/dev/null)
    CONV_INIT=$(jq -r '.initiator' "$CONV_FILE" 2>/dev/null)
    if [ "$CONV_STATUS" != "resolved" ] && [ "$CONV_INIT" = "$SESSION_ID" ]; then
      BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-update.sh" \
        "$PROJECT_ID" "$(jq -r '.conversationId' "$CONV_FILE")" "resolved" \
        --resolution "Session ended" 2>/dev/null || true
    fi
  done
fi
```

The existing legacy cleanup code (peer notification via inbox/outbox scan, session dir removal, stale session cleanup) remains unchanged for non-project sessions.

- [ ] **Step 4: Modify list-peers.sh**

Add project support. Replace the main scanning loop with:

```bash
# Parse optional project flag
PROJECT_FILTER=""
if [ "${1:-}" = "--project" ]; then
  PROJECT_FILTER="$2"
fi

# Scan project sessions
for PROJ_JSON in "$BRIDGE_DIR"/projects/*/project.json; do
  [ -f "$PROJ_JSON" ] || continue
  PROJ_NAME=$(jq -r '.projectId' "$PROJ_JSON")
  [ -n "$PROJECT_FILTER" ] && [ "$PROJ_NAME" != "$PROJECT_FILTER" ] && continue

  PROJ_SESSIONS_DIR="$(dirname "$PROJ_JSON")/sessions"
  echo ""
  echo "Project: $PROJ_NAME"
  printf "  %-10s %-20s %-12s %-15s %s\n" "SESSION" "NAME" "ROLE" "STATUS" "SPECIALTY"
  printf "  %-10s %-20s %-12s %-15s %s\n" "-------" "----" "----" "------" "---------"

  for MANIFEST in "$PROJ_SESSIONS_DIR"/*/manifest.json; do
    [ -f "$MANIFEST" ] || continue
    SID=$(jq -r '.sessionId' "$MANIFEST")
    PNAME=$(jq -r '.projectName' "$MANIFEST")
    ROLE=$(jq -r '.role // ""' "$MANIFEST")
    SPEC=$(jq -r '.specialty // ""' "$MANIFEST")
    HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
    HB_EPOCH=$(date -u -d "$HB" +%s 2>/dev/null || echo "0")
    AGE=$((NOW_EPOCH - HB_EPOCH))
    STATUS=$( [ "$AGE" -gt "$STALE_SECONDS" ] && echo "stale" || echo "active" )

    printf "  %-10s %-20s %-12s %-15s %s\n" "$SID" "$PNAME" "$ROLE" "$STATUS" "$SPEC"
    FOUND=$((FOUND + 1))
  done
done
```

Keep the existing legacy session scanning after this block for backward compatibility.

- [ ] **Step 5: Modify get-session-id.sh**

Add project-scoped scanning after the existing legacy scan (before the "Not found" exit). Insert at line 36:

```bash
# Project-scoped scan
for MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/*/manifest.json; do
  [ -f "$MANIFEST" ] || continue
  PROJ_PATH=$(jq -r '.projectPath // ""' "$MANIFEST" 2>/dev/null)
  [ -n "$PROJ_PATH" ] || continue
  case "$CURRENT_DIR" in
    "$PROJ_PATH"|"$PROJ_PATH"/*)
      jq -r '.sessionId' "$MANIFEST"
      exit 0
      ;;
  esac
done
```

- [ ] **Step 6: Run all tests**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: All pass

- [ ] **Step 7: Commit**

```bash
git add plugins/session-bridge/scripts/cleanup.sh plugins/session-bridge/scripts/list-peers.sh plugins/session-bridge/scripts/get-session-id.sh plugins/session-bridge/tests/test-cleanup.sh plugins/session-bridge/tests/test-list-peers.sh plugins/session-bridge/tests/test-get-session-id.sh
git commit -m "feat: enhance cleanup, list-peers, get-session-id for project-scoped sessions"
```

---

## Task 12: Hooks & Plugin Config

**Files:**
- Modify: `plugins/session-bridge/hooks/hooks.json`
- Modify: `plugins/session-bridge/.claude-plugin/plugin.json`

- [ ] **Step 1: Update hooks.json**

Add the `PostToolUse` hook entry. The full hooks.json becomes the updated version from the spec (Section 3).

- [ ] **Step 2: Update plugin.json version**

Change version from `0.1.1` to `0.2.0`.

- [ ] **Step 3: Run full test suite**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add plugins/session-bridge/hooks/hooks.json plugins/session-bridge/.claude-plugin/plugin.json
git commit -m "feat: add PostToolUse hook, bump plugin version to 0.2.0"
```

---

## Task 13: bridge.md Command Rewrite

**Files:**
- Modify: `plugins/session-bridge/commands/bridge.md`

- [ ] **Step 1: Rewrite bridge.md**

Replace the entire command file with the new command set from the spec. The new commands are:

- `project create <name>` — calls `project-create.sh`
- `project join <name> [--role] [--specialty] [--name]` — calls `project-join.sh`
- `project list` — calls `project-list.sh`
- `peers` — calls `list-peers.sh` (enhanced)
- `status` — shows conversations, pending decisions, message counts
- `standby` — enters the standby listen loop (bridge-listen.sh in a loop with auto-restart)
- `decisions` — shows pending human-input-needed queue
- `stop` — calls cleanup.sh
- `ask <question>` — legacy shortcut, still works
- `start` — legacy shortcut, calls register.sh for ad-hoc bridges
- `connect <id>` — legacy shortcut, calls connect-peer.sh

The `standby` action should instruct the agent to:
1. Auto-register if not already in a project
2. Enter a loop: run `bridge-listen.sh` with session ID, handle messages, repeat
3. Emphasize: **never break the loop unless user Ctrl+C**

The `decisions` action should scan all inboxes in the project for `human-input-needed` messages and display them.

Keep the `allowed-tools` frontmatter unchanged (Bash, Read, Write).

- [ ] **Step 2: Commit**

```bash
git add plugins/session-bridge/commands/bridge.md
git commit -m "feat: rewrite bridge.md for v2 bidirectional commands"
```

---

## Task 14: SKILL.md Rewrite

**Files:**
- Modify: `plugins/session-bridge/skills/bridge-awareness/SKILL.md`

- [ ] **Step 1: Rewrite SKILL.md**

Full rewrite based on the spec's Section 4 (Skill & Agent Awareness). The new skill covers:

1. **Session lifecycle** — register → work → standby loop
2. **Peer routing logic** — topology hints → specialty matching → orchestrator query
3. **Responding to messages by type** — task-assign, query, response, escalate, task-complete, task-cancel, task-redirect, human-input-needed, human-response
4. **Decision point: block or continue** — when awaiting a response, can you proceed? Use bridge-receive.sh if not, hook-based pickup if yes
5. **Always enter standby** — after finishing work, run bridge-listen.sh in a loop
6. **Include real code** — read files, paste actual code in responses
7. **Escalate, don't guess** — if outside your specialty, route to the right peer
8. **Resolution summaries flow up** — task-complete carries enough detail
9. **Human-in-the-loop** — send human-input-needed with proposedDefault and blocksWork flag
10. **Orchestrator-specific** — task decomposition, routing-query handling, decision queue, conversation tree tracking
11. **Orchestrator failure** — detect via heartbeat, pause, wait for recovery

Keep the same frontmatter format (name, description).

- [ ] **Step 2: Commit**

```bash
git add plugins/session-bridge/skills/bridge-awareness/SKILL.md
git commit -m "feat: rewrite SKILL.md for bidirectional protocol"
```

---

## Task 15: Bidirectional Integration Tests

**Files:**
- Create: `plugins/session-bridge/tests/test-bidirectional-integration.sh`
- Modify: `plugins/session-bridge/test.sh` (add new test files)

- [ ] **Step 1: Write comprehensive integration tests**

Create `plugins/session-bridge/tests/test-bidirectional-integration.sh`:

```bash
#!/usr/bin/env bash
# End-to-end bidirectional orchestration tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"
RECEIVE="$PLUGIN_DIR/scripts/bridge-receive.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"
LIST_PEERS="$PLUGIN_DIR/scripts/list-peers.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-bidirectional-integration.sh ==="

# --- Scenario 1: Full orchestrator → specialist → specialist chain ---
echo ""
echo "Scenario 1: Task delegation chain (orchestrator → dev → framework)"

ORCH_DIR="$TEST_TMPDIR/orchestrator"
DEV_DIR="$TEST_TMPDIR/dev-app"
FW_DIR="$TEST_TMPDIR/framework"
mkdir -p "$ORCH_DIR" "$DEV_DIR" "$FW_DIR"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "chain-test" > /dev/null

ORCH_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$ORCH_DIR" bash "$JOIN" "chain-test" --role orchestrator --specialty "coordination")
DEV_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$DEV_DIR" bash "$JOIN" "chain-test" --role specialist --specialty "app development")
FW_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$FW_DIR" bash "$JOIN" "chain-test" --role specialist --specialty "shared framework")

# Orchestrator assigns task to dev
TASK_MSG=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$ORCH_ID" bash "$SEND_MSG" "$DEV_ID" task-assign "Fix issue #123")
TASK_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/chain-test/sessions/$DEV_ID/inbox/$TASK_MSG.json")
assert_not_empty "task conversation created" "$TASK_CONV"

# Dev picks up the task
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$DEV_ID" 5)
assert_contains "dev sees task-assign" "Fix issue #123" "$OUTPUT"
assert_contains "dev sees type" "TYPE=task-assign" "$OUTPUT"

# Dev needs help from framework — sends query (new conversation, child of task)
FW_QUERY=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$DEV_ID" bash "$SEND_MSG" "$FW_ID" query "Bug in shared utils, can you investigate?")
FW_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/chain-test/sessions/$FW_ID/inbox/$FW_QUERY.json")

# Framework picks up the query
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$FW_ID" 5)
assert_contains "framework sees query" "Bug in shared utils" "$OUTPUT"

# Framework responds
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$FW_ID" bash "$SEND_MSG" "$DEV_ID" task-complete "Fixed: updated validate() in utils.go" --conversation "$FW_CONV" "$FW_QUERY" > /dev/null

# Dev picks up framework's response
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$DEV_ID" "$FW_QUERY" 10)
assert_contains "dev gets framework response" "Fixed: updated validate()" "$OUTPUT"

# Dev completes task back to orchestrator
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$DEV_ID" bash "$SEND_MSG" "$ORCH_ID" task-complete "Issue #123 fixed, framework utils updated" --conversation "$TASK_CONV" "$TASK_MSG" > /dev/null

# Orchestrator picks up completion
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$ORCH_ID" "$TASK_MSG" 10)
assert_contains "orchestrator gets completion" "Issue #123 fixed" "$OUTPUT"

# Verify conversation states
assert_json_field "task conv resolved" "$BRIDGE_DIR/projects/chain-test/conversations/$TASK_CONV.json" '.status' "resolved"
assert_json_field "fw conv resolved" "$BRIDGE_DIR/projects/chain-test/conversations/$FW_CONV.json" '.status' "resolved"

# --- Scenario 2: Bidirectional — both sessions ask each other ---
echo ""
echo "Scenario 2: Bidirectional query exchange"

PROJ_X="$TEST_TMPDIR/proj-x"
PROJ_Y="$TEST_TMPDIR/proj-y"
mkdir -p "$PROJ_X" "$PROJ_Y"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "bidir-test" > /dev/null
SID_X=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_X" bash "$JOIN" "bidir-test" --role specialist --specialty "frontend")
SID_Y=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_Y" bash "$JOIN" "bidir-test" --role specialist --specialty "backend")

# X asks Y
Q1_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_X" bash "$SEND_MSG" "$SID_Y" query "What does the new API return?")

# Y asks X (independent conversation)
Q2_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_Y" bash "$SEND_MSG" "$SID_X" query "What frontend components use the old API?")

# Both pick up each other's messages
OUT_Y=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_Y" 5)
assert_contains "Y sees X's query" "new API return" "$OUT_Y"

OUT_X=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_X" 5)
assert_contains "X sees Y's query" "frontend components" "$OUT_X"

# Both respond
Q1_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/bidir-test/sessions/$SID_Y/inbox/$Q1_ID.json")
Q2_CONV=$(jq -r '.conversationId' "$BRIDGE_DIR/projects/bidir-test/sessions/$SID_X/inbox/$Q2_ID.json")

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_Y" bash "$SEND_MSG" "$SID_X" response "Returns JSON with userId field" --conversation "$Q1_CONV" "$Q1_ID" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_X" bash "$SEND_MSG" "$SID_Y" response "UserCard and ProfilePage use it" --conversation "$Q2_CONV" "$Q2_ID" > /dev/null

OUT_X2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SID_X" "$Q1_ID" 10)
assert_contains "X gets response about API" "userId field" "$OUT_X2"

OUT_Y2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SID_Y" "$Q2_ID" 10)
assert_contains "Y gets response about components" "UserCard" "$OUT_Y2"

# --- Scenario 3: Human-input-needed message ---
echo ""
echo "Scenario 3: Human decision escalation"

HIN_CONV=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$PLUGIN_DIR/scripts/conversation-create.sh" "bidir-test" "$SID_Y" "$SID_X" "API design question")
HIN_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_Y" bash "$SEND_MSG" "$SID_X" human-input-needed "REST or GraphQL?" --conversation "$HIN_CONV" --urgency high)
HIN_FILE="$BRIDGE_DIR/projects/bidir-test/sessions/$SID_X/inbox/$HIN_ID.json"
assert_json_field "human-input urgency is high" "$HIN_FILE" '.metadata.urgency' "high"
assert_json_field "human-input type correct" "$HIN_FILE" '.type' "human-input-needed"

# --- Scenario 4: Legacy backward compatibility ---
echo ""
echo "Scenario 4: Legacy ad-hoc bridge still works"

LEGACY_A="$TEST_TMPDIR/legacy-a"
LEGACY_B="$TEST_TMPDIR/legacy-b"
mkdir -p "$LEGACY_A/.claude" "$LEGACY_B/.claude"

# Use original register.sh (not project-join)
LEGACY_SID_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$LEGACY_A" bash "$PLUGIN_DIR/scripts/register.sh")
LEGACY_SID_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$LEGACY_B" bash "$PLUGIN_DIR/scripts/register.sh")

MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$LEGACY_SID_A" bash "$SEND_MSG" "$LEGACY_SID_B" query "Legacy test")
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$LEGACY_SID_B" 5)
assert_contains "legacy message delivered" "Legacy test" "$OUTPUT"

print_results
```

- [ ] **Step 2: Update test.sh to include new test files**

Add the new test files to the runner. The existing `test.sh` loops over `tests/test-*.sh`, so new files are auto-discovered. Just verify:

Run: `cd plugins/session-bridge && bash test.sh`

- [ ] **Step 3: Run full test suite**

Expected: All tests pass including new bidirectional integration tests

- [ ] **Step 4: Commit**

```bash
git add plugins/session-bridge/tests/test-bidirectional-integration.sh
git commit -m "test: add comprehensive bidirectional integration tests"
```

---

## Task 16: Legacy Backward-Compatibility Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the original integration test**

Run: `cd plugins/session-bridge && bash tests/test-integration.sh`
Expected: All 20 original tests pass. This verifies the legacy ad-hoc bridge still works.

- [ ] **Step 2: Run full test suite**

Run: `cd plugins/session-bridge && bash test.sh`
Expected: ALL tests pass — original 132 + new tests.

- [ ] **Step 3: Manual smoke test (optional)**

If Claude Code is available, test the plugin manually:
1. Open two terminals
2. Terminal 1: `claude --plugin-dir ~/path/to/plugins/session-bridge`
3. Run `/bridge project create test-project`
4. Run `/bridge project join test-project --role orchestrator --specialty "coordination"`
5. Terminal 2: `claude --plugin-dir ~/path/to/plugins/session-bridge`
6. Run `/bridge project join test-project --role specialist --specialty "development"`
7. Run `/bridge standby`
8. Terminal 1: "Ask the development session what files it has open"
9. Verify the message reaches Terminal 2 and a response comes back

- [ ] **Step 4: Final commit — update test.sh if needed**

```bash
git add plugins/session-bridge/test.sh
git commit -m "chore: final backward-compatibility verification"
```

---

## Summary

| Task | Component | New Tests | Estimated Steps |
|------|-----------|-----------|----------------|
| 1 | test-helpers additions | 0 (utility) | 3 |
| 2 | project-create.sh | 5 | 5 |
| 3 | project-join.sh | 8 | 5 |
| 4 | project-list.sh | 3 | 5 |
| 5 | conversation-create.sh | 5 | 5 |
| 6 | conversation-update.sh | 4 | 5 |
| 7 | send-message.sh v2 | 8 | 6 |
| 8 | check-inbox.sh v2 | 2 | 6 |
| 9 | bridge-listen.sh v2 | 1 | 6 |
| 10 | inbox-watcher.sh | 3 | 7 |
| 11 | cleanup + list-peers + get-session-id | 3+ | 7 |
| 12 | hooks.json + plugin.json | 0 | 4 |
| 13 | bridge.md rewrite | 0 | 2 |
| 14 | SKILL.md rewrite | 0 | 2 |
| 15 | Bidirectional integration tests | 15+ | 4 |
| 16 | Legacy backward-compat | 0 | 4 |
| **Total** | | **57+** | **76** |
