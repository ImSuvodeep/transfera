#!/bin/bash

# Configuration
export PATH="/Users/suvodeepchowdhury/Transfera/tools/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export HOME="/Users/suvodeepchowdhury/Transfera/.flutter_home"
export ANDROID_HOME="/Users/suvodeepchowdhury/Transfera/tools/android-sdk"

# Move to app directory
cd "$( dirname "${BASH_SOURCE[0]}" )/../app"

echo "------------------------------------------------"
echo "🛠️  Transfera Production APK Builder"
echo "------------------------------------------------"

# 1. Clean build
echo "🧹 Cleaning previous builds..."
flutter clean > /dev/null

# 2. Get dependencies
echo "📦 Fetching packages..."
flutter pub get > /dev/null

# 3. Build APK
echo "🏗️  Building Optimized APK (Split by ABI for smaller size)..."
flutter build apk --split-per-abi --release --no-pub

if [ $? -eq 0 ]; then
    echo "✅ Build Successful!"
    # Move the universal or arm64 apk to the root
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    if [ ! -f "$APK_PATH" ]; then
        APK_PATH="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
    fi
    
    cp "$APK_PATH" ../Transfera_Remote.apk
    echo "------------------------------------------------"
    echo "📲 FINAL APK READY: Transfera_Remote.apk"
    echo "------------------------------------------------"
    echo "Next: Install this file on your real Android phone."
else
    echo "❌ Build Failed! Check the terminal output above."
    exit 1
fi
