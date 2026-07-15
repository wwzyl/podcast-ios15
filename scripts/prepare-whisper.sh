#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DEST="$VENDOR/whisper.xcframework"
VERSION="1.9.1"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/v${VERSION}/whisper-v${VERSION}-xcframework.zip"

if [ -d "$DEST" ]; then
  echo "whisper.xcframework already exists"
  exit 0
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl --fail --location --retry 5 --retry-delay 3 --output "$TMP/whisper.zip" "$URL"
unzip -q "$TMP/whisper.zip" -d "$TMP/unpacked"
cp -R "$TMP/unpacked/build-apple/whisper.xcframework" "$DEST"
echo "Prepared $DEST"

