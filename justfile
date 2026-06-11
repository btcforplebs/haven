# Haven / Nostr Vault build recipes

android_sdk := env("ANDROID_HOME", env("HOME", "") + "/Library/Android/sdk")
adb := android_sdk + "/platform-tools/adb"
ndk_home := `ls -d ~/Library/Android/sdk/ndk/* 2>/dev/null | tail -1`

# Build Android release APK (compiles Go native lib + Gradle build)
android-build:
    #!/usr/bin/env bash
    set -euo pipefail
    NDK_BIN="{{ndk_home}}/toolchains/llvm/prebuilt/darwin-x86_64/bin"
    GO_SRC="{{justfile_directory()}}/haven-go"
    JNILIBS="{{justfile_directory()}}/NostrVault/app/src/main/jniLibs"
    mkdir -p "$JNILIBS/arm64-v8a"
    JNI_SRC="{{justfile_directory()}}/NostrVault/app/src/main/java/com/nostrvault/relay/HavenBridgeJNI.c"
    echo "Building libhaven.so for arm64-v8a (with JNI bridge)..."
    # Copy JNI bridge into Go source so CGO compiles it into libhaven.so
    cp "$JNI_SRC" "$GO_SRC/HavenBridgeJNI.c"
    cd "$GO_SRC"
    CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
        CC="${NDK_BIN}/aarch64-linux-android26-clang" \
        CGO_CFLAGS="-DMDB_USE_ROBUST=0" \
        go build -buildmode=c-shared -tags cshared -trimpath \
        -ldflags="-s -w" \
        -o "$JNILIBS/arm64-v8a/libhaven.so" .
    rm -f "$GO_SRC/HavenBridgeJNI.c"
    rm -f "$JNILIBS/arm64-v8a/libhaven.h"
    echo "Building APK..."
    cd {{justfile_directory()}}/NostrVault && ./gradlew assembleRelease

# Install Android release APK on connected device
android-install:
    {{adb}} install -r {{justfile_directory()}}/NostrVault/app/build/outputs/apk/release/app-release.apk

# Build iOS app via Xcode
ios-build:
    xcodebuild -project {{justfile_directory()}}/HavenApp/HavenApp.xcodeproj \
        -scheme HavenApp-iOS \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -allowProvisioningUpdates \
        build

# Build macOS app via Xcode
macos-build:
    xcodebuild -project {{justfile_directory()}}/HavenApp/HavenApp.xcodeproj \
        -scheme HavenApp \
        -configuration Debug \
        -allowProvisioningUpdates \
        build
