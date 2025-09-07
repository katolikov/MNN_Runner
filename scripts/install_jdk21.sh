#!/usr/bin/env bash
set -Eeuo pipefail

# Download and set up Temurin JDK 21 locally, and configure Gradle to use it.
# Installs under .jdk/temurin-21 and updates android/gradle.properties with org.gradle.java.home.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
JDK_DIR="$ROOT_DIR/.jdk"
TARGET_DIR="$JDK_DIR/temurin-21"

OS=$(uname -s)
ARCH=$(uname -m)

case "$OS" in
  Darwin) OS_SLUG="mac" ;;
  Linux)  OS_SLUG="linux" ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  arm64|aarch64) ARCH_SLUG="aarch64" ;;
  x86_64|amd64)  ARCH_SLUG="x64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

URL="https://api.adoptium.net/v3/binary/latest/21/ga/${OS_SLUG}/${ARCH_SLUG}/jdk/hotspot/normal/eclipse?project=jdk"

mkdir -p "$JDK_DIR"
TMP_TGZ="$JDK_DIR/jdk21.tgz"

echo "==> Downloading JDK 21: $URL"
curl -L --fail -o "$TMP_TGZ" "$URL"

echo "==> Extracting to $TARGET_DIR"
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
tar -xzf "$TMP_TGZ" -C "$TARGET_DIR" --strip-components=1
rm -f "$TMP_TGZ"

JAVA_HOME_LOCAL="$TARGET_DIR"
if [[ "$OS" == "Darwin" ]]; then
  # macOS Temurin tarball extracts as a bundle with Contents/Home
  if [[ -d "$TARGET_DIR/Contents/Home" ]]; then
    JAVA_HOME_LOCAL="$TARGET_DIR/Contents/Home"
  fi
fi
GP="$ANDROID_DIR/gradle.properties"

echo "==> Setting org.gradle.java.home in $GP"
if grep -q '^org.gradle.java.home=' "$GP" 2>/dev/null; then
  sed -i.bak -E "s|^org.gradle.java.home=.*$|org.gradle.java.home=$JAVA_HOME_LOCAL|" "$GP"
else
  echo "org.gradle.java.home=$JAVA_HOME_LOCAL" >> "$GP"
fi

echo "==> Done. JAVA_HOME=$JAVA_HOME_LOCAL"
echo "    Next builds will use JDK 21. Example:"
echo "    GRADLE_USER_HOME=\"$ANDROID_DIR/.gradle-home\" flutter build apk --debug"
