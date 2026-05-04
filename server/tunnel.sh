#!/bin/bash

# Configuration
PORT=3000

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# Ensure dependencies are installed
if [ ! -d "node_modules" ]; then
    echo "📦 Installing server dependencies..."
    npm install
fi

# Start signaling server in background
echo "🌐 Starting Signaling Server on port $PORT..."
node index.js > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Start localtunnel
echo "🚀 Exposing server to the internet using localtunnel..."
echo "--------------------------------------------------------"
npx localtunnel --port $PORT

# Cleanup on exit
kill $SERVER_PID
echo "👋 Server stopped."
