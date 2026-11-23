#!/bin/zsh
set -e

cd "$(dirname "$0")/android"
ADB="/Applications/IriunWebcam.app/Contents/MacOS/adb"
if ! command -v "$ADB" >/dev/null 2>&1; then
    ADB="adb"
fi

echo "==> Checking Java & Gradle..."
if ! command -v gradle >/dev/null 2>&1; then
    brew install openjdk@17 gradle
    brew install --cask android-commandlinetools
fi

export JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || echo "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home")"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"

if [ ! -d "$ANDROID_HOME/platforms/android-34" ]; then
    yes | sdkmanager --sdk_root="$ANDROID_HOME" "platforms;android-34" "build-tools;34.0.0" "platform-tools"
fi

echo "==> Building PixelProCam APK..."
gradle assembleDebug

APK_PATH="app/build/outputs/apk/debug/app-debug.apk"
echo "==> Installing $APK_PATH onto Pixel 10 Pro..."
"$ADB" install -r "$APK_PATH"
"$ADB" forward tcp:5555 tcp:5555
"$ADB" forward tcp:5556 tcp:5556
"$ADB" shell am start -n com.pixelprocam/.MainActivity
echo "==> Done! PixelProCam is running on your Pixel 10 Pro."
