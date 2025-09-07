#!/usr/bin/env bash
set -euo pipefail

# Capture a screenshot from a connected Android 15/16 device or emulator.
# Usage: scripts/screenshot_android.sh [serial]

PKG=com.mnn.runner.mnn_runner_app
ACT=com.mnn.runner.mnn_runner_app.MainActivity
SERIAL=${1:-}

ADB=(adb)
if [[ -n "$SERIAL" ]]; then
  ADB=(adb -s "$SERIAL")
fi

echo "[i] Checking device..."
"${ADB[@]}" get-state >/dev/null

echo "[i] Building and installing debug APK (first run may take a while)..."
flutter build apk --debug >/dev/null
"${ADB[@]}" install -r build/app/outputs/flutter-apk/app-debug.apk >/dev/null || true

echo "[i] Launching app..."
"${ADB[@]}" shell am start -W -n ${PKG}/${ACT} >/dev/null
sleep 2

mkdir -p docs
OUT=docs/screenshot_android.png
echo "[i] Capturing screenshot to ${OUT}"
"${ADB[@]}" exec-out screencap -p > "$OUT"
echo "[✓] Saved: ${OUT}"

