#!/bin/bash
# ready_for_remote.sh
# Bootstraps the environment for mobile hotspot / completely remote transfers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
PORT=3000
LOG_DIR="server"
TUNNEL_LOG="$LOG_DIR/tunnel.log"

echo "------------------------------------------------"
echo "🚀 Transfera Remote Setup (Cloudflare + NTFY Bridge)"
echo "------------------------------------------------"

# 1. Kill old processes
echo "🧹 Cleaning up old sessions..."
killall node 2>/dev/null
pkill -f "localtunnel" 2>/dev/null
pkill -f "cloudflared" 2>/dev/null
sleep 2

# 2. Start Cloudflare Tunnel in background
echo "🔗 Opening Cloudflare Tunnel..."
mkdir -p "$LOG_DIR"
cd "$LOG_DIR"
nohup cloudflared tunnel --url http://localhost:$PORT > tunnel.log 2>&1 &
cd "$SCRIPT_DIR"

# Wait for tunnel to initialize and generate URL
sleep 6

# Extract the TryCloudflare URL
TUNNEL_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TUNNEL_LOG" | head -n 1)

if [ -z "$TUNNEL_URL" ]; then
    echo "❌ ERROR: Failed to extract Cloudflare URL."
    echo "Check server/tunnel.log for details."
    cat "$TUNNEL_LOG"
    exit 1
fi

echo "✅ Tunnel Active: $TUNNEL_URL"

# 3. Publish URL to unique NTFY bridge so Android can discover it automatically
echo "📡 Publishing URL to unique discovery bridge..."
curl -s -d "$TUNNEL_URL" "https://ntfy.sh/transfera-suvodeep-bridge" > /dev/null

# 4. Start Node server WITH TUNNEL_URL injected
echo "🌐 Starting Signaling Server with TUNNEL_URL=$TUNNEL_URL..."
cd "$LOG_DIR"
export TUNNEL_URL="$TUNNEL_URL"
nohup node index.js > server.log 2>&1 &
cd "$SCRIPT_DIR"

sleep 2

if pgrep -f "node index.js" > /dev/null; then
    echo "✅ Server is live at http://localhost:3000"
    echo "✅ App will auto-fetch: $TUNNEL_URL"
    echo "------------------------------------------------"
    echo "🎉 ALL DONE! Open the Mac app and you're ready."
    echo "   Android will discover the URL automatically."
    echo "   You can now TYPE the 6-digit code again!"
    echo "------------------------------------------------"
else
    echo "❌ ERROR: Signaling Server failed to start."
    cat "$LOG_DIR/server.log"
    exit 1
fi
