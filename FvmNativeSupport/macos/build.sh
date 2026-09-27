#!/bin/bash
set -euo pipefail

# Uses only Apple's Command Line Tools and the system libarchive runtime.
native_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$native_dir/build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/fvm-native-build.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

for architecture in arm64 x86_64; do
  xcrun clang++ -std=c++17 -fobjc-arc -fvisibility=hidden \
    -Wall -Wextra -Werror -Wno-deprecated-declarations -O2 \
    -mmacosx-version-min=11.0 -arch "$architecture" -dynamiclib \
    "$native_dir/FvmNativeSupport.mm" "$native_dir/GameFrameCodec.mm" \
    -I"$native_dir/../FvmNativeSupport" -I"$native_dir/vendor/libarchive" \
    -framework Cocoa -framework ImageIO -framework CoreGraphics -larchive.2 \
    -Wl,-exported_symbols_list,"$native_dir/exports.txt" \
    -install_name @rpath/libFvmNativeSupport.dylib \
    -o "$temporary_dir/FvmNativeSupport.$architecture.dylib"
done
xcrun lipo -create "$temporary_dir/FvmNativeSupport.arm64.dylib" \
  "$temporary_dir/FvmNativeSupport.x86_64.dylib" \
  -output "$output_dir/libFvmNativeSupport.dylib"
codesign --force --sign - --timestamp=none "$output_dir/libFvmNativeSupport.dylib"
xcrun lipo -info "$output_dir/libFvmNativeSupport.dylib"
printf 'Built %s\n' "$output_dir/libFvmNativeSupport.dylib"
