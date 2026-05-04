#!/bin/bash
export PATH="/Users/suvodeepchowdhury/Transfera/tools/flutter/bin:/opt/homebrew/bin:$PATH"
export HOME="/Users/suvodeepchowdhury/Transfera/.flutter_home"
export ANDROID_HOME="/Users/suvodeepchowdhury/Transfera/tools/android-sdk"

echo "🚀 Restarting Signaling Server..."
killall node 2>/dev/null
cd server && node index.js > server.log 2>&1 &

echo "💻 Launching macOS App..."
cd app && flutter run -d macos > macos_run.log 2>&1 &

echo "📱 Launching Android App (emulator-5554)..."
flutter run -d emulator-5554 > android_run.log 2>&1 &

echo "✅ Both apps are launching in the background."
echo "📝 Run 'tail -f app/macos_run.log' or 'tail -f app/android_run.log' to see output."
