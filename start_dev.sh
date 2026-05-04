export PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
export TOOLS_DIR="$PROJECT_ROOT/tools"

# Add Flutter and Java to PATH
export PATH="$TOOLS_DIR/flutter/bin:/opt/homebrew/opt/openjdk@17/bin:$PATH"
export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
export ANDROID_SDK_ROOT="$TOOLS_DIR/android-sdk"

# Force Flutter to use the project folder for config to avoid permission errors
export HOME="$PROJECT_ROOT/tools/fake_home"

echo "✅ Transfera Environment Ready (Portable Mode)!"
echo "You can now run 'flutter' commands in this terminal."
