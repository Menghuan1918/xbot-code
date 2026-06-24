#!/bin/bash
set -euo pipefail

# goal.sh — Goal management CLI for xbot (multi-session)
# State: ~/.xbot/goal/sessions/<session_id>/state.json
#
# Usage:
#   goal get [--session <id>]
#   goal create --objective "..." [--session <id>]
#   goal update --status complete|blocked [--session <id>]
#   goal clear [--session <id>]
#   goal status [--session <id>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_DIR="$SCRIPT_DIR/prompts"
GOAL_HOME="${XBOT_HOME:-$HOME/.xbot}/goal"

get_session_id() {
    local sid=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) sid="$2"; shift 2 ;;
            --session=*) sid="${1#--session=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -z "$sid" ] && sid="${XBOT_SESSION_ID:-default}"
    echo "$sid"
}

case "${1:-help}" in
    get) shift; sid=$(get_session_id "$@")
        sf="$GOAL_HOME/sessions/$sid/state.json"
        [ ! -f "$sf" ] && { echo '{"status":"no_goal"}'; exit 0; }
        XBOT_GOAL_STATE_FILE="$sf" XBOT_GOAL_TEMPLATE="$PROMPT_DIR/continuation.md" python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone
sf = os.environ["XBOT_GOAL_STATE_FILE"]; tpl = os.environ["XBOT_GOAL_TEMPLATE"]
with open(sf) as f: state = json.load(f)
if state.get("status") != "active":
    print(json.dumps(state, ensure_ascii=False)); sys.exit(0)
state["iteration"] = state.get("iteration", 0) + 1
state["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(sf, "w") as f: json.dump(state, f, indent=2, ensure_ascii=False)
with open(tpl) as f: template = f.read()
prompt = template.replace("{{ objective }}", state.get("objective", ""))
print(json.dumps({"status":"active","objective":state["objective"],
    "iteration":state["iteration"],"continuation_prompt":prompt}, indent=2, ensure_ascii=False))
PYEOF
        ;;
    create) shift; objective=""; sid=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --objective) objective="$2"; shift 2 ;;
                --objective=*) objective="${1#--objective=}"; shift ;;
                --session) sid="$2"; shift 2 ;;
                --session=*) sid="${1#--session=}"; shift ;;
                *) shift ;;
            esac
        done
        [ -z "$objective" ] && { echo '{"error":"Missing --objective"}'; exit 1; }
        [ -z "$sid" ] && sid="${XBOT_SESSION_ID:-default}"
        mkdir -p "$GOAL_HOME/sessions/$sid"
        sf="$GOAL_HOME/sessions/$sid/state.json"
        XBOT_GOAL_STATE_FILE="$sf" XBOT_GOAL_OBJECTIVE="$objective" \
        XBOT_GOAL_SESSION="$sid" XBOT_GOAL_TEMPLATE="$PROMPT_DIR/setup.md" python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone
sf = os.environ["XBOT_GOAL_STATE_FILE"]; objective = os.environ["XBOT_GOAL_OBJECTIVE"]
session = os.environ["XBOT_GOAL_SESSION"]; tpl = os.environ["XBOT_GOAL_TEMPLATE"]
if os.path.exists(sf):
    with open(sf) as f: existing = json.load(f)
    if existing.get("status") == "active":
        print(json.dumps({"error":"Active goal exists. Complete or clear first."})); sys.exit(0)
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
state = {"objective":objective,"status":"active","created_at":ts,"updated_at":ts,"iteration":0}
with open(sf, "w") as f: json.dump(state, f, indent=2, ensure_ascii=False)
with open(tpl) as f: template = f.read()
setup_prompt = template.replace("{{ objective }}", objective)
print(json.dumps({"status":"created","objective":objective,"session":session,
    "message":"Goal created. Start working now.","setup_prompt":setup_prompt}, indent=2, ensure_ascii=False))
PYEOF
        ;;
    update) shift; status=""; sid=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --status) status="$2"; shift 2 ;;
                --status=*) status="${1#--status=}"; shift ;;
                --session) sid="$2"; shift 2 ;;
                --session=*) sid="${1#--session=}"; shift ;;
                *) shift ;;
            esac
        done
        [ "$status" != "complete" ] && [ "$status" != "blocked" ] && { echo '{"error":"Use: --status complete|blocked"}'; exit 1; }
        [ -z "$sid" ] && sid="${XBOT_SESSION_ID:-default}"
        sf="$GOAL_HOME/sessions/$sid/state.json"
        [ ! -f "$sf" ] && { echo '{"error":"No goal to update."}'; exit 1; }
        XBOT_GOAL_STATE_FILE="$sf" XBOT_GOAL_STATUS="$status" python3 << 'PYEOF'
import json, os
from datetime import datetime, timezone
sf = os.environ["XBOT_GOAL_STATE_FILE"]; status = os.environ["XBOT_GOAL_STATUS"]
with open(sf) as f: state = json.load(f)
state["status"] = status
state["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(sf, "w") as f: json.dump(state, f, indent=2, ensure_ascii=False)
print(json.dumps({"status":status,"objective":state.get("objective",""),
    "message":f"Goal marked as {status}."}, indent=2, ensure_ascii=False))
PYEOF
        ;;
    clear) shift; sid=$(get_session_id "$@")
        sf="$GOAL_HOME/sessions/$sid/state.json"
        [ -f "$sf" ] && { rm -f "$sf"; echo '{"status":"cleared"}'; } || echo '{"status":"no_goal"}'
        ;;
    status) shift; sid=$(get_session_id "$@")
        sf="$GOAL_HOME/sessions/$sid/state.json"
        [ ! -f "$sf" ] && { echo "no_goal"; exit 0; }
        python3 -c "import json; print(json.load(open('$sf')).get('status',''))" 2>/dev/null || echo "unknown"
        ;;
    *) echo "Usage: goal get|create|update|clear|status [--session <id>] [--objective '...' | --status complete|blocked]"
        exit 1 ;;
esac
