#!/bin/sh
# Builds libLaunchServicesSupport.dylib on a Mac (to compare it with Apple's): sh build-mac.sh OUTDIR
set -e
OUT="${1:?output directory}"; H="$(cd "$(dirname "$0")" && pwd)"; SDK=$(xcrun --show-sdk-path); mkdir -p "$OUT"
CF="-arch x86_64 -mmacosx-version-min=14.0 -fobjc-arc -fblocks -O2 -Wall -Wno-unused-function -I$H"
for f in Support.m; do clang $CF -c "$H/$f" -o "$OUT/${f%.*}.o"; done
for f in CFSupport.mm QuitSupport.mm; do clang++ $CF -std=gnu++20 -c "$H/$f" -o "$OUT/${f%.*}.o"; done
clang++ -arch x86_64 -mmacosx-version-min=14.0 -dynamiclib -install_name /usr/lib/libLaunchServicesSupport.dylib \
	-compatibility_version 1.0.0 -current_version 1.0.0 -exported_symbols_list "$H/exports.txt" \
	-framework CoreServices -F"$SDK/System/Library/PrivateFrameworks" -framework AppServerSupport -framework BackgroundTaskManagement \
	-framework CoreAnalytics -framework CoreGraphics -framework Foundation -weak-lquit -framework QuartzCore -framework Security \
	-framework SkyLight -lobjc -lc++ -framework CoreFoundation \
	-o "$OUT/libLaunchServicesSupport.dylib" "$OUT/Support.o" "$OUT/CFSupport.o" "$OUT/QuitSupport.o"
