#!/bin/bash
# Start MCP Server on port 3845

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_SERVER="$SCRIPT_DIR/mcp_server.py"
PID_FILE="/tmp/mcp_server.pid"
LOG_FILE="/tmp/mcp_server.log"

# Check if already running
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "MCP server is already running (PID: $PID)"
        exit 0
    else
        rm -f "$PID_FILE"
    fi
fi

# Start server
echo "Starting MCP server on http://127.0.0.1:3845/mcp"
nohup python3 "$MCP_SERVER" 3845 > "$LOG_FILE" 2>&1 &
PID=$!

# Save PID
echo $PID > "$PID_FILE"

# Wait a moment and check if it's running
sleep 1
if ps -p "$PID" > /dev/null 2>&1; then
    echo "MCP server started successfully (PID: $PID)"
    echo "Log file: $LOG_FILE"
    echo "To stop: kill $PID or run stop_mcp_server.sh"
else
    echo "Failed to start MCP server. Check log: $LOG_FILE"
    rm -f "$PID_FILE"
    exit 1
fi











