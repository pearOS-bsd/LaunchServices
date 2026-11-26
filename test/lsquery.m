/* Test (pearOS and macOS): asks Launch Services for an application by identifier and by URL, then runs IconServices' recipe for its icon in this process.
 *   lsquery BUNDLE-ID /path/App.app [points] */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 3) return 2;
		dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
		dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW);
		NSError *e = nil;
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
