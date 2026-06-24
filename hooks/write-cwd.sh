#!/bin/bash
# write-cwd.sh — Called by UserPromptSubmit hook to cache the project directory
# for the AGENTS.md enricher.
#
# Environment variables (provided by xbot hooks system):
#   $XBOT_PROJECT_DIR  — current project root directory
#   $XBOT_SESSION_ID    — current session ID
#
# Writes $XBOT_PROJECT_DIR to a per-session temp file so the stdio enricher
# can read it when building the system prompt.

set -euo pipefail

# Use session ID for per-session isolation (avoids race between concurrent sessions)
SESSION_ID="${XBOT_SESSION_ID:-default}"
CACHE_FILE="/tmp/xbot-agents-md-cwd-${SESSION_ID}"

# Write the project directory to the cache file
echo -n "${XBOT_PROJECT_DIR:-}" > "$CACHE_FILE"

# Exit 0 = allow the user prompt to proceed
exit 0
