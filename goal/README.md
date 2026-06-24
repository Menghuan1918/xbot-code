# Goal Plugin for xbot

A persistent goal management plugin inspired by [Codex](https://github.com/openai/codex)'s `/goal` functionality.

## Features

- **`/goal <objective>`** — Start a goal that persists across turns
- **Automatic continuation via WebSocket** — When the agent finishes a turn with an active goal, the AgentStop hook injects a continuation prompt through xbot's WebSocket `send_inbound` RPC, triggering a new agent turn
- **Multi-session support** — Each session has its own independent goal state
- **Max iteration guard** — Stops after 10 continuations to prevent infinite loops
- **Completion audit** — The continuation prompt enforces strict evidence-based completion verification
- **Blocked detection** — After 3+ consecutive failed attempts at the same blocker, the goal can be marked blocked
- **Goal status widget** — Shows active goal status in the info bar (🎯)

## How It Works

### Architecture (WebSocket-based continuation)

```
User types: /goal <objective>
        │
        ▼
┌─────────────────────────────┐
│ UserPromptSubmit Hook       │  on_prompt.sh detects /goal command
│ (on_prompt.sh)              │  Creates state.json for this session
└───────────┬─────────────────┘
            │
            ▼
┌─────────────────────────────┐
│ Agent works on goal         │  Uses tools, writes code, runs tests
└───────────┬─────────────────┘
            │
            ▼
┌─────────────────────────────┐
│ Agent finishes turn         │  Agent decides to stop (no more tool calls)
│                             │
│ AgentStop Hook fires        │  on_stop.sh checks goal state for session
│ (on_stop.sh)                │  If active → connects to xbot server via WebSocket
└───────────┬─────────────────┘
            │
            ▼
┌─────────────────────────────┐
│ WebSocket RPC injection     │  on_stop.sh calls send_inbound RPC
│                             │  Injects continuation prompt as a new
│                             │  user message → triggers new Run()
└───────────┬─────────────────┘
            │
            ▼
  Agent runs again → works → stops → hook fires → repeat
  Until: goal update --status complete / --status blocked
  Or:   max 10 iterations reached (auto-stops)
```

### Why WebSocket instead of AgentStop deny?

Currently xbot's `AgentStop` hook is **fire-and-forget** — the hook's decision is discarded and cannot prevent the agent from stopping (see [ai-pivot/xbot#173](https://github.com/ai-pivot/xbot/issues/173) for the feature request to fix this).

Since the hook cannot block, `on_stop.sh` works around this by connecting to the xbot server via WebSocket and calling the `send_inbound` RPC to inject a continuation prompt as a new user message. This triggers a new agent `Run()` without modifying xbot source code.

**No engine rebuild required.** The plugin works entirely through the hook system + WebSocket RPC.

### Multi-Session Support

Goal state is stored per-session:
```
~/.xbot/goal/sessions/<session_id>/state.json
```

Each session has its own independent goal. The session ID comes from:
1. `--session` parameter on the CLI
2. `$XBOT_SESSION_ID` environment variable (set by xbot hooks)
3. Falls back to `"default"`

### Max Iterations

The goal system automatically stops after **10 continuation iterations** if the goal is not marked complete or blocked. When the limit is reached, the goal status is set to `max_iterations` and no further continuation prompts are injected.

### Files

| File | Description |
|------|-------------|
| `plugin.json` | Plugin manifest (script type, infoBar widget) |
| `goal.sh` | Goal CLI tool (get/create/update/clear/status) with `--session` support |
| `hooks/on_prompt.sh` | UserPromptSubmit hook — detects `/goal` command |
| `hooks/on_stop.sh` | AgentStop hook — injects continuation via WebSocket if goal active |
| `widget.sh` | InfoBar widget showing goal status |
| `prompts/continuation.md` | Continuation prompt (adapted from Codex, no budget/token) |
| `prompts/setup.md` | Initial goal setup prompt |
| `hooks.json` | Hook configuration template |
| `install.sh` | Installation script |

## Installation

```bash
cd /root/Code/xbot-code/goal
bash install.sh
```

The installer copies plugin files to `~/.xbot/plugins/goal/` and merges hook configurations into `~/.xbot/hooks.json`. No xbot source modification or rebuild is needed.

## Usage

### Starting a Goal

In your xbot chat, type:
```
/goal Implement user authentication for the API
```

### Goal CLI Tool

```bash
# Get current goal status + continuation prompt
goal get [--session <id>]

# Create a new goal
goal create --objective "Fix all failing tests" [--session <id>]

# Mark goal as complete
goal update --status complete [--session <id>]

# Mark goal as blocked (after 3+ failed attempts)
goal update --status blocked [--session <id>]

# Clear goal state
goal clear [--session <id>]

# Get just the status (for scripts)
goal status [--session <id>]
```

### Stopping a Goal

The agent will call `goal update --status complete` when done. To manually stop:

```bash
~/.xbot/plugins/goal/goal.sh update --status complete
```

## Differences from Codex

| Aspect | Codex | xbot Goal Plugin |
|--------|-------|-------------------|
| Tools | 3 tools (get_goal, create_goal, update_goal) | 1 CLI tool with subcommands |
| Budget | Token budget tracking | Removed |
| Continuation | Extension API (on_thread_idle) | AgentStop hook → WebSocket send_inbound RPC |
| State | Per-thread in state DB | Per-session JSON files |
| Multi-session | Built-in (thread IDs) | `--session` parameter + `$XBOT_SESSION_ID` |
| Max iterations | N/A | 10 (auto-stops) |
| Prompt injection | Steering items (ContextualUserFragment) | WebSocket RPC → user message |
