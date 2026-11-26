/* lsd: the Launch Services database daemon (Mach service com.apple.lsd.mapdb, protocol _LSDReadProtocol), wire-compatible with macOS 26.7.2.
 * Protocol, replies and store format: research/docs/LAUNCHSERVICES-WIRE.md (github.com/pearOS-bsd/research).
 * The database is written by our own code (store/csstore.c, store/lsdb.c, lsd/apps.m) to the place the Mac uses:
 *   <DARWIN_USER_DIR>/com.apple.LaunchServices.dv/com.apple.LaunchServices-20971545-v2.csstore (DARWIN_USER_DIR ends in 0/)
 * and handed to every client by getServerStoreNonBlockingWithCompletionHandler: as the Mac's lsd does (an _CSStore whose XPC representation is the
 * whole file, and the FSNode of the file).  The interface and the classes on the wire (_CSStore, FSNode) come from CoreServices at run time.
 * Our own code (BSD-2-Clause). */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>
#import "../store/lsdb.h"
#import "apps.h"

#define MSG(T, ...) ((T (*)(__VA_ARGS__))objc_msgSend)

static void Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *fmt, ...)
{
	if (!getenv("LSD_LOG")) return;
	va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat: fmt arguments: a]; va_end(a);
	fprintf(stderr, "lsd: %s\n", s.UTF8String);
}

static NSError *OSStatusError(int code, NSString *message)
{
	return [NSError errorWithDomain: NSOSStatusErrorDomain code: code userInfo: message ? @{ @"_LSErrorMessage": message } : nil];
}

