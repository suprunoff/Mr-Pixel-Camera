#!/bin/bash
set -e

cd "$(dirname "$0")"

REPO_NAME="${1:-PixelProCam-Studio}"
VISIBILITY="${2:---public}"

echo "🚀 Publishing $REPO_NAME to GitHub account $(gh api user -q .login 2>/dev/null || echo 'suprunoff')..."

if ! git remote get-url origin >/dev/null 2>&1; then
    gh repo create "$REPO_NAME" "$VISIBILITY" \
        --source=. \
        --remote=origin \
        --description "Native macOS Cinema Control Center for Google Pixel USB Webcam + OBS Studio (3D LUTs, Apple Vision AI Auto-Framing, Hardware Lens Switcher, RØDE Lip-Sync)" \
        --push
else
    git push -u origin main
fi

echo "✅ Published! View on GitHub:"
gh repo view --web || true
