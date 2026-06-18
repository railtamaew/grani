#!/bin/bash
# Stop MCP Server

PID_FILE="/tmp/mcp_server.pid"

if [ ! -f "$PID_FILE" ]; then
    echo "MCP server is not running (PID file not found)"
    exit 0
fi

PID=$(cat "$PID_FILE")

if ps -p "$PID" > /dev/null 2>&1; then
    echo "Stopping MCP server (PID: $PID)"
    kill "$PID"
    rm -f "$PID_FILE"
    echo "MCP server stopped"
else
    echo "MCP server is not running (process not found)"
    rm -f "$PID_FILE"
fi











