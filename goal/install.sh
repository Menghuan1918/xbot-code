#!/bin/bash
set -euo pipefail

# install.sh — Install the Goal plugin for xbot
# Multi-session + WebSocket-based forced continuation (no engine modification needed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBOT_HOME="${XBOT_HOME:-$HOME/.xbot}"
PLUGIN_DIR="$XBOT_HOME/plugins/goal"

echo "=== Goal Plugin Installer ==="
echo ""

echo "[1/2] Copying plugin to $PLUGIN_DIR ..."
mkdir -p "$PLUGIN_DIR"
cp -r "$SCRIPT_DIR"/* "$PLUGIN_DIR/"

chmod +x "$PLUGIN_DIR/goal.sh" \
         "$PLUGIN_DIR/widget.sh" \
         "$PLUGIN_DIR/hooks/on_prompt.sh" \
         "$PLUGIN_DIR/hooks/on_stop.sh" 2>/dev/null || true

echo "[2/2] Merging hooks configuration ..."
HOOKS_FILE="$XBOT_HOME/hooks.json"
[ ! -f "$HOOKS_FILE" ] && echo '{"enable_command_hooks":true,"hooks":{}}' > "$HOOKS_FILE"

python3 << 'PYEOF'
import json, os
xbot_home = os.environ.get("XBOT_HOME", os.path.expanduser("~/.xbot"))
hooks_file = os.path.join(xbot_home, "hooks.json")
plugin_dir = os.path.join(xbot_home, "plugins", "goal")
try:
    with open(hooks_file) as f: config = json.load(f)
except:
    config = {"enable_command_hooks": True, "hooks": {}}
config["enable_command_hooks"] = True
config.setdefault("hooks", {})
goal_hooks = {
    "UserPromptSubmit": [{"matcher":"","hooks":[{"type":"command","command":f"bash {plugin_dir}/hooks/on_prompt.sh","timeout":10}]}],
    "AgentStop": [{"matcher":"","hooks":[{"type":"command","command":f"bash {plugin_dir}/hooks/on_stop.sh","timeout":15}]}]
}
for event, handlers in goal_hooks.items():
    if event not in config["hooks"]:
        config["hooks"][event] = handlers
    else:
        for group in config["hooks"][event]:
            for hook in group.get("hooks", []):
                if "goal" in hook.get("command", ""):
                    hook["command"] = handlers[0]["hooks"][0]["command"]
                    break
            else:
                config["hooks"][event].extend(handlers)
                break
with open(hooks_file, "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print(f"  Hooks merged into {hooks_file}")
PYEOF

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Usage:"
echo "  /goal <objective>              — Start a new goal"
echo "  goal get [--session <id>]       — Check goal status"
echo "  goal update --status complete   — Mark goal as complete"
echo "  goal update --status blocked    — Mark goal as blocked"
echo "  goal clear [--session <id>]     — Clear goal state"
echo ""
echo "Features:"
echo "  - Multi-session: each session has independent goal state"
echo "  - Forced continuation: AgentStop hook injects continuation via WebSocket send_inbound"
echo "  - No xbot source modification required"
echo "  - No Cron self-scheduling needed"
