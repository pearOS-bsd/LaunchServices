#!/bin/sh
# Builds lsd ON FreeBSD (pearOS), without a Mac: clang for x86_64-apple-macosx + ld64.lld, the open header tree of dyld/tools/sdk,
# compat/LSCompat.h for what it lacks, text-stub frameworks (install names only: the symbols bind at run time to the frameworks dyld finds), -undefined dynamic_lookup.
#   sh build-bsd.sh OUTDIR      SDK_WORK (default /root/oss) = where dyld/tools/sdk was run; ../darwinator (macho-toolchain: libSystem / libobjc stubs) next to this repository
set -e
OUT="${1:?output directory}"; H="$(cd "$(dirname "$0")" && pwd)"; P="$(dirname "$H")"; W="${SDK_WORK:-/root/oss}"; I="$W/sdk/usr/include"
RES=$(ls -d /usr/local/llvm*/lib/clang/*/include 2>/dev/null | tail -1); LD=$(ls /usr/local/llvm*/bin/ld64.lld 2>/dev/null | tail -1)
rm -rf "$OUT/ravyn"; mkdir -p "$OUT/o" "$OUT/fw"
# CGFloat is a double on 64 bits (Apple); ravynOS' headers say float, in the typedef and in the prototypes
cp -R "$W/sdk/ravyn" "$OUT/ravyn"; grep -rl "typedef float CGFloat;" "$OUT/ravyn" | while read f; do sed -i.bak "s/typedef float CGFloat;/typedef double CGFloat;/" "$f"; rm -f "$f.bak"; done
python3 - "$OUT/ravyn/CoreGraphics" <<'PY'
import re, sys, glob
for f in glob.glob(sys.argv[1] + "/*.h"):
    s = open(f, errors="replace").read()
    t = "\n".join(l if re.search(r"typedef (float|double) CGFloat;", l) else re.sub(r"\bfloat\b", "CGFloat", l) for l in s.split("\n"))
    if t != s: open(f, "w").write(t)
PY
T="--target=x86_64-apple-macosx14.0 -DXNU_PLATFORM_MacOSX -nostdinc -isystem $RES -isystem $I"
OBJC="$T -x objective-c -fobjc-runtime=macosx-14.0 -fobjc-arc -Wno-everything -Werror=implicit-function-declaration -Werror=int-conversion -O1 -isystem $OUT/ravyn -isystem $W/sdk/stubs -I$H/compat -include $H/compat/LSCompat.h"
ERR=0
o="$OUT/o/lsd.o"; clang $OBJC -c "$H/lsd/main.m" -o "$o" 2>"$o.err" || { ERR=1; echo "== lsd"; grep error "$o.err" | head -30; }
for f in csstore lsdb; do clang $T -std=gnu11 -Wno-everything -O1 -c "$H/store/$f.c" -o "$OUT/o/$f.o" || ERR=1; done
[ $ERR = 0 ] || { echo "compile errors"; exit 1; }
for n in Foundation CoreFoundation; do
	V=A; [ $n = Foundation ] && V=C; mkdir -p "$OUT/fw/$n.framework"; printf -- "--- !tapi-tbd\ntbd-version:     4\ntargets:         [ x86_64-macos ]\ninstall-name:    '/System/Library/Frameworks/$n.framework/Versions/$V/$n'\ncurrent-version: 1\nexports:\n  - targets:         [ x86_64-macos ]\n    symbols:         []\n...\n" > "$OUT/fw/$n.framework/$n.tbd"; done
L="-arch x86_64 -platform_version macos 14.0 14.0 -undefined dynamic_lookup -F$OUT/fw -L$P/darwinator/tests/macho-toolchain -L$P/darwinator/tests/macho-toolchain/objc -lSystem -lobjc"
$LD $L -framework Foundation -framework CoreFoundation -o "$OUT/lsd" "$OUT/o/lsd.o" "$OUT/o/csstore.o" "$OUT/o/lsdb.o"
file "$OUT/lsd" | cut -c1-110
