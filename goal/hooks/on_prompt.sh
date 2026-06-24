#!/bin/bash
set -euo pipefail

# on_prompt.sh — UserPromptSubmit hook (multi-session)
# Detects /goal command, creates goal state immediately.
#
# NOTE: xbot's UserPromptSubmit hook is fire-and-forget — the returned
# context field is NOT injected into the agent's prompt by the engine.
# Therefore we don't rely on context injection here. The goal is set to
# active immediately, and on_stop.sh handles prompting via WebSocket.
#
# When an active goal already exists, this hook does nothing extra —
# the agent's prompt goes through unchanged.

GOAL_HOME="${XBOT_HOME:-$HOME/.xbot}/goal"
PAYLOAD=$(cat)

XBOT_GOAL_HOME="$GOAL_HOME" \
XBOT_HOOK_PAYLOAD="$PAYLOAD" python3 << 'PYEOF'
import json, os, sys, re
from datetime import datetime, timezone

goal_home = os.environ["XBOT_GOAL_HOME"]
payload_str = os.environ["XBOT_HOOK_PAYLOAD"]

try:
    payload = json.loads(payload_str)
except:
    sys.exit(0)

session_id = payload.get("session_id", payload.get("chat_id", ""))
prompt = payload.get("prompt", "")
if not prompt:
    sys.exit(0)

# Check for /goal command — search across all lines (Feishu channel adds
# timestamp/user prefix before the actual message)
match = re.search(r'^/goal\s+(.+)', prompt.strip(), re.DOTALL | re.MULTILINE)
if match:
    objective = match.group(1).strip().strip('"').strip("'")
    if not objective:
        sys.exit(0)
    if not session_id:
        session_id = "default"
    session_dir = os.path.join(goal_home, "sessions", session_id)
    os.makedirs(session_dir, exist_ok=True)
    state_file = os.path.join(session_dir, "state.json")
    # Check existing active goal
    if os.path.exists(state_file):
        try:
            with open(state_file) as f: existing = json.load(f)
            if existing.get("status") == "active":
                # Goal already active — let the prompt through unchanged
                sys.exit(0)
        except: pass
    # Create new goal — status=active immediately
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    state = {"objective":objective,"status":"active","created_at":ts,"updated_at":ts,"iteration":0}
    with open(state_file, "w") as f: json.dump(state, f, indent=2, ensure_ascii=False)
    # Context injection doesn't work (engine discards UserPromptSubmit result),
    # but return it anyway for log visibility / future engine support
    print(json.dumps({"decision":"allow",
        "context":f"[Goal Plugin] Goal created: {objective}"}))
    sys.exit(0)

# No /goal command — do nothing (agent prompt goes through unchanged)
sys.exit(0)
PYEOF
