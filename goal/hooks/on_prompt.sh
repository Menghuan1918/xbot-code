#!/bin/bash
set -euo pipefail

# on_prompt.sh — UserPromptSubmit hook (multi-session)
# Detects /goal command, creates goal state.
# Also reminds agent when an active goal exists.

GOAL_HOME="${XBOT_HOME:-$HOME/.xbot}/goal"
SETUP_TEMPLATE="$(cd "$(dirname "$0")" && pwd)/../prompts/setup.md"
PAYLOAD=$(cat)

XBOT_GOAL_HOME="$GOAL_HOME" XBOT_GOAL_TEMPLATE="$SETUP_TEMPLATE" \
XBOT_HOOK_PAYLOAD="$PAYLOAD" python3 << 'PYEOF'
import json, os, sys, re
from datetime import datetime, timezone

goal_home = os.environ["XBOT_GOAL_HOME"]
template_path = os.environ["XBOT_GOAL_TEMPLATE"]
payload_str = os.environ["XBOT_HOOK_PAYLOAD"]

try:
    payload = json.loads(payload_str)
except:
    sys.exit(0)

session_id = payload.get("session_id", payload.get("chat_id", ""))
prompt = payload.get("prompt", "")
if not prompt:
    sys.exit(0)

# Check for /goal command
match = re.match(r'^/goal\s+(.+)', prompt.strip(), re.DOTALL)
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
                print(json.dumps({"decision":"allow",
                    "context":"[Goal Plugin] Active goal already exists. Run 'goal get' via Shell to continue."}))
                sys.exit(0)
        except: pass
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    state = {"objective":objective,"status":"active","created_at":ts,"updated_at":ts,"iteration":0}
    with open(state_file, "w") as f: json.dump(state, f, indent=2, ensure_ascii=False)
    print(json.dumps({"decision":"allow",
        "context":f"[Goal Plugin] New goal: {objective}\n\nRun 'goal get' via Shell to get the continuation prompt."}))
    sys.exit(0)

# No /goal command — check if active goal exists
if session_id:
    sf = os.path.join(goal_home, "sessions", session_id, "state.json")
    if os.path.exists(sf):
        try:
            with open(sf) as f: state = json.load(f)
            if state.get("status") == "active":
                print(json.dumps({"decision":"allow",
                    "context":f"[Goal Plugin] Active goal: {state.get('objective','')}\nRun 'goal get' via Shell to continue."}))
        except: pass
PYEOF
