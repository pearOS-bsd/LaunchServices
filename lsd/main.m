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
	in.sequence = ls_sequence(db);
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

int main(void)
{
	@autoreleasepool {
		if (!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)) { fprintf(stderr, "lsd: CoreServices: %s\n", dlerror()); return 1; }
		LSDReadService *read = [LSDReadService new];
		read.storePath = StorePath();
		if (![read writeDatabase]) fprintf(stderr, "lsd: cannot write the database %s\n", read.storePath.UTF8String);
		NSXPCListener *mapdb = [[NSXPCListener alloc] initWithMachServiceName: @"com.apple.lsd.mapdb"];
		mapdb.delegate = read;
		[mapdb resume];
		[[NSRunLoop currentRunLoop] run];
	}
	return 0;
}
