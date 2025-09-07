#!/usr/bin/env bash
set -euo pipefail

# Push shared libs from jniLibs to an Android device for shell-side testing.
# Usage: ./scripts/push_libs.sh [arm64-v8a|armeabi-v7a]

ADB_BIN=${ADB_BIN:-adb}
ABI=${1:-}

if [[ -z "${ABI}" ]]; then
  # Try auto-detect via device's ro.product.cpu.abi
  ABI=$(${ADB_BIN} shell getprop ro.product.cpu.abi | tr -d '\r')
fi

case "${ABI}" in
  arm64-v8a|arm64*) ABI=arm64-v8a ;;
  armeabi-v7a|armeabi*) ABI=armeabi-v7a ;;
  *) echo "Unknown/unsupported ABI: ${ABI}. Pass one of: arm64-v8a, armeabi-v7a" ; exit 1 ;;
esac

SRC_DIR="android/app/src/main/jniLibs/${ABI}"
if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Missing jniLibs for ABI ${ABI}: ${SRC_DIR}" >&2
  exit 1
fi

DEST_DIR="/data/local/tmp/mnn/${ABI}"
echo "Pushing libs for ${ABI} to ${DEST_DIR}"
${ADB_BIN} shell mkdir -p "${DEST_DIR}"

for lib in libMNN.so libMNN_Express.so libMNN_CL.so libMNN_Vulkan.so libMNN_GL.so ; do
  if [[ -f "${SRC_DIR}/${lib}" ]]; then
    echo "- ${lib}"
    ${ADB_BIN} push "${SRC_DIR}/${lib}" "${DEST_DIR}/${lib}" >/dev/null
  else
    echo "- ${lib} (not found, skipping)"
  fi
done

${ADB_BIN} shell chmod -R 755 "/data/local/tmp/mnn"
echo "Done. On device, set LD_LIBRARY_PATH=${DEST_DIR} when running your binary."

