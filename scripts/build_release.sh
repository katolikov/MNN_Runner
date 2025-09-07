#!/usr/bin/env bash
set -euo pipefail

# Build a release APK and print the output path.

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter not found in PATH" >&2
  exit 1
fi

echo "Checking native libs..."
if [[ ! -d android/app/src/main/jniLibs ]]; then
  echo "Missing android/app/src/main/jniLibs with MNN .so files" >&2
  exit 1
fi

flutter pub get
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
if [[ -f "$APK" ]]; then
  echo "Built APK: $APK"
else
  echo "APK not found; build may have failed" >&2
  exit 1
fi

