#!/bin/bash
# Claude Code adapter for ghostty-restore daemon.
# Given a PID, resolves the Claude session ID from ~/.claude/sessions/{pid}.json
# and outputs the resume command.
#
# Usage: claude.sh <pid> <process_name>
# Exit 0 + stdout command = match
# Exit 1 = no match (pass to next adapter)

PID="$1"
PROCESS_NAME="$2"

# Only handle claude processes
[[ "$PROCESS_NAME" == "claude" ]] || exit 1

SESSION_FILE="$HOME/.claude/sessions/${PID}.json"
[[ -f "$SESSION_FILE" ]] || exit 1

# Extract sessionId — use python since it's always available on macOS/Linux
SESSION_ID=$(python3 -c "
import json, sys
try:
    data = json.load(open('$SESSION_FILE'))
    print(data.get('sessionId', ''))
except Exception:
    sys.exit(1)
" 2>/dev/null)

[[ -n "$SESSION_ID" ]] || exit 1

echo "claude --resume $SESSION_ID"
