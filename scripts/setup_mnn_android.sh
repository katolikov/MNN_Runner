#!/usr/bin/env bash
set -Eeuo pipefail

# Build and install MNN 3.1.0 for Android (armeabi-v7a, arm64-v8a) and place:
# - headers: android/app/src/main/cpp/third_party/MNN/include
# - libs:    android/app/src/main/jniLibs/<ABI>/libMNN.so
#
# Requirements: git, cmake, ninja, Android NDK, internet access.
# Optional: set MNN_VERSION, ABIS, ANDROID_API, EXTRA_CMAKE_FLAGS.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
APP_DIR="$ANDROID_DIR/app"
JNI_LIBS_DIR="$APP_DIR/src/main/jniLibs"
MNN_INCLUDE_DST="$APP_DIR/src/main/cpp/third_party/MNN/include"

MNN_VERSION="${MNN_VERSION:-3.1.0}"
ABIS_CSV="${ABIS:-arm64-v8a,armeabi-v7a}"
ANDROID_API="${ANDROID_API:-23}"
EXTRA_CMAKE_FLAGS="${EXTRA_CMAKE_FLAGS:-}" # e.g., "-DMNN_VULKAN=ON -DMNN_OPENCL=ON"

IFS=',' read -r -a ABIS <<<"$ABIS_CSV"

echo "==> MNN version: $MNN_VERSION"
echo "==> Target ABIs: ${ABIS[*]} (android-$ANDROID_API)"

require_bin() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1"; exit 1; }; }
require_bin git

# Resolve NDK/SDK path from local.properties, env, or SDK layout
NDK_PATH=""
LP_FILE="$ANDROID_DIR/local.properties"
SDK_DIR=""
if [[ -f "$LP_FILE" ]]; then
  NDK_PATH=$(grep -E '^ndk\.dir=' "$LP_FILE" | sed -E 's/^ndk\.dir=//') || true
  SDK_DIR=$(grep -E '^sdk\.dir=' "$LP_FILE" | sed -E 's/^sdk\.dir=//') || true
