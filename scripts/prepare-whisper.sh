#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DEST="$VENDOR/whisper.xcframework"
VERSION="1.9.1"
MIN_IOS="15.0"

audit_framework() {
  local binary
  binary=$(find "$DEST" -path '*ios-arm64*' -path '*/whisper.framework/whisper' -type f | head -n 1)
  if [ -z "$binary" ]; then
    echo "No iOS arm64 whisper binary found in $DEST"
    exit 1
  fi
  echo "Auditing $binary"
  if nm -u "$binary" | grep -E 'NEWLAPACK|ILP64'; then
    echo "whisper contains BLAS symbols unavailable on iOS 15"
    exit 1
  fi
  if otool -L "$binary" | grep -q 'Accelerate.framework'; then
    echo "whisper unexpectedly links Accelerate.framework"
    exit 1
  fi
  xcrun vtool -show-build "$binary"
}

if [ -d "$DEST" ]; then
  echo "Using cached iOS 15 whisper.xcframework"
  audit_framework
  exit 0
fi

if ! command -v cmake >/dev/null 2>&1; then
  brew install cmake
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Cloning whisper.cpp v$VERSION"
git clone --quiet --depth 1 --branch "v$VERSION" \
  https://github.com/ggml-org/whisper.cpp.git "$TMP/whisper.cpp"
cd "$TMP/whisper.cpp"

echo "Building whisper.cpp for arm64 iOS $MIN_IOS without Accelerate/BLAS"
cmake -S . -B build-ios-device -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
  -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_COREML=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_ACCELERATE=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_BLAS_DEFAULT=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_USE_BF16=OFF

cmake --build build-ios-device --config Release --target whisper -- -quiet

RELEASE_DIR="Release-iphoneos"
LIBRARIES=(
  "build-ios-device/src/$RELEASE_DIR/libwhisper.a"
  "build-ios-device/ggml/src/$RELEASE_DIR/libggml.a"
  "build-ios-device/ggml/src/$RELEASE_DIR/libggml-base.a"
  "build-ios-device/ggml/src/$RELEASE_DIR/libggml-cpu.a"
  "build-ios-device/ggml/src/ggml-metal/$RELEASE_DIR/libggml-metal.a"
)
for library in "${LIBRARIES[@]}"; do
  if [ ! -f "$library" ]; then
    echo "Expected static library is missing: $library"
    find build-ios-device -name '*.a' -print
    exit 1
  fi
done

FRAMEWORK="$TMP/whisper.framework"
mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules"
libtool -static -o "$TMP/combined.a" "${LIBRARIES[@]}"

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang++ -dynamiclib \
  -isysroot "$SDK_PATH" \
  -arch arm64 \
  -mios-version-min="$MIN_IOS" \
  -Wl,-force_load,"$TMP/combined.a" \
  -framework Foundation \
  -framework Metal \
  -install_name '@rpath/whisper.framework/whisper' \
  -o "$FRAMEWORK/whisper"

cp include/whisper.h "$FRAMEWORK/Headers/"
cp ggml/include/ggml.h "$FRAMEWORK/Headers/"
cp ggml/include/ggml-alloc.h "$FRAMEWORK/Headers/"
cp ggml/include/ggml-backend.h "$FRAMEWORK/Headers/"
cp ggml/include/ggml-metal.h "$FRAMEWORK/Headers/"
cp ggml/include/ggml-cpu.h "$FRAMEWORK/Headers/"
cp ggml/include/ggml-blas.h "$FRAMEWORK/Headers/"
cp ggml/include/gguf.h "$FRAMEWORK/Headers/"

cat > "$FRAMEWORK/Modules/module.modulemap" <<'EOF'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"
    link "c++"
    link framework "Metal"
    link framework "Foundation"
    export *
}
EOF

cat > "$FRAMEWORK/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>whisper</string>
<key>CFBundleIdentifier</key><string>org.ggml.whisper.ios15</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>whisper</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>$MIN_IOS</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
EOF

rm -rf "$DEST"
xcodebuild -create-xcframework \
  -framework "$FRAMEWORK" \
  -output "$DEST"

audit_framework
echo "Prepared iOS 15 compatible framework at $DEST"
