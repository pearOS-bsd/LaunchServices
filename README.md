# LaunchServices

Icons (`LSIcon`, icns reader), the uniform type table (`uti_table.json`) and the default desktop pictures.

## lsd (the Launch Services database daemon), wire-compatible with macOS 26.7.2
Protocols, replies and the store format: `research/docs/LAUNCHSERVICES-WIRE.md` (github.com/pearOS-bsd/research).

| part | what |
|---|---|
| `store/csstore.[ch]` | writer of the CSStore2 container (units, tables, id maps, catalog, header and CRC) |
| `store/lsdb.[ch]` | the Launch Services schema: the DB Header (schema 0x01400019, sequence, database UUID) and the 33 tables of 26.7.2 |
| `lsd/main.m` | `lsd`: `com.apple.lsd.mapdb` (`_LSDReadProtocol`, the 15 methods with the replies of the Mac); writes the database to `<DARWIN_USER_DIR>/0/com.apple.LaunchServices.dv/com.apple.LaunchServices-20971545-v2.csstore` and hands it to clients as an `_CSStore` + `FSNode` like the Mac's lsd |
| `lsd/apps.m` | registration of an application: the Bundle record (588 bytes), its Alias (CFURL bookmark data), Info.plist and icon property lists (compacted like the Mac's), the bindings (bundle id, names, activity types); the system applications are registered when the database is made |
| `lsd/commonstrings.m` | the common strings of the property list compaction, read at run time from the LaunchServices image in the process (never stored here) |
| `test/empty_store.c` | `make -f Makefile.lsd check`: an empty store |

Checked (2026-11-26):
- The C writer produces the same bytes as `research/tools/launchservices/make_empty_store.py` (which Apple's `_CSStore` reader opens).
- Mac VM, Apple's client against our `lsd` (service name redirected for the test process with `IconServices/test/redirect.c`): `+[LSRecord _is_getSequenceNumber:andUUID:]` (the call of IconServices) takes our database and returns our UUID; `+[LSBundleRecord bundleRecordWithBundleIdentifier:]` answers `kLSApplicationNotFoundErr` (no records yet). Open: the sequence number read back is 0 while the header says 1.
- pearOS (ISO of 2026-11-20, `build-bsd.sh`, started as root next to the image's stack): our Dock gets the database from our `lsd` and goes past Launch Services; IconServices then generates its first icon (the Trash, `ISIcnsIcon` 58 pt) and the Dock receives it. Finder's icon comes back empty: Apple's recipe needs the Finder's Bundle record (the database has none yet).
- 2026-11-27, records: the store now has the 8 binding class names, the persisted string cache, immediate short strings, string bindings and Bundle records (byte-identical to research `lsbuild.py` for the same input). Mac VM, Apple's client against our lsd (182 applications of /System/Applications, CoreServices, /Applications registered): the database is accepted (sequence 729 and our UUID come back), `LSBundleRecord bundleRecordWithBundleIdentifier: com.apple.calculator` finds it with its URL, `LSCopyDisplayNameForURL` gives "Calculator", and IconServices' recipe renders its icon from the record.
Next: Bundle records from the bundles on disk (`registerItemInfo` of `com.apple.lsd.modifydb`), Claim / Type records, `launchservicesd`.

## libLaunchServicesSupport.dylib (Apple's private `/usr/lib/libLaunchServicesSupport.dylib`, macOS 26.7.2)
ABI-compatible replacement: same install name (compatibility / current version 1.0.0), the same 78 x86_64 exports (`libLaunchServicesSupport/exports.txt`),
the same linked libraries in the same order, the same behaviour. Only Dock (`_LSForceQuitApplication`, `_kLSForceQuitApplicationPresentFirstForceQuitDialogKey`)
and loginwindow (those and `_LSRegisterAsQuitReallyHelperClient`) link it. Evidence per symbol: `research/docs/LAUNCHSERVICESSUPPORT.md`.

| part | what |
|---|---|
| `libLaunchServicesSupport/QuitSupport.mm` | `_LSForceQuitApplication` (libquit `LQReportHang`, coalition SIGTERM, proc-exit source, SIGKILL after 3 s, `_LSApplicationQuitting`), `_LSRegisterAsQuitReallyHelperClient` (entitlement checks, os_state handlers, BTM force-quit handler), `_LSSysdiagnoseStatus`, `_LSApplicationHasAVisibleWindowOrContext` (SkyLight accessibility report), classes `LSExitedApplication` and `BTMManagerSupport` |
| `libLaunchServicesSupport/CFSupport.mm` | the C++ CF helpers (`asString`, `CFArray*`, `CFDictionary*`, `CFSet*`, hex, `processName` ...), with Apple's odd corners kept |
| `libLaunchServicesSupport/Support.m` | the 21 `_LS…Log` getters (`com.apple.launchservices`), version symbols, `loggableURL`, `backtraceString` |
| `libLaunchServicesSupport/build-bsd.sh` | build on FreeBSD (clang + ld64.lld, llvm-project libc++ headers = the Mac's libc++ ABI, text stubs, `compat/` for missing headers; `compat/os/log.h` emits real `_os_log_impl` calls) |
| `libLaunchServicesSupport/build-mac.sh` | build on a Mac (to compare) |
| `test/lsss_check.mm` | loads Apple's dylib and ours and compares 203 results (exports, logs, CF helpers, ObjC metadata, the quit entry points, a force quit of an app the test starts) |

Checked 2026-11-27 on the Mac VM (26.7.2): 203/203 equal for the Mac build and for the dylib built on FreeBSD; the unified-log lines of a force quit are the same.
Not yet run on the pearOS ISO.

    sh libLaunchServicesSupport/build-bsd.sh OUT          # FreeBSD, SDK_WORK=/root/oss
    sh libLaunchServicesSupport/build-mac.sh OUT          # Mac
    clang++ -std=gnu++20 -fobjc-arc test/lsss_check.mm -framework Foundation -framework AppKit -framework CoreServices -framework Security -o lsss_check
    ./lsss_check /usr/lib/libLaunchServicesSupport.dylib OUT/ours-test.dylib   # ours copied with install_name_tool -id /tmp/x.dylib

The launchd jobs (`launchd/*.plist`, the format of the Mac's; on pearOS the launchd of `d` reads them, `@USER@` is the console user, put in by rc.d/wsbsd_macstack of the image): the agent and lsd run as the user and start on demand, like the Mac's per-user jobs.
