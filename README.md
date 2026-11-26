# LaunchServices

Icons (`LSIcon`, icns reader), the uniform type table (`uti_table.json`) and the default desktop pictures.

## lsd (the Launch Services database daemon), wire-compatible with macOS 26.7.2
Protocols, replies and the store format: `research/docs/LAUNCHSERVICES-WIRE.md` (github.com/pearOS-bsd/research).

| part | what |
|---|---|
| `store/csstore.[ch]` | writer of the CSStore2 container (units, tables, id maps, catalog, header and CRC) |
| `store/lsdb.[ch]` | the Launch Services schema: the DB Header (schema 0x01400019, sequence, database UUID) and the 33 tables of 26.7.2 |
| `lsd/main.m` | `lsd`: `com.apple.lsd.mapdb` (`_LSDReadProtocol`, the 15 methods with the replies of the Mac); writes the database to `<DARWIN_USER_DIR>/0/com.apple.LaunchServices.dv/com.apple.LaunchServices-20971545-v2.csstore` and hands it to clients as an `_CSStore` + `FSNode` like the Mac's lsd |
| `test/empty_store.c` | `make -f Makefile.lsd check`: an empty store |

Checked (2026-11-26):
- The C writer produces the same bytes as `research/tools/launchservices/make_empty_store.py` (which Apple's `_CSStore` reader opens).
- Mac VM, Apple's client against our `lsd` (service name redirected for the test process with `IconServices/test/redirect.c`): `+[LSRecord _is_getSequenceNumber:andUUID:]` (the call of IconServices) takes our database and returns our UUID; `+[LSBundleRecord bundleRecordWithBundleIdentifier:]` answers `kLSApplicationNotFoundErr` (no records yet). Open: the sequence number read back is 0 while the header says 1.
- pearOS (ISO of 2026-11-20, `build-bsd.sh`, started as root next to the image's stack): our Dock gets the database from our `lsd` and goes past Launch Services; IconServices then generates its first icon (the Trash, `ISIcnsIcon` 58 pt) and the Dock receives it. Finder's icon comes back empty: Apple's recipe needs the Finder's Bundle record (the database has none yet).
Next: Bundle records from the bundles on disk (`registerItemInfo` of `com.apple.lsd.modifydb`), Claim / Type records, `launchservicesd`.
