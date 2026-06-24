#!/bin/bash
set -euo pipefail

# on_stop.sh — AgentStop hook for goal plugin (multi-session, forced continuation)
#
# When an active goal exists for this session:
#   1. Connects to xbot server via WebSocket
#   2. Calls send_inbound RPC to inject a continuation message
#   3. Server queues the message → triggers new agent turn after current completes
#
# When goal is complete/blocked or no goal: does nothing (agent stops normally)
#
# This provides FORCED continuation without modifying xbot source code.
# The agent cannot skip continuation — it's injected by the hook, not by the agent.

GOAL_HOME="${XBOT_HOME:-$HOME/.xbot}/goal"
GOAL_CMD="$(cd "$(dirname "$0")" && pwd)/../goal.sh"
CONTINUATION_TEMPLATE="$(cd "$(dirname "$0")" && pwd)/../prompts/continuation.md"

PAYLOAD=$(cat)

XBOT_GOAL_HOME="$GOAL_HOME" \
XBOT_GOAL_TEMPLATE="$CONTINUATION_TEMPLATE" \
XBOT_HOOK_PAYLOAD="$PAYLOAD" \
XBOT_HOME_ENV="${XBOT_HOME:-$HOME/.xbot}" \
python3 << 'PYEOF'
import json, os, sys, time
from datetime import datetime, timezone

goal_home = os.environ["XBOT_GOAL_HOME"]
template_path = os.environ["XBOT_GOAL_TEMPLATE"]
xbot_home = os.environ["XBOT_HOME_ENV"]
payload_str = os.environ["XBOT_HOOK_PAYLOAD"]

# Parse event payload
try:
    payload = json.loads(payload_str)
except:
    sys.exit(0)

session_id = payload.get("session_id", payload.get("chat_id", ""))
channel = payload.get("channel", "cli")
sender_id = payload.get("sender_id", "admin")
if not session_id:
    sys.exit(0)

# Check goal state for this session
state_file = os.path.join(goal_home, "sessions", session_id, "state.json")
if not os.path.exists(state_file):
    sys.exit(0)

try:
    with open(state_file) as f:
        state = json.load(f)
except:
    sys.exit(0)

status = state.get("status", "")
if status != "active":
    # Goal complete or blocked — allow normal stop
    sys.exit(0)

# Goal is active — increment iteration
state["iteration"] = state.get("iteration", 0) + 1
state["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(state_file, "w") as f:
    json.dump(state, f, indent=2, ensure_ascii=False)

# Max iteration guard — stop continuation after MAX_ITERATIONS
MAX_ITERATIONS = 10
if state["iteration"] >= MAX_ITERATIONS:
    state["status"] = "max_iterations"
    state["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    # Write fallback note so the agent/user can see why continuation stopped
    fallback_file = os.path.join(goal_home, "sessions", session_id, "pending_continuation.txt")
    with open(fallback_file, "w") as f:
        f.write(f"Goal reached max iterations ({MAX_ITERATIONS}). "
                f"Marking as max_iterations to stop continuation.\n"
                f"Objective: {state.get('objective', '')}\n")
    sys.exit(0)

# Read continuation prompt template
with open(template_path) as f:
    template = f.read()
continuation_prompt = template.replace("{{ objective }}", state.get("objective", ""))

# Read server config
config_path = os.path.join(xbot_home, "config.json")
try:
    with open(config_path) as f:
        config = json.load(f)
except:
    sys.exit(0)

server_url = config.get("cli", {}).get("server_url", "")
token = config.get("cli", {}).get("token", "")
if not server_url or not token:
    # No server configured — can't inject via WebSocket
    # Fallback: write continuation message to a file for debugging
    fallback_file = os.path.join(goal_home, "sessions", session_id, "pending_continuation.txt")
    with open(fallback_file, "w") as f:
        f.write(continuation_prompt)
    sys.exit(0)

# Build WebSocket URL with CLI auth
ws_url = f"{server_url}/ws?token={token}&client_type=cli"

# Connect and send send_inbound RPC
try:
    import websocket
    ws = websocket.create_connection(ws_url, timeout=5)
    
    rpc_id = f"goal-cont-{int(time.time())}"
    rpc = {
        "type": "rpc",
        "id": rpc_id,
        "method": "send_inbound",
        "params": {
            "channel": channel,
            "chat_id": session_id,
            "content": continuation_prompt,
            "sender_id": sender_id,
            "sender_name": "Goal Plugin",
            "chat_type": "private"
        }
    }
    ws.send(json.dumps(rpc))
    resp = json.loads(ws.recv())
    ws.close()
    
    if resp.get("error"):
        # RPC failed — write fallback file
        fallback_file = os.path.join(goal_home, "sessions", session_id, "pending_continuation.txt")
        with open(fallback_file, "w") as f:
            f.write(f"RPC Error: {resp['error']}\n\n{continuation_prompt}")
    else:
        # Success — continuation message injected
        pass
except Exception as e:
    # WebSocket failed — write fallback file
    fallback_file = os.path.join(goal_home, "sessions", session_id, "pending_continuation.txt")
    with open(fallback_file, "w") as f:
        f.write(f"WS Error: {e}\n\n{continuation_prompt}")
PYEOF
