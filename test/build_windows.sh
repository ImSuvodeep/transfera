#!/bin/bash
# Windows Build Script for Transfera

echo "🏗️ Building Transfera for Windows..."

cd app

# 1. Setup Environment
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../start_dev.sh"

cd "$SCRIPT_DIR/../app"

# 2. Clean and get dependencies
flutter clean
flutter pub get

# 3. Build Release Executable
# Note: Windows builds require a Windows machine. 
# This script is prepared for when you run it in a Windows terminal/WSL.
flutter build windows --release

echo "✅ Build Complete!"
echo "📍 Your Windows App is located in:"
echo "   app/build/windows/runner/Release/"
echo ""
echo "🚀 NEXT STEPS:"
echo "1. Zip the 'Release' folder and share it with your friends."
echo "2. They can run 'transfera.exe' to start transferring files."
