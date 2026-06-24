# Goal Plugin for xbot

A persistent goal management plugin inspired by [Codex](https://github.com/openai/codex)'s `/goal` functionality.

## Features

- **`/goal <objective>`** — Start a goal that persists across turns
- **Automatic continuation via AgentStop hook** — When the agent finishes a turn with an active goal, the AgentStop hook returns `{"decision":"deny","context":"<continuation_prompt>"}`, forcing the agent to continue working
- **Multi-session support** — Each session has its own independent goal state, keyed by `$XBOT_SESSION_ID`
- **Completion audit** — The continuation prompt enforces strict evidence-based completion verification
- **Blocked detection** — After 3+ consecutive failed attempts at the same blocker, the goal can be marked blocked
- **Goal status widget** — Shows active goal status in the info bar (🎯)

## How It Works

### Architecture (AgentStop-based continuation)

```
User types: /goal <objective>
        │
        ▼
┌─────────────────────────┐
│ UserPromptSubmit Hook   │  on_prompt.sh detects /goal command
│ (on_prompt.sh)          │  Creates goal state for this session
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ Agent works on goal     │  Uses tools, writes code, runs tests...
│ (Shell: goal get)       │  Retrieves continuation prompt
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ Agent finishes turn     │  Agent decides to stop (no more tool calls)
│                         │
│ AgentStop Hook fires    │  on_stop.sh checks goal state for session
│ (on_stop.sh)            │  If active: outputs {"decision":"deny","context":"<prompt>"}
└───────────┬─────────────┘
            │
     ┌──────┴──────┐
     │             │
  deny           allow
     │             │
     ▼             ▼
┌──────────┐  ┌────────────┐
│ Engine   │  │ Agent      │
│ injects  │  │ stops      │
│ context  │  │ normally   │
│ as user  │  └────────────┘
│ message  │
│ &        │
│ continues│
│ loop     │
└──────────┘
     │
     ▼
  Agent runs again → works on goal → AgentStop fires again → repeat
  Until: goal update --status complete → AgentStop allows stop
```

### Engine Modification

The xbot engine (`agent/engine.go`) has been modified to use the AgentStop hook's decision:

1. **Before**: AgentStop was in a `defer`, decision discarded ("notification, non-blocking")
2. **After**: AgentStop is checked at each exit point. If `deny`:
   - The hook's `context` field is injected as a user message
   - The agent loop continues instead of stopping

Key changes in `engine.go`:
- `emitAgentStopHook()` closure replaces the deferred emit
- Checked at: `handleFinalResponse` exit, max iterations exit
- `restartLoop` label for goto-based loop restart on max iterations

### Multi-Session Support

Goal state is stored per-session:
```
~/.xbot/goal/sessions/<session_id>/state.json
```

Each session has its own independent goal. The session ID comes from:
1. `--session` parameter on the CLI
2. `$XBOT_SESSION_ID` environment variable (set by xbot hooks)
3. Falls back to `"default"`

### Files

| File | Description |
|------|-------------|
| `plugin.json` | Plugin manifest (script type, infoBar widget) |
| `goal.sh` | Goal CLI tool (get/create/update/clear/status) with `--session` support |
| `hooks/on_prompt.sh` | UserPromptSubmit hook — detects `/goal` command |
| `hooks/on_stop.sh` | AgentStop hook — returns deny+context if goal active |
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

**Important**: The xbot engine must be rebuilt for AgentStop deny support:
```bash
cd ~/Code/xbot && go build -o xbot .
```

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

## Differences from Codex

| Aspect | Codex | xbot Goal Plugin |
|--------|-------|-------------------|
| Tools | 3 tools (get_goal, create_goal, update_goal) | 1 CLI tool with subcommands |
| Budget | Token budget tracking | Removed |
| Continuation | Extension API (on_thread_idle) | AgentStop hook (deny + context injection) |
| State | Per-thread in state DB | Per-session JSON files |
| Multi-session | Built-in (thread IDs) | `--session` parameter + `$XBOT_SESSION_ID` |
| Prompt injection | Steering items (ContextualUserFragment) | AgentStop deny → context → user message |
