#!/bin/bash
set -e

echo "🎬 Installing Mr. Pixel Camera v2.1 for macOS (by mrmo.es)..."

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
OBS_LUT_DIR="$HOME/Library/Application Support/obs-studio/LUTs"
APP_BUNDLE="$REPO_DIR/Mr. Pixel Camera.app"

# 1. Install 3D LUTs (.cube) & Optical Overlays (.png) into OBS Studio
mkdir -p "$OBS_LUT_DIR"
cp -f "$REPO_DIR/assets/luts/"*.cube "$OBS_LUT_DIR/"
cp -f "$REPO_DIR/assets/overlays/"*.png "$OBS_LUT_DIR/"
echo "✅ Installed 33x33x33 3D LUTs & Cinema Overlays into: $OBS_LUT_DIR"

# 2. Build Native macOS App Bundle (Apple Silicon / Intel)
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp -f "$REPO_DIR/assets/icons/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -f "$REPO_DIR/assets/icons/mo_logo.png" "$APP_BUNDLE/Contents/Resources/mo_logo.png"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
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
    <string>2.1</string>
    <key>CFBundleVersion</key>
    <string>21</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "⚙️ Compiling PixelProCamStudio.swift with Apple Vision & SwiftUI..."
/usr/bin/swiftc -O "$REPO_DIR/macos/PixelProCamStudio.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/PixelProCamStudio" \
    -framework Cocoa -framework SwiftUI -framework UniformTypeIdentifiers -framework Vision

if [ -f "$REPO_DIR/bin/adb" ]; then
    cp -f "$REPO_DIR/bin/adb" "$APP_BUNDLE/Contents/MacOS/adb"
    chmod +x "$APP_BUNDLE/Contents/MacOS/adb"
fi

touch "$APP_BUNDLE"
echo "✅ Built native macOS app: $APP_BUNDLE"

# 3. Ensure OBS WebSocket v5 server is enabled on port 4455 (auth disabled for local loopback)
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

echo "🚀 Launching PixelProCam Studio.app..."
open "$APP_BUNDLE"
