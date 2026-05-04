#!/bin/bash
# Windows Build Script for Transfera

echo "🏗️ Building Transfera for Windows..."

cd app

# 1. Clean and get dependencies
flutter clean
flutter pub get

# 2. Build Release Executable
flutter build windows --release

echo "✅ Build Complete!"
echo "📍 Your Windows App is located in:"
echo "   app/build/windows/runner/Release/"
echo ""
echo "🚀 NEXT STEPS:"
echo "1. Zip the 'Release' folder and share it with your friends."
echo "2. They can run 'transfera.exe' to start transferring files."