fi
if [[ -z "${NDK_PATH}" && -n "${ANDROID_NDK_HOME:-}" ]]; then NDK_PATH="$ANDROID_NDK_HOME"; fi
if [[ -z "${SDK_DIR}" && -n "${ANDROID_HOME:-}" ]]; then SDK_DIR="$ANDROID_HOME"; fi
if [[ -z "${SDK_DIR}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then SDK_DIR="$ANDROID_SDK_ROOT"; fi
if [[ -z "${NDK_PATH}" && -n "${SDK_DIR}" && -d "$SDK_DIR/ndk" ]]; then
  NDK_PATH=$(ls -d "$SDK_DIR/ndk"/* 2>/dev/null | sort -V | tail -n1 || true)
fi
if [[ -z "$NDK_PATH" || ! -d "$NDK_PATH" ]]; then
  echo "Error: Could not find Android NDK. Set ANDROID_NDK_HOME or ndk.dir in android/local.properties";
  exit 1;
fi
echo "==> Using NDK: $NDK_PATH"

# Ensure cmake/ninja are available (fallback to SDK CMake)
if ! command -v cmake >/dev/null 2>&1; then
  if [[ -n "${SDK_DIR}" && -d "$SDK_DIR/cmake" ]]; then
    CMAKE_BIN=$(ls -d "$SDK_DIR/cmake"/*/bin 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -n "$CMAKE_BIN" ]]; then export PATH="$CMAKE_BIN:$PATH"; fi
  fi
fi
require_bin cmake
if ! command -v ninja >/dev/null 2>&1; then
  if [[ -n "${SDK_DIR}" && -d "$SDK_DIR/cmake" ]]; then
    NINJA_BIN=$(ls -d "$SDK_DIR/cmake"/*/bin 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -n "$NINJA_BIN" ]]; then export PATH="$NINJA_BIN:$PATH"; fi
  fi
fi
if ! command -v ninja >/dev/null 2>&1; then echo "Info: ninja not found, using default generator"; fi

WORK_DIR="$ROOT_DIR/.mnn-build"
SRC_DIR="$WORK_DIR/MNN"
mkdir -p "$WORK_DIR"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  echo "==> Cloning MNN @ $MNN_VERSION"
  git clone --depth 1 --branch "$MNN_VERSION" https://github.com/alibaba/MNN.git "$SRC_DIR"
else
  echo "==> MNN source exists; skipping clone"
fi

# Prepare include destination
echo "==> Installing headers -> $MNN_INCLUDE_DST"
rm -rf "$MNN_INCLUDE_DST"
mkdir -p "$MNN_INCLUDE_DST"
cp -R "$SRC_DIR/include/"* "$MNN_INCLUDE_DST/"

for ABI in "${ABIS[@]}"; do
  echo "==> Building libMNN.so for $ABI"
  BUILD_DIR="$WORK_DIR/build-$ABI"
  GEN_ARGS=("-DCMAKE_BUILD_TYPE=Release" "-DMNN_BUILD_SHARED_LIBS=ON" "-DMNN_BUILD_TRAIN=OFF" "-DMNN_BUILD_BENCHMARK=OFF" "-DMNN_BUILD_DEMO=OFF")
  ANDROID_ARGS=(
    "-DANDROID_ABI=$ABI"
    "-DANDROID_PLATFORM=android-$ANDROID_API"
    "-DANDROID_STL=c++_shared"
    "-DCMAKE_TOOLCHAIN_FILE=$NDK_PATH/build/cmake/android.toolchain.cmake"
  )
  mkdir -p "$BUILD_DIR"
  if command -v ninja >/dev/null 2>&1; then
    cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja "${GEN_ARGS[@]}" "${ANDROID_ARGS[@]}" $EXTRA_CMAKE_FLAGS
    cmake --build "$BUILD_DIR" --target MNN -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}"
    # Attempt to build optional GPU plugin targets if enabled
    cmake --build "$BUILD_DIR" --target MNN_Vulkan -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}" || true
    cmake --build "$BUILD_DIR" --target MNN_CL -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}" || true
    cmake --build "$BUILD_DIR" --target MNN_GL -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}" || true
  else
    cmake -S "$SRC_DIR" -B "$BUILD_DIR" "${GEN_ARGS[@]}" "${ANDROID_ARGS[@]}" $EXTRA_CMAKE_FLAGS
    cmake --build "$BUILD_DIR" --target MNN -- -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}"
    cmake --build "$BUILD_DIR" --target MNN_Vulkan -- -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}" || true
    cmake --build "$BUILD_DIR" --target MNN_CL -- -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}" || true
    cmake --build "$BUILD_DIR" --target MNN_GL -- -j"${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)}" || true
  fi
  SO_PATH=$(find "$BUILD_DIR" -name 'libMNN.so' -type f | head -n1 || true)
  if [[ -z "$SO_PATH" ]]; then echo "Error: libMNN.so not found for $ABI"; exit 1; fi
  DST_DIR="$JNI_LIBS_DIR/$ABI"
  mkdir -p "$DST_DIR"
  cp -f "$SO_PATH" "$DST_DIR/libMNN.so"
  echo "    -> Installed $DST_DIR/libMNN.so"

  # If GPU backends were enabled, install their plugin libs too (separate build mode)
  # These files are optional and only exist when -DMNN_VULKAN=ON / -DMNN_OPENCL=ON / -DMNN_OPENGL=ON
  for plugin in MNN_Vulkan MNN_CL MNN_GL; do
    PLUGIN_PATH=$(find "$BUILD_DIR" -name "lib${plugin}.so" -type f | head -n1 || true)
    if [[ -n "$PLUGIN_PATH" ]]; then
      cp -f "$PLUGIN_PATH" "$DST_DIR/lib${plugin}.so"
      echo "    -> Installed $DST_DIR/lib${plugin}.so"
    fi
  done
done

echo "==> Done. MNN headers/libs installed. You can now build:"
echo "    GRADLE_USER_HOME=\"$ANDROID_DIR/.gradle-home\" flutter build apk --debug"
