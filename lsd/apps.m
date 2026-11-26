/* Registration of an application in the Launch Services database: the Bundle record (588 bytes), its Alias (CFURL bookmark data), its strings, property lists and
 * bindings, shaped like what the Mac's lsd writes.  Layout and evidence: research/docs/LAUNCHSERVICES-WIRE.md 5.6, 5.10-5.13 (and tools/launchservices/lsapp.py,
 * the research writer this follows field by field).  Claims, types, services and plugins are not written yet.  Our own code (BSD-2-Clause). */
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import "../store/lsdb.h"
#import "apps.h"

NSArray<NSString *> *LSDCommonStrings(void);

#define CF_EPOCH 978307200
#define REVISION 0xb                       /* Bundle.revision lsd writes (544): bundleRecordWithURL: ignores a record with another revision */
#define FLAG_TMP (1ull << 47)              /* _bundleFlags: the bundle is below a temporary directory: identifier look-ups skip it */
#define CLASS_APPLICATION 2

static void p32(uint8_t *b, size_t o, uint32_t v) { memcpy(b + o, &v, 4); }
static void p64(uint8_t *b, size_t o, uint64_t v) { memcpy(b + o, &v, 8); }

/* _LSPlistCompactString: a string of the common list becomes its short form (base-64 digits of its index, least significant first); a string that already looks like a
 * short form, or starts with U+0008, gets U+0008 in front; anything else stays */
static NSString *Abbreviation(NSUInteger n)
{
	static const char alpha[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ~!@#$%^&*()_";
	NSMutableString *s = [NSMutableString string];
	for (;;) { [s appendFormat: @"%c", alpha[n & 63]]; if (n < 64) return s; n >>= 6; }
}
static NSString *Compact(NSString *x)
{
	static NSDictionary<NSString *, NSNumber *> *index;
	static NSSet *shorts;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableDictionary *m = [NSMutableDictionary dictionary]; NSMutableSet *sh = [NSMutableSet set];
		NSArray *common = LSDCommonStrings();
		[common enumerateObjectsUsingBlock: ^(NSString *s, NSUInteger i, BOOL *stop) { if (!m[s]) m[s] = @(i); }];
		for (NSUInteger i = 0; i < 256; i++) [sh addObject: Abbreviation(i)];
		index = m; shorts = sh;
	});
	if (x.length && ([x characterAtIndex: 0] == 8 || [shorts containsObject: x])) return [@"\b" stringByAppendingString: x];
	NSNumber *i = index[x];
	return i ? Abbreviation(i.unsignedIntegerValue) : x;
}
static id CompactPlist(id o)
{
	if ([o isKindOfClass: [NSDictionary class]]) { NSMutableDictionary *m = [NSMutableDictionary dictionary]; [o enumerateKeysAndObjectsUsingBlock: ^(id k, id v, BOOL *stop) { m[[k isKindOfClass: [NSString class]] ? Compact(k) : k] = CompactPlist(v); }]; return m; }
	if ([o isKindOfClass: [NSArray class]]) { NSMutableArray *a = [NSMutableArray array]; for (id v in o) [a addObject: CompactPlist(v)]; return a; }
	if ([o isKindOfClass: [NSString class]]) return Compact(o);
	return o;
}
static uint32_t PlistUnit(ls_db *db, id obj)
{
	if (!obj) return 0;
	NSData *d = [NSPropertyListSerialization dataWithPropertyList: CompactPlist(obj) format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL];
	if (!d) return 0;
	NSMutableData *u = [NSMutableData dataWithBytes: "lnch" length: 4];
	[u appendData: d];
	return ls_unit(db, LS_T_PROPERTYLIST, u.bytes, u.length);
}
static uint32_t S(ls_db *db, NSString *s) { return s.length ? ls_string(db, s.UTF8String) : 0; }
static uint32_t StringArray(ls_db *db, NSArray<NSString *> *a)
{
	uint32_t ids[64]; size_t n = 0;
	for (NSString *s in a) if (n < 64) ids[n++] = S(db, s);
	return ls_array(db, ids, n);
}
static void Version(uint8_t *b, size_t o, NSString *s)
{
	NSArray *parts = [s componentsSeparatedByString: @"."];
	for (NSUInteger i = 0; i < 3; i++) p64(b, o + 8 * i, i < parts.count ? (uint64_t)[parts[i] longLongValue] : 0);
	p64(b, o + 24, 0);
}

uint32_t LSDVolumeContainer(ls_db *db)
{
	uint8_t z[24] = { 0 };                /* one all-zero Container is enough in a database of our own (5.12): call once per database */
	return ls_unit(db, LS_T_CONTAINER, z, sizeof z);
}

