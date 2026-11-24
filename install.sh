#!/bin/bash
set -e

echo "🎬 Installing Mr. Pixel Camera v2.2 + Mr. Audio Meters v2.6 for macOS (by mrmo.es)..."

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
OBS_LUT_DIR="$HOME/Library/Application Support/obs-studio/LUTs"
CAM_BUNDLE="$REPO_DIR/Mr. Pixel Camera.app"
AUD_BUNDLE="$REPO_DIR/Mr. Audio Meters.app"

# 1. Install 3D LUTs (.cube), GPU Shaders (.shader) & Optical Overlays (.png) into OBS Studio
mkdir -p "$OBS_LUT_DIR"
cp -f "$REPO_DIR/assets/luts/"*.cube "$OBS_LUT_DIR/"
cp -f "$REPO_DIR/assets/overlays/"*.png "$OBS_LUT_DIR/"
if [ -d "$REPO_DIR/assets/shaders" ]; then
    cp -f "$REPO_DIR/assets/shaders/"*.shader "$OBS_LUT_DIR/"
fi
echo "✅ Installed 3D LUTs, GPU Cinema Shaders & Overlays into: $OBS_LUT_DIR"

# 2. Build Native Mr. Pixel Camera.app
mkdir -p "$CAM_BUNDLE/Contents/MacOS" "$CAM_BUNDLE/Contents/Resources"
cp -f "$REPO_DIR/assets/icons/AppIcon.icns" "$CAM_BUNDLE/Contents/Resources/AppIcon.icns"
cp -f "$REPO_DIR/assets/icons/mo_logo.png" "$CAM_BUNDLE/Contents/Resources/mo_logo.png"

cat > "$CAM_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PixelProCamStudio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>es.mrmo.MrPixelCamera</string>
    <key>CFBundleName</key>
    <string>Mr. Pixel Camera</string>
    <key>CFBundleDisplayName</key>
    <string>Mr. Pixel Camera</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.2</string>
    <key>CFBundleVersion</key>
    <string>22</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "⚙️ Compiling Mr. Pixel Camera (SwiftUI + Apple Vision)..."
/usr/bin/swiftc -O "$REPO_DIR/macos/PixelProCamStudio.swift" \
    -o "$CAM_BUNDLE/Contents/MacOS/PixelProCamStudio" \
    -framework Cocoa -framework SwiftUI -framework UniformTypeIdentifiers -framework Vision

if [ -f "$REPO_DIR/bin/adb" ]; then
    cp -f "$REPO_DIR/bin/adb" "$CAM_BUNDLE/Contents/MacOS/adb"
    chmod +x "$CAM_BUNDLE/Contents/MacOS/adb"
fi
codesign --force --deep --sign - "$CAM_BUNDLE" >/dev/null 2>&1 || true
touch "$CAM_BUNDLE"
echo "✅ Built: $CAM_BUNDLE"

# 3. Build Native Mr. Audio Meters.app (RØDE NT1 USB HID + CoreAudio + vDSP + ScreenCaptureKit + OBS RNNoise)
mkdir -p "$AUD_BUNDLE/Contents/MacOS" "$AUD_BUNDLE/Contents/Resources"
cp -f "$REPO_DIR/assets/icons/AudioMetersIcon.icns" "$AUD_BUNDLE/Contents/Resources/AppIcon.icns"
cp -f "$REPO_DIR/assets/icons/mo_audio_logo.png" "$AUD_BUNDLE/Contents/Resources/mo_audio_logo.png"
cp -f "$REPO_DIR/assets/icons/mo_logo.png" "$AUD_BUNDLE/Contents/Resources/mo_logo.png"

cat > "$AUD_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MrAudioMeters</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>es.mrmo.MrAudioMeters</string>
    <key>CFBundleName</key>
    <string>Mr. Audio Meters</string>
    <key>CFBundleDisplayName</key>
    <string>Mr. Audio Meters</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.6</string>
    <key>CFBundleVersion</key>
    <string>26</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mr. Audio Meters uses your microphone for real-time FFT spectrum, waveform, spectrogram, EBU R128 LUFS metering, RT60 echo measurement, and RØDE NT1 calibration.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Mr. Audio Meters optionally captures macOS System Audio (ScreenCaptureKit) when you switch the meter source to System Audio.</string>
</dict>
</plist>
EOF

echo "⚙️ Compiling Mr. Audio Meters v2.6 (Accelerate vDSP + IOKit HID + ScreenCaptureKit + Carbon)..."
/usr/bin/swiftc -O "$REPO_DIR/macos/MrAudioMeters.swift" \
    -o "$AUD_BUNDLE/Contents/MacOS/MrAudioMeters" \
    -framework Cocoa -framework SwiftUI -framework AVFoundation -framework CoreAudio \
    -framework AudioToolbox -framework Accelerate -framework IOKit \
    -framework Carbon -framework ScreenCaptureKit -framework CoreMedia

codesign --force --deep --sign - "$AUD_BUNDLE" >/dev/null 2>&1 || true
touch "$AUD_BUNDLE"
echo "✅ Built: $AUD_BUNDLE"

# 4. Sync both apps into /Applications (for Spotlight, Raycast & Launchpad!)
if [ -w "/Applications" ]; then
    rm -rf "/Applications/Mr. Pixel Camera.app" "/Applications/Mr. Audio Meters.app"
    ditto "$CAM_BUNDLE" "/Applications/Mr. Pixel Camera.app"
    ditto "$AUD_BUNDLE" "/Applications/Mr. Audio Meters.app"
    echo "✅ Installed into /Applications: Mr. Pixel Camera.app & Mr. Audio Meters.app"
fi

# 5. Ensure OBS WebSocket v5 server is enabled on port 4455 (local loopback)
OBS_WS_CFG="$HOME/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json"
if [ -d "$(dirname "$OBS_WS_CFG")" ]; then
    cat > "$OBS_WS_CFG" << 'EOF'
{
    "alerts_enabled": false,
    "auth_required": false,
    "first_load": false,
    "server_enabled": true,
    "server_password": "",
    "server_port": 4455
}
EOF
    echo "✅ Configured OBS WebSocket v5 (port 4455)"
fi

echo "🚀 Launching Mr. Pixel Camera.app & Mr. Audio Meters.app..."
if [ -d "/Applications/Mr. Pixel Camera.app" ]; then
    open "/Applications/Mr. Pixel Camera.app"
    open "/Applications/Mr. Audio Meters.app"
else
    open "$CAM_BUNDLE"
    open "$AUD_BUNDLE"
fi
