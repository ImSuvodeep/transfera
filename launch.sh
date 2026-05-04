#!/bin/bash

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 1. Setup Environment
source "$SCRIPT_DIR/start_dev.sh"
export PATH="/opt/homebrew/bin:$PATH"

# 2. Start Cloudflare Tunnel & Signaling Server automatically
echo "🌐 Initializing Cloudflare Remote Tunnel..."
./ready_for_remote.sh


# 3. Handle Launch Options
cd "$SCRIPT_DIR/app"
case "$1" in
    "macos")
        echo "💻 Launching Transfera for macOS..."
        flutter run -d macos
        ;;
    "ios")
        echo "📱 Launching Transfera for iOS Simulator..."
        flutter run -d ios
        ;;
    "android")
        echo "🤖 Launching Transfera for Android..."
        flutter run -d android
        ;;
    *)
        echo "❓ Usage: ./launch.sh [macos|ios|android]"
        echo "Example: ./launch.sh macos"
        ;;
esac
