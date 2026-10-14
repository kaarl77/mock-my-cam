#!/usr/bin/env bash
#
# Build VirtualCamera.dylib (the iOS-Simulator camera-injection library) from the
# vendored Objective-C sources in ThirdParty/VirtualCamera/ and place it into the
# MockMyCamKit resource bundle so it ships inside MockMyCam.app.
#
# The sources are vendored from baguette (Apache-2.0) — see
# ThirdParty/VirtualCamera/LICENSE and NOTICE. This script is MockMyCam's own
# authored build (mirrors the upstream build.sh) so we never execute external code.
#
# IMPORTANT: the dylib is adhoc *linker-signed* at link time (-Wl,-adhoc_codesign).
# Do NOT run `codesign --force --sign -` afterwards: iOS 26+ simulator dyld rejects
# post-build ad-hoc signatures with code:codesigning(3) invalid-page(2).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ThirdParty/VirtualCamera/Sources"
OUTDIR="$ROOT/Sources/MockMyCamKit/Resources"
OUT="$OUTDIR/VirtualCamera.dylib"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$OUTDIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

build_slice() {
    local arch="$1"
    xcrun clang \
        -arch "$arch" \
        -isysroot "$SDK" \
        -target "${arch}-apple-ios17.0-simulator" \
        -dynamiclib \
        -framework Foundation -framework UIKit -framework QuartzCore \
        -framework CoreGraphics -framework AVFoundation \
        -framework CoreMedia -framework CoreVideo \
        -framework Vision -framework CoreImage \
        -framework ImageIO -framework CoreServices \
        -fobjc-arc -ldl \
        -install_name "@rpath/VirtualCamera.dylib" \
        -Wl,-adhoc_codesign \
        -I "$SRC" \
        -o "$tmp/VirtualCamera.${arch}.dylib" \
        "$SRC/SimCamInject.m" \
        "$SRC/SimCamPreviewLayerDriver.m" \
        "$SRC/SimCamSampleBufferDriver.m" \
        "$SRC/SimCamCaptureShim.m" \
        "$SRC/SimCamVisionShim.m" \
        "$SRC/SimCamMetadataShim.m" \
        "$SRC/SimCamFakePhoto.m" \
        "$SRC/SimCamSharedFrameReader.m"
}

build_slice arm64
build_slice x86_64

xcrun lipo -create \
    "$tmp/VirtualCamera.arm64.dylib" \
    "$tmp/VirtualCamera.x86_64.dylib" \
    -output "$OUT"

echo "Built: $OUT"
echo "  archs: $(lipo -archs "$OUT")"
codesign -dvv "$OUT" 2>&1 | grep -iE "flags|adhoc" || true
