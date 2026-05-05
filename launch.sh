#!/bin/bash

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Flutter path (bundled with project)
FLUTTER="$SCRIPT_DIR/tools/flutter/bin/flutter"

# Signaling is now on Render — no tunnel needed!

# Handle Launch Options
cd "$SCRIPT_DIR/app"
case "$1" in
    "macos")
        echo "💻 Launching Transfera for macOS..."
        "$FLUTTER" run -d macos
        ;;
    "ios")
        echo "📱 Launching Transfera for iOS Simulator..."
        "$FLUTTER" run -d ios
        ;;
    "android")
        echo "🤖 Launching Transfera for Android..."
        "$FLUTTER" run -d android
        ;;
    "build-apk")
        echo "📦 Building release APK..."
        "$FLUTTER" build apk --release
        echo "✅ APK: app/build/app/outputs/flutter-apk/app-release.apk"
        ;;
    "build-macos")
        echo "🏗️ Building macOS release app..."
        "$FLUTTER" build macos
        echo "✅ App: app/build/macos/Build/Products/Release/transfera.app"
        open "$SCRIPT_DIR/app/build/macos/Build/Products/Release/transfera.app"
        ;;
    *)
        echo "Usage: ./launch.sh [macos|ios|android|build-apk|build-macos]"
        echo ""
        echo "  macos       — Run Mac debug build (hot reload enabled)"
        echo "  android     — Run on connected Android device"
        echo "  build-apk   — Build release APK for Android"
        echo "  build-macos — Build & open release Mac app"
        ;;
esac
