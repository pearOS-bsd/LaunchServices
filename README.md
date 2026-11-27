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
Next: Bundle records from the bundles on disk (`registerItemInfo` of `com.apple.lsd.modifydb`), Claim / Type records.

## launchservicesd (the Launch Services session daemon, `com.apple.coreservices.launchservicesd`), wire-compatible with macOS 26.7.2
Plain XPC dictionaries (`command` + `session`, every reply has `success`); one daemon for all sessions, running as root like the Mac's (`launchd/com.apple.coreservices.launchservicesd.plist`, installed as `/usr/libexec/pearos/launchservicesd`).
Protocol, page layout, notification codes and the replies of the Mac's daemon it was compared with: `research/docs/LAUNCHSERVICES-WIRE.md` 6.1-6.6.

| part | what |
|---|---|
| `launchservicesd/launchservicesd.c` | per session (the caller's audit session; pearOS: 100000 + uid): the shared info page (0xf000 bytes, version 0x104, written in place under the lock count, 72-byte records with ASN, ChangeCount, flags, front-to-back position, pid, pid version, `CFHash` of the bundle id and the display name, device/inode of bundle and executable, the seeds), the application records (500/501 check-in, 505, 360, 510 with the special keys, 520, 590, death through the `deathport` and a process-exit source), front application and menu bar owner (300, 910/920 for root and `_windowserver` only, as the Mac), lists (310/320/330/331), meta information (200/210), launch modifiers (370/380/600), death information (700), notification listeners (400/410/420) and the notifications the Mac sends (Creation, Birth, stopped state, key added/changed, RegisteredForCGEvents, Ready, BringForwardRequest, Became/LostFrontmost, MenuBarAcquired/Lost, Hidden/Shown, TypeChanged, NameChanged, Death, Exited), and the Mac's answer (`success` false) to every other command |
| `launchservicesd/compat/lsvd_xpc.h` | the libxpc declarations for the FreeBSD build (the open header tree has no `<xpc/xpc.h>`) |
| `test/lsvd_check.c` | 29 checks of a daemon (check-in, page read live, record keys, 505/360/510/520/590, listener and its notifications, lists, meta, refusals); passes against the Mac's own daemon and against ours |
| `test/launchd/com.pearos.t.lsd.plist` | a test job (service `com.pearos.t.lsd`, log to `/tmp/lsvd-test.err` with `LSVD_LOG=1`) |

    make -f Makefile.lsd build/launchservicesd     # macOS
    sh build-bsd.sh OUT                            # FreeBSD: OUT/lsd and OUT/launchservicesd
    __LSXPCSERVICENAME=com.pearos.t.lsd ./lsvd_check

Environment: `LSVD_SERVICE_NAME` (another Mach service name, for tests), `LSVD_LOG=1` (every request and reply on stderr), `LSVD_CGS_SESSION` (the CGS session id in the page, default 0x101).

Checked 2026-11-27 on the Mac VM (26.7.2, SIP on; ours as a system LaunchDaemon `com.pearos.t.lsd`, the clients pointed at it with `__LSXPCSERVICENAME`):
- The same 30 requests and a 410 listener against Apple's daemon and ours (`research/tools/launchservices/probes/lsvd-compare.sh`): after normalizing addresses, ASNs, pids and times the transcripts are equal except the session number (Apple maps an ssh client to the console session 100001, ours uses the audit session), the numbering of a 120 ASN, and one 0x203 BringForwardRequest that ours sends because nothing was in front (on the Mac Terminal was). The binary built on FreeBSD (`build-bsd.sh`) gives the same result on the Mac.
- Apple's client against ours (`probes/lsc.m`): AppKit checks in, `_LSCopyApplicationInformation` (whole and restricted), `_LSCopyFrontApplication`, `_LSCopyApplicationArrayInFrontToBackOrder`, `_LSCopyMetaApplicationInformation`, `NSRunningApplication`, and `NSWorkspaceDidTerminateApplicationNotification` for an application that quits (decoded by Apple's client from our Death notification) - the same as with Apple's daemon.
- The info page decoded with `research/tools/launchservices/infopage.py`: header, records and flags as the Mac's for the same steps.
- `test/lsvd_check`: 29/29 against Apple's daemon and against ours.
Not checked: pearOS itself (the lab VM has no darwinator stack); 450 positive path, 501, 597/610 with a pending launch, coalitions, RunningBoard, activation tokens (1000-1030), named connections (595/596), reconnection (598/599).

`d/darwin/lsd-stub` still serves the other names it is given; started without names (as launchservicesd) it leaves `com.apple.coreservices.launchservicesd` alone when `/usr/libexec/pearos/launchservicesd` is installed.

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
