#!/bin/bash
# Android Build Script for Transfera

echo "🏗️ Building Transfera for Android..."

cd app

# 1. Clean and get dependencies
flutter clean
flutter pub get

# 2. Build Release APK
# NOTE: To send this to friends, an APK is the easiest format.
# If you want to put it on Google Play, use 'flutter build appbundle'.
flutter build apk --release --split-per-abi

echo "✅ Build Complete!"
echo "📍 Your APK files are located in:"
echo "   app/build/app/outputs/flutter-apk/"
echo ""
echo "🚀 NEXT STEPS:"
echo "1. Upload 'app-release.apk' to Google Drive, Discord, or Transfer.sh."
echo "2. Share that link with your friends."
echo "3. They can install it by enabling 'Install from Unknown Sources' on their phone."
