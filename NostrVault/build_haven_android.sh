#!/usr/bin/env bash
# build_haven_android.sh
# Cross-compile the Haven Go relay into Android .so libraries via CGO.
#
# Prerequisites:
#   - Go 1.22+ installed
#   - Android NDK r26+ installed (set ANDROID_NDK_HOME or auto-detect)
#   - gomobile: go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
#
# Usage:
#   ./build_haven_android.sh              # Build all ABIs
#   ./build_haven_android.sh arm64        # Build only arm64-v8a
#   ./build_haven_android.sh clean        # Remove built .so files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_SRC_DIR="${SCRIPT_DIR}/../haven-go"
OUTPUT_BASE="${SCRIPT_DIR}/app/src/main/jniLibs"

# Android NDK auto-detection
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    # Common locations
    for candidate in \
        "$HOME/Library/Android/sdk/ndk"/* \
        "$HOME/Android/Sdk/ndk"/* \
        "/usr/local/lib/android/sdk/ndk"/*; do
        if [ -d "$candidate" ]; then
            ANDROID_NDK_HOME="$candidate"
            break
        fi
    done
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ERROR: ANDROID_NDK_HOME not set and NDK not found in common locations."
    echo "Install via: sdkmanager --install 'ndk;26.1.10909125'"
    exit 1
fi

echo "Using NDK: ${ANDROID_NDK_HOME}"

# NDK toolchain bin directory
NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt"
if [ "$(uname)" = "Darwin" ]; then
    NDK_HOST="darwin-x86_64"
elif [ "$(uname)" = "Linux" ]; then
    NDK_HOST="linux-x86_64"
else
    echo "ERROR: Unsupported host OS: $(uname)"
    exit 1
fi
NDK_BIN="${NDK_TOOLCHAIN}/${NDK_HOST}/bin"

# API level (minSdk 26 = Android 8.0)
API_LEVEL=26

# ABI -> (GOARCH, CC triple) mapping
declare -A ABI_MAP
ABI_MAP[arm64-v8a]="arm64:aarch64-linux-android${API_LEVEL}-clang"
ABI_MAP[armeabi-v7a]="arm:armv7a-linux-androideabi${API_LEVEL}-clang"
ABI_MAP[x86_64]="amd64:x86_64-linux-android${API_LEVEL}-clang"

build_abi() {
    local abi="$1"
    local goarch="${ABI_MAP[$abi]%%:*}"
    local cc="${ABI_MAP[$abi]##*:}"
    local output_dir="${OUTPUT_BASE}/${abi}"
    local output_file="${output_dir}/libhaven.so"

    echo "Building ${abi} (GOARCH=${goarch})..."

    mkdir -p "${output_dir}"

    # Use Go 1.24.x for c-shared builds — Go 1.26+ has GC regressions
    # in c-shared mode on Android ARM64 (span corruption / bad heap pointers).
    local GO_CMD="${GO_CMD:-go}"
    if command -v go1.24.4 &>/dev/null; then
        GO_CMD="go1.24.4"
    fi

    CGO_ENABLED=1 \
    GOOS=android \
    GOARCH="${goarch}" \
    CC="${NDK_BIN}/${cc}" \
    ${GO_CMD} build \
        -buildmode=c-shared \
        -tags cshared \
        -trimpath \
        -ldflags="-s -w" \
        -o "${output_file}" \
        "${GO_SRC_DIR}"

    # Remove the generated .h file (we define our own JNI bridge)
    rm -f "${output_dir}/libhaven.h"

    local size
    size=$(du -h "${output_file}" | cut -f1)
    echo "  -> ${output_file} (${size})"
}

clean() {
    echo "Cleaning built .so files..."
    for abi in "${!ABI_MAP[@]}"; do
        rm -f "${OUTPUT_BASE}/${abi}/libhaven.so"
        rm -f "${OUTPUT_BASE}/${abi}/libhaven.h"
    done
    echo "Clean complete."
}

# Parse arguments
if [ "${1:-}" = "clean" ]; then
    clean
    exit 0
fi

if [ -n "${1:-}" ]; then
    # Build specific ABI
    if [ -z "${ABI_MAP[${1}]:-}" ]; then
        echo "ERROR: Unknown ABI '${1}'. Valid: ${!ABI_MAP[*]}"
        exit 1
    fi
    build_abi "$1"
else
    # Build all ABIs
    for abi in arm64-v8a armeabi-v7a x86_64; do
        build_abi "$abi"
    done
fi

echo ""
echo "Build complete. .so files are in ${OUTPUT_BASE}/"
ls -la "${OUTPUT_BASE}"/*/libhaven.so 2>/dev/null || true
