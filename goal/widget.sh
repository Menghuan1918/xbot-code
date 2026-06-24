#!/bin/bash
set -euo pipefail

# widget.sh — InfoBar widget showing goal status (multi-session)
# Uses $XBOT_SESSION_ID to find the right goal state.

GOAL_HOME="${XBOT_HOME:-$HOME/.xbot}/goal"
SESSION_ID="${XBOT_SESSION_ID:-default}"
STATE_FILE="$GOAL_HOME/sessions/$SESSION_ID/state.json"

if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

STATUS=$(python3 -c "
import json
try:
    with open('$STATE_FILE') as f:
        print(json.load(f).get('status', ''))
except:
    print('')
" 2>/dev/null || echo "")

case "$STATUS" in
    active)
        ITER=$(python3 -c "
import json
try:
    with open('$STATE_FILE') as f:
        print(json.load(f).get('iteration', 0))
except:
    print(0)
" 2>/dev/null || echo "0")
        echo "accent|🎯 goal #$ITER"
        ;;
    complete)
        echo "ok|🎯 ✓ done"
        ;;
    blocked)
        echo "warn|🎯 blocked"
        ;;
    *)
        exit 0
        ;;
esac
