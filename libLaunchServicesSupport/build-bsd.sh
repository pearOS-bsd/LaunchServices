#!/bin/sh
# Builds libLaunchServicesSupport.dylib ON FreeBSD (pearOS), without a Mac: clang for x86_64-apple-macosx + ld64.lld, the open header
# tree of dyld/tools/sdk (SDK_WORK, default /root/oss) with ravynOS' Foundation/CoreGraphics headers, the libc++ headers of
# llvm-project (SDK_WORK/llvm-libcxx, config in SDK_WORK/libcxx-cfg: the same libc++ ABI as the Mac's /usr/lib/libc++.1.dylib),
# compat/ for the few headers the tree lacks, text stubs for the libraries Apple's dylib links (install names only:
# the symbols bind at run time, -undefined dynamic_lookup), and exports.txt (exactly Apple's 78 x86_64 exports).
#   sh build-bsd.sh OUTDIR        needs ../../darwinator (macho-toolchain: libSystem / libobjc stubs)
set -e
OUT="${1:?output directory}"; H="$(cd "$(dirname "$0")" && pwd)"; R="$(dirname "$(dirname "$H")")"; W="${SDK_WORK:-/root/oss}"; I="$W/sdk/usr/include"
RES=$(ls -d /usr/local/llvm*/lib/clang/*/include 2>/dev/null | tail -1); LD=$(ls /usr/local/llvm*/bin/ld64.lld 2>/dev/null | tail -1)
CC=$(ls /usr/local/llvm*/bin/clang 2>/dev/null | tail -1); [ -n "$CC" ] || CC=clang
mkdir -p "$OUT/o" "$OUT/fw" "$OUT/lib"
if [ ! -d "$OUT/ravyn" ]; then
	# CGFloat is a double on 64 bits (Apple); ravynOS' headers say float (same fix as ../build-bsd.sh)
	cp -R "$W/sdk/ravyn" "$OUT/ravyn"; grep -rl "typedef float CGFloat;" "$OUT/ravyn" | while read f; do sed -i.bak "s/typedef float CGFloat;/typedef double CGFloat;/" "$f"; rm -f "$f.bak"; done
fi
T="--target=x86_64-apple-macosx14.0 -DXNU_PLATFORM_MacOSX -nostdinc -fblocks -fobjc-runtime=macosx-14.0 -fobjc-arc -O2 -Wno-everything -Werror=implicit-function-declaration -Werror=int-conversion"
INC="-I$H -isystem $H/compat -include $H/compat/LSFoundationCompat.h -isystem $RES -isystem $I -isystem $OUT/ravyn -isystem $W/sdk/stubs"
CXX="-x objective-c++ -std=gnu++20 -nostdinc++ -isystem $W/libcxx-cfg -isystem $W/llvm-libcxx/libcxx/include -isystem $W/llvm-libcxx/libcxxabi/include"
$CC $T $INC -x objective-c -c "$H/Support.m" -o "$OUT/o/Support.o"
for f in CFSupport QuitSupport; do $CC $T $CXX $INC -c "$H/$f.mm" -o "$OUT/o/$f.o"; done
stub() { # stub DIR NAME INSTALL-NAME CURRENT COMPAT
	mkdir -p "$1"; printf -- "--- !tapi-tbd\ntbd-version:     4\ntargets:         [ x86_64-macos ]\ninstall-name:    '%s'\ncurrent-version: %s\ncompatibility-version: %s\nexports:\n  - targets:         [ x86_64-macos ]\n    symbols:         []\n...\n" "$3" "$4" "$5" > "$1/$2.tbd"; }
F=/System/Library/Frameworks; P=/System/Library/PrivateFrameworks
stub "$OUT/fw/CoreServices.framework" CoreServices $F/CoreServices.framework/Versions/A/CoreServices 1226 1
stub "$OUT/fw/AppServerSupport.framework" AppServerSupport $P/AppServerSupport.framework/Versions/A/AppServerSupport 3102.160.5 1
stub "$OUT/fw/BackgroundTaskManagement.framework" BackgroundTaskManagement $P/BackgroundTaskManagement.framework/Versions/A/BackgroundTaskManagement 104 1
stub "$OUT/fw/CoreAnalytics.framework" CoreAnalytics $P/CoreAnalytics.framework/Versions/A/CoreAnalytics 1 1
stub "$OUT/fw/CoreGraphics.framework" CoreGraphics $F/CoreGraphics.framework/Versions/A/CoreGraphics 1965.102.1 64
stub "$OUT/fw/Foundation.framework" Foundation $F/Foundation.framework/Versions/C/Foundation 5026.6.7 300
stub "$OUT/fw/QuartzCore.framework" QuartzCore $F/QuartzCore.framework/Versions/A/QuartzCore 1195.17.2 1.2
stub "$OUT/fw/Security.framework" Security $F/Security.framework/Versions/A/Security 61901.160.44 1
stub "$OUT/fw/SkyLight.framework" SkyLight $P/SkyLight.framework/Versions/A/SkyLight 600 64
stub "$OUT/fw/CoreFoundation.framework" CoreFoundation $F/CoreFoundation.framework/Versions/A/CoreFoundation 5026.6.7 150
stub "$OUT/lib" libquit /usr/lib/libquit.dylib 1 1
stub "$OUT/lib" libc++ /usr/lib/libc++.1.dylib 2100.43 1
M="$R/darwinator/tests/macho-toolchain"
$LD -arch x86_64 -platform_version macos 14.0 14.0 -dylib -install_name /usr/lib/libLaunchServicesSupport.dylib \
	-compatibility_version 1.0.0 -current_version 1.0.0 -exported_symbols_list "$H/exports.txt" -undefined dynamic_lookup \
	-F"$OUT/fw" -L"$OUT/lib" -L"$M" -L"$M/objc" \
	-framework CoreServices -framework AppServerSupport -framework BackgroundTaskManagement -framework CoreAnalytics -framework CoreGraphics \
	-framework Foundation -weak-lquit -framework QuartzCore -framework Security -framework SkyLight -lobjc -lc++ -lSystem -framework CoreFoundation \
	-o "$OUT/libLaunchServicesSupport.dylib" "$OUT/o/Support.o" "$OUT/o/CFSupport.o" "$OUT/o/QuitSupport.o"
file "$OUT/libLaunchServicesSupport.dylib" | cut -c1-120
