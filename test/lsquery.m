/* Test (pearOS and macOS): asks Launch Services for an application by identifier and by URL, then runs IconServices' recipe for its icon in this process.
 *   lsquery BUNDLE-ID /path/App.app [points]
 *   lsquery -b PATH   makes CFURL bookmark data of PATH and resolves it again (what the Alias units hold)
 *   lsquery -e        lists every application record the client sees (count, then identifier and URL of each) */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2 || (argc < 3 && strcmp(argv[1], "-e"))) return 2;
		if (!strcmp(argv[1], "-b")) {
			NSError *be = nil;
			NSData *bm = [[NSURL fileURLWithPath: @(argv[2])] bookmarkDataWithOptions: 0 includingResourceValuesForKeys: nil relativeToURL: nil error: &be];
			fprintf(stderr, "bookmark: %lu bytes (error %s)\n", (unsigned long)bm.length, be ? [[be description] UTF8String] : "-");
			if (argc > 3 && bm) [bm writeToFile: @(argv[3]) atomically: NO];
			BOOL stale = NO;
			NSURL *u = bm ? [NSURL URLByResolvingBookmarkData: bm options: 0 relativeToURL: nil bookmarkDataIsStale: &stale error: &be] : nil;
			fprintf(stderr, "resolved: %s (error %s)\n", u ? u.path.UTF8String : "nil", be ? [[be description] UTF8String] : "-");
			return 0;
		}
		dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
		dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW);
		NSError *e = nil;
		if (!strcmp(argv[1], "-e")) {
			id ctx = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"LSDatabaseContext"), sel_registerName("sharedDatabaseContext"));
			BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(ctx, sel_registerName("startAccessingReturningError:"), &e);
			fprintf(stderr, "database access: %s (error %s)\n", ok ? "yes" : "no", e ? [[e description] UTF8String] : "-");
			if (ok) ((void (*)(id, SEL))objc_msgSend)(ctx, sel_registerName("stopAccessing"));
			e = nil;
			id en = ((id (*)(id, SEL, unsigned long))objc_msgSend)(NSClassFromString(@"LSApplicationRecord"), sel_registerName("enumeratorWithOptions:"), 0);
			unsigned n = 0;
			for (id r in en) {
				n++;
				fprintf(stderr, "%s %s\n", [[[r valueForKey: @"bundleIdentifier"] description] UTF8String], [[[r valueForKey: @"URL"] path] UTF8String]);
			}
			fprintf(stderr, "%u application records\n", n);
			return 0;
		}
		fprintf(stderr, "asking by identifier\n");
		id r = ((id (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(NSClassFromString(@"LSBundleRecord"), sel_registerName("bundleRecordWithBundleIdentifier:allowPlaceholder:error:"), @(argv[1]), NO, &e);
		fprintf(stderr, "by identifier: %s (error %s)\n", r ? [[r description] UTF8String] : "none", e ? [[e description] UTF8String] : "-");
		e = nil;
		fprintf(stderr, "asking by URL\n");
		id a = ((id (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)([NSClassFromString(@"LSApplicationRecord") alloc], sel_registerName("initWithURL:allowPlaceholder:error:"), [NSURL fileURLWithPath: @(argv[2])], NO, &e);
		fprintf(stderr, "by URL: %s (error %s)\n", a ? [[a description] UTF8String] : "none", e ? [[e description] UTF8String] : "-");
		double pt = argc > 3 ? atof(argv[3]) : 128;
		id icon = ((id (*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"ISBundleIcon") alloc], sel_registerName("initWithBundleURL:"), [NSURL fileURLWithPath: @(argv[2])]);
		id d = ((id (*)(id, SEL, CGSize, double))objc_msgSend)([NSClassFromString(@"ISImageDescriptor") alloc], sel_registerName("initWithSize:scale:"), CGSizeMake(pt, pt), 1.0);
		id req = [NSClassFromString(@"ISGenerationRequest") new];
		((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setIcon:"), icon);
		((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setImageDescriptor:"), d);
		id ids = nil; NSDate *t = [NSDate date];
		id img = ((id (*)(id, SEL, id *))objc_msgSend)(req, sel_registerName("generateImageReturningRecordIdentifiers:"), &ids);
		fprintf(stderr, "recipe: %s in %.2f s\n", img ? [[img description] UTF8String] : "nil", -[t timeIntervalSinceNow]);
	}
	return 0;
}