uint32_t LSDRegisterApplication(ls_db *db, NSString *path, uint32_t container)
{
	NSString *real = [path stringByResolvingSymlinksInPath];
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile: [real stringByAppendingPathComponent: @"Contents/Info.plist"]];
	NSString *bid = info[@"CFBundleIdentifier"], *exe = info[@"CFBundleExecutable"] ?: @"";
	struct stat st, est;
	if (!bid.length || stat(real.fileSystemRepresentation, &st) != 0) return 0;
	NSString *exepath = [real stringByAppendingPathComponent: [@"Contents/MacOS" stringByAppendingPathComponent: exe]];
	if (stat(exepath.fileSystemRepresentation, &est) != 0) est = st;
	BOOL tmp = [real hasPrefix: @"/private/tmp"] || [real hasPrefix: @"/private/var/tmp"] || [real hasPrefix: @"/private/var/folders"] || [real hasPrefix: @"/tmp/"];
	int32_t now = (int32_t)(time(NULL) - CF_EPOCH);
	uint64_t seq = ls_sequence(db) + 4;

	/* the Alias: CFURL bookmark data of the bundle (made by CoreFoundation itself, like the Mac's lsd) */
	NSData *bm = [[NSURL fileURLWithPath: path isDirectory: YES] bookmarkDataWithOptions: 0 includingResourceValuesForKeys: nil relativeToURL: nil error: NULL];
	uint8_t b[588] = { 0 };
	if (bm) p32(b, 0, ls_unit(db, LS_T_ALIAS, bm.bytes, bm.length));
	p32(b, 4, container);
	p32(b, 8, S(db, [@"Contents/MacOS/" stringByAppendingString: exe])); p32(b, 12, S(db, bid));
	p32(b, 24, 1); p32(b, 28, (uint32_t)now);                                          /* platform (1 = macOS), registration time */
	Version(b, 32, info[@"CFBundleVersion"]);
	p32(b, 104, S(db, info[@"CFBundleName"])); p32(b, 112, S(db, info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"]));
	p32(b, 124, PlistUnit(db, info));
	b[136] = tmp ? 0xff : ([real hasPrefix: @"/System/"] ? 1 : 0);                      /* containingDirectoryClass */
	p32(b, 148, CLASS_APPLICATION);
	p64(b, 152, 2 | (tmp ? FLAG_TMP : 0));
	p32(b, 160, 0x10000); p32(b, 164, 0x10008a);                                       /* itemFlags: lsd writes 0x10008e; with bit 0x4 an identifier look-up failed (research 5.12, U9) */
	p32(b, 168, 0x05010005); p32(b, 172, 0x05010101); p32(b, 176, 5);
	const char *ptype = [[info[@"CFBundlePackageType"] description] UTF8String] ?: "APPL", *sig = [[info[@"CFBundleSignature"] description] UTF8String] ?: "????";
	for (int i = 0; i < 4; i++) {                                                        /* four-char codes, big-endian in a little-endian u32 */
		b[184 + 3 - i] = i < (int)strlen(ptype) ? (uint8_t)ptype[i] : '?';
		b[188 + 3 - i] = i < (int)strlen(sig) ? (uint8_t)sig[i] : '?';
	}
	p64(b, 192, (uint64_t)st.st_ino); p64(b, 200, (uint64_t)est.st_ino);
	p32(b, 208, (uint32_t)(int32_t)(st.st_mtime - CF_EPOCH));                          /* must equal the bundle's mtime: bundleRecordWithURL: compares it */
	p32(b, 212, 1);
	p32(b, 280, (uint32_t)st.st_uid); p32(b, 284, (uint32_t)(int32_t)(est.st_mtime - CF_EPOCH));
	p64(b, 320, seq);
	p32(b, 340, S(db, bid.lowercaseString));                                            /* identifier: lower case (exactIdentifier at 12 keeps the case) */
	p32(b, 360, S(db, real.lastPathComponent.lowercaseString)); p32(b, 364, S(db, [info[@"CFBundleVersion"] description])); p32(b, 368, S(db, [info[@"CFBundleShortVersionString"] description]));
	NSString *icon = info[@"CFBundleIconFile"], *iname = info[@"CFBundleIconName"];
	if (icon.length || iname.length) {
		p32(b, 480, S(db, iname.length ? iname : icon));
		NSMutableDictionary *prim = [NSMutableDictionary dictionary];
		if (icon.length) prim[@"CFBundleIconFile"] = icon;
		if (iname.length) prim[@"CFBundleIconName"] = iname;
		p32(b, 484, PlistUnit(db, @{ @"CFBundlePrimaryIcon": prim }));          /* NOT the flat form: ISBundleIcon reads CFBundlePrimaryIcon */
		if (icon.length) {
			NSString *rel = [@"Contents/Resources" stringByAppendingPathComponent: [icon.pathExtension isEqualToString: @"icns"] ? icon : [icon stringByAppendingPathExtension: @"icns"]];
			if ([[NSFileManager defaultManager] fileExistsAtPath: [real stringByAppendingPathComponent: rel]]) p32(b, 488, StringArray(db, @[ rel ]));
		}
	}
	NSMutableArray *acts = [NSMutableArray arrayWithObject: [@"NOTIFICATION#:" stringByAppendingString: bid]];
	for (id a in info[@"NSUserActivityTypes"]) if ([a isKindOfClass: [NSString class]]) [acts addObject: a];
	p32(b, 532, StringArray(db, acts));
	for (size_t i = 0, o[] = { 344, 348, 500, 520, 536 }; i < 5; i++) p32(b, o[i], ls_array(db, NULL, 0));
	b[544] = REVISION; p32(b, 560, (uint32_t)now);
	uint32_t unit = ls_unit(db, LS_T_BUNDLE, b, sizeof b);
	if (!unit) return 0;
	ls_bind(db, LS_T_BUNDLEIDBINDING, S(db, bid.lowercaseString), unit);
	ls_bind(db, LS_T_BUNDLENAMEBINDING, S(db, real.lastPathComponent.lowercaseString), unit);
	if ([info[@"CFBundleName"] length]) ls_bind(db, LS_T_BUNDLENAMEBINDING, S(db, info[@"CFBundleName"]), unit);
	for (NSString *a in acts) ls_bind(db, LS_T_ACTIVITYTYPEBINDING, S(db, a), unit);
	ls_set_sequence(db, seq);
	return unit;
}

NSUInteger LSDRegisterApplicationsIn(ls_db *db, NSArray<NSString *> *dirs, uint32_t container)
{
	NSUInteger n = 0;
	for (NSString *dir in dirs)
		for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath: dir error: NULL])
			if ([name.pathExtension isEqualToString: @"app"] && LSDRegisterApplication(db, [dir stringByAppendingPathComponent: name], container)) n++;
	return n;
}