/* the database file: where the Mac keeps it, one per user */
static NSString *StorePath(void)
{
	char buf[1024];
	if (getenv("LSD_STORE")) return @(getenv("LSD_STORE"));            /* tests on a Mac, where the real directory is the data vault of Apple's lsd */
	NSString *dir = confstr(_CS_DARWIN_USER_DIR, buf, sizeof buf) ? [@(buf) stringByAppendingPathComponent: @"com.apple.LaunchServices.dv"] : @"/var/db/lsd";
	[[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: @{ NSFilePosixPermissions: @0755 } error: NULL];
	return [dir stringByAppendingPathComponent: [NSString stringWithFormat: @"com.apple.LaunchServices-%u-v2.csstore", LS_SCHEMA_VERSION]];
}

/* the UUID and sequence of a database we wrote before (our layout: the DB Header table is the first table unit, its extra bytes at 0xb4); the UUID stays, the sequence goes on */
static BOOL ReadPrevious(NSString *path, uint8_t uuid[16], uint64_t *seq)
{
	NSData *d = [NSData dataWithContentsOfFile: path options: NSDataReadingMappedIfSafe error: NULL];
	const uint8_t *p = d.bytes;
	uint32_t magic, schema;
	if (d.length < 0xb4 + 0xc0) return NO;
	memcpy(&magic, p, 4); memcpy(&schema, p + 0xb4, 4);
	if (magic != 0x6c736462 || schema != LS_SCHEMA_VERSION) return NO;
	memcpy(seq, p + 0xb4 + 0x80, 8); memcpy(uuid, p + 0xb4 + 0x88, 16);
	return YES;
}

@interface LSDReadService : NSObject <NSXPCListenerDelegate>
@property (copy) NSString *storePath;
@property (strong) NSMutableArray<NSString *> *registered;     /* bundles registered through com.apple.lsd.modifydb, kept in every rebuild */
@property (assign) uint64_t sequence;
- (BOOL)writeDatabase;
@end

@implementation LSDReadService
- (BOOL)writeDatabase
{
	ls_db_info in = { .system_version = { 26, 7, 2, 0 }, .build = "25G332", .model = "/iMac19,1", .xcode = "2416", .created = (uint32_t)time(NULL) };
	uint64_t seq = 0;
	if (ReadPrevious(self.storePath, in.uuid, &seq)) in.sequence = seq + 1;
	else { [[NSUUID UUID] getUUIDBytes: in.uuid]; in.sequence = 1; }
	ls_db *db = ls_db_new(&in);
	if (!db) return NO;
	/* the applications of the system, registered when the database is made (the Mac's lsd seeds its database the same way) */
	uint32_t container = LSDVolumeContainer(db);
	NSArray *dirs = @[ @"/System/Applications", @"/System/Applications/Utilities", @"/System/Library/CoreServices", @"/Applications", @"/Applications/Utilities" ];
	NSUInteger napps = LSDRegisterApplicationsIn(db, dirs, container);
	for (NSString *p in self.registered) if (![dirs containsObject: p.stringByDeletingLastPathComponent] && LSDRegisterApplication(db, p, container)) napps++;	/* the system ones are in already */
	in.sequence = ls_sequence(db);
	self.sequence = in.sequence;
	size_t n = 0;
	uint8_t *b = ls_db_build(db, &n);
	ls_db_free(db);
	if (!b) return NO;
	Log(@"%lu applications registered", (unsigned long)napps);
	NSData *d = [NSData dataWithBytesNoCopy: b length: n freeWhenDone: YES];
	NSString *tmp = [self.storePath stringByAppendingFormat: @".%d", getpid()];
	BOOL ok = [d writeToFile: tmp options: 0 error: NULL] && chmod(tmp.fileSystemRepresentation, 0644) == 0 && rename(tmp.fileSystemRepresentation, self.storePath.fileSystemRepresentation) == 0;
	Log(@"database %@: %lu bytes, sequence %llu: %s", self.storePath, (unsigned long)n, (unsigned long long)in.sequence, ok ? "written" : "FAILED");
	return ok;
}

- (void)getServerStoreNonBlockingWithCompletionHandler:(void (^)(id, id, id, BOOL, NSError *))reply
{
	NSURL *url = [NSURL fileURLWithPath: self.storePath];
	NSError *e = nil;
	id store = MSG(id, id, SEL, id, NSError **)([NSClassFromString(@"_CSStore") alloc], sel_registerName("initWithContentsOfURL:error:"), url, &e);
	id node = MSG(id, id, SEL, id, unsigned, NSError **)([NSClassFromString(@"FSNode") alloc], sel_registerName("initWithURL:flags:error:"), url, 0, NULL);
	Log(@"server store: %@ %@", store ? @"sent" : e, node ? @"" : @"(no FSNode)");
	reply(store, node, nil, NO, store ? nil : e);
}
- (void)getSystemContentStoreWithCompletionHandler:(void (^)(id, id, NSError *))reply { reply(nil, nil, OSStatusError(-10814, @"no system content store")); }
- (void)getServerStatusWithCompletionHandler:(void (^)(unsigned))reply { reply(256); }
- (void)getSystemModeWithCompletionHandler:(void (^)(NSString *, NSError *))reply { reply(nil, nil); }
- (void)getPreferencesWithCompletionHandler:(void (^)(NSDictionary *, NSError *))reply { reply(@{}, nil); }
- (void)getSettingsStoreConfigurationWithCompletionHandler:(void (^)(id, NSError *))reply { reply(nil, OSStatusError(-10814, @"no settings store")); }
- (void)getSelectedDeveloperDirectoryURLWithCompletionHandler:(void (^)(NSURL *))reply { reply(nil); }
- (void)getKernelPackageExtensionsWithCompletionHandler:(void (^)(NSArray *, NSError *))reply { reply(@[ @"app", @"bundle", @"framework", @"plugin", @"kext" ], nil); }
- (void)getApplicationCategoryIdentifiersSetWithCompletionHandler:(void (^)(NSSet *, NSError *))reply { reply([NSSet set], nil); }
- (void)getSessionLanguagesForImproperlyLocalizedProcessWithCompletionHandler:(void (^)(NSArray *))reply { reply(@[]); }
- (void)getEligibilityAnswerForDomain:(unsigned long long)domain withCompletionHandler:(void (^)(NSNumber *, NSError *))reply { reply(nil, OSStatusError(-50, [NSString stringWithFormat: @"Can't ask to evaluate domain %llu", domain])); }
- (void)getCurrentApplicationDefaultInfoForCategory:(unsigned long long)category completion:(void (^)(id, NSError *))reply { reply(nil, OSStatusError(-10814, nil)); }
- (void)mapBundleIdentifiers:(NSSet *)ids orMachOUUIDs:(NSSet *)uuids completionHandler:(void (^)(NSArray *, NSArray *, NSError *))reply { reply(nil, nil, OSStatusError(-54, @"required entitlement missing")); }
- (void)mapPlugInBundleIdentifiersToContainingBundleIdentifiers:(NSSet *)ids completionHandler:(void (^)(NSDictionary *, NSError *))reply { reply(nil, OSStatusError(-54, @"required entitlement missing")); }
- (void)getRedactedAppexRecordForSystemAppexWithUUID:(NSUUID *)u node:(id)node bundleIdentifier:(NSString *)b platform:(unsigned)p completionHandler:(void (^)(id, NSError *))reply { reply(nil, OSStatusError(-10814, nil)); }
- (void)getRedactedPluginProxyForSystemAppexWithUUID:(NSUUID *)u node:(id)node bundleIdentifier:(NSString *)b platform:(unsigned)p completionHandler:(void (^)(id, NSError *))reply { reply(nil, OSStatusError(-10814, nil)); }

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c
{
	NSXPCInterface *i = MSG(id, id, SEL)(NSClassFromString(@"_LSDReadService"), sel_registerName("XPCInterface"));     /* the interface of CoreServices: the class sets of the Mac exactly */
	if (!i) return NO;
	c.exportedInterface = i;
	c.exportedObject = self;
	[c resume];
	Log(@"connection");
	return YES;
}
@end

/* com.apple.lsd.modifydb (_LSDModifyProtocol, research/docs/LAUNCHSERVICES-WIRE.md 2.2): registration of a bundle a client found unregistered rebuilds the
 * database with it (the next getServerStore... returns the new store, its sequence bumped); the other changes are answered with success and not kept yet. */
@interface LSDModifyService : NSObject <NSXPCListenerDelegate>
@property (weak) LSDReadService *db;
@end
@implementation LSDModifyService
- (void)registerItemInfo:(id)info alias:(NSData *)alias diskImageAlias:(NSData *)dia bundleURL:(NSURL *)url installationPlist:(NSDictionary *)plist completionHandler:(void (^)(BOOL, unsigned, NSArray *, BOOL, NSError *))reply
{
	NSString *path = url.path.stringByStandardizingPath;
	BOOL ok = NO;
	if (path.length && [[NSFileManager defaultManager] fileExistsAtPath: [path stringByAppendingPathComponent: @"Contents/Info.plist"]]) {
		if (![self.db.registered containsObject: path]) [self.db.registered addObject: path];
		ok = [self.db writeDatabase];
	}
	Log(@"modify: registerItemInfo %@: %s (sequence %llu)", path, ok ? "registered" : "not a bundle", (unsigned long long)self.db.sequence);
	reply(ok, (unsigned)self.db.sequence, nil, NO, ok ? nil : OSStatusError(-10811, nil));
}
- (void)unregisterBundleUnit:(unsigned)unit options:(unsigned)o completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: unregisterBundleUnit %u", unit); reply(YES, nil); }
- (void)registerContainerURL:(NSURL *)url completionHandler:(void (^)(unsigned, NSError *))reply { Log(@"modify: registerContainerURL %@", url); reply(4, nil); }
/* the Mac's lsd answers with the 24-byte Container record of the volume, current state (captured: 13000100 c42ab430 67456400 00000000 04000000 00000000 for unit 4);
 * a nil answer makes the client ask again and fail.  Ours: the record as it is in our database (all zero: the volume state is not computed yet, fields not decoded) */
- (void)updateContainerUnit:(unsigned)unit completionHandler:(void (^)(NSData *, NSError *))reply { Log(@"modify: updateContainerUnit %u", unit); uint8_t z[24] = { 0 }; reply([NSData dataWithBytes: z length: sizeof z], nil); }
- (void)removeContainer:(unsigned)unit { Log(@"modify: removeContainer %u", unit); }
- (void)registerExtensionPoint:(NSString *)n platform:(unsigned)p declaringURL:(NSURL *)u withInfo:(NSDictionary *)i completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: registerExtensionPoint %@", n); reply(YES, nil); }
- (void)unregisterExtensionPoint:(NSString *)n platform:(unsigned)p withVersion:(NSString *)v parentBundleUnit:(unsigned)b completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: unregisterExtensionPoint %@", n); reply(YES, nil); }
- (void)performPostInstallationRegistration:(NSArray *)a personaUniqueStrings:(NSArray *)ps operationUUID:(NSUUID *)op reply:(void (^)(id, id, NSError *))reply { Log(@"modify: performPostInstallationRegistration"); reply(nil, nil, OSStatusError(-4, nil)); }
- (void)performPostUninstallationUnregistrationOfBundleID:(NSString *)b operationUUID:(NSUUID *)op unregisterType:(unsigned)t precondition:(id)pre reply:(void (^)(id, NSError *))reply { Log(@"modify: performPostUninstallationUnregistration %@", b); reply(nil, OSStatusError(-4, nil)); }
- (void)performUpdateOfPersonasOfBundleIDs:(NSSet *)b toPersonaUniqueStrings:(NSSet *)p operationUUID:(NSUUID *)op reply:(void (^)(id, NSError *))reply { reply(nil, OSStatusError(-4, nil)); }
- (void)updateRecordForApp:(NSString *)b withSINF:(NSDictionary *)s iTunesMetadata:(NSDictionary *)i placeholderMetadata:(NSDictionary *)p sendNotification:(int)n operationUUID:(NSUUID *)op returnSaveToken:(BOOL)t completionHandler:(void (^)(BOOL, id, NSError *))reply { reply(NO, nil, OSStatusError(-4, nil)); }
- (void)setHandler:(NSString *)b version:(struct { unsigned char v[32]; })v forURLScheme:(NSString *)s completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: setHandler %@ for scheme %@", b, s); reply(YES, nil); }
- (void)setHandler:(NSString *)b version:(struct { unsigned char v[32]; })v roles:(unsigned)r forContentType:(NSString *)t completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: setHandler %@ for type %@", b, t); reply(YES, nil); }
- (void)removeHandlerForURLScheme:(NSString *)s completionHandler:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
- (void)removeHandlerForContentType:(NSString *)t roles:(unsigned)r completionHandler:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
- (void)removeAllHandlerPrefsForBundleID:(NSString *)b completionHandler:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
- (void)removeAllHandlersWithCompletionHandler:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
- (void)setPreferenceValue:(id)v forKey:(NSString *)k forApplicationAtURL:(NSURL *)u completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: setPreferenceValue %@", k); reply(YES, nil); }
- (void)setPreferenceValueForCallingApplication:(id)v forKey:(NSString *)k completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: setPreferenceValueForCallingApplication %@", k); reply(YES, nil); }
- (void)setDatabaseIsSeeded:(BOOL)seeded completionHandler:(void (^)(BOOL, NSError *))reply { Log(@"modify: setDatabaseIsSeeded %d", seeded); reply(YES, nil); }
- (void)garbageCollectDatabaseWithCompletionHandler:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
- (void)resetServerStoreWithCompletionHandler:(void (^)(BOOL, NSError *))reply { BOOL ok = [self.db writeDatabase]; reply(ok, nil); }
- (void)removeDatabaseStoreOnNextOpportunity:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
- (void)forceSaveForTestingWithCompletion:(void (^)(NSError *))reply { reply(nil); }
- (void)requestLSDExitSafely:(double)t completionHandler:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
- (void)registerSelf { }
- (void)synchronizeWithMobileInstallation { }
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c
{
	NSXPCInterface *i = MSG(id, id, SEL)(NSClassFromString(@"_LSDModifyService"), sel_registerName("XPCInterface"));
	if (!i) return NO;
	c.exportedInterface = i;
	c.exportedObject = self;
	[c resume];
	Log(@"modify: connection");
	return YES;
}
@end

int main(void)
{
	@autoreleasepool {
		if (!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)) { fprintf(stderr, "lsd: CoreServices: %s\n", dlerror()); return 1; }
		LSDReadService *read = [LSDReadService new];
		read.storePath = StorePath();
		read.registered = [NSMutableArray array];
		if (![read writeDatabase]) fprintf(stderr, "lsd: cannot write the database %s\n", read.storePath.UTF8String);
		NSXPCListener *mapdb = [[NSXPCListener alloc] initWithMachServiceName: @"com.apple.lsd.mapdb"];
		mapdb.delegate = read;
		[mapdb resume];
		LSDModifyService *modify = [LSDModifyService new];
		modify.db = read;
		NSXPCListener *modifydb = [[NSXPCListener alloc] initWithMachServiceName: @"com.apple.lsd.modifydb"];
		modifydb.delegate = modify;
		[modifydb resume];
		[[NSRunLoop currentRunLoop] run];
	}
	return 0;
}
