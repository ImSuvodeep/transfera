#!/bin/bash
# macOS Build Script for Transfera

echo "🏗️ Building Transfera for macOS..."

cd app

# 1. Clean and get dependencies
flutter clean
flutter pub get

# 2. Build Release App
flutter build macos --release

echo "✅ Build Complete!"
echo "📍 Your App is located in:"
echo "   app/build/macos/Build/Products/Release/transfera.app"
echo ""
echo "🚀 NEXT STEPS:"
echo "1. Right-click 'transfera.app' and click 'Compress' to create a zip file."
echo "2. Send that zip file to your friends or upload to a sharing service."
echo "3. They can drag the app into their Applications folder."
