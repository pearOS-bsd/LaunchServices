/* SPDX-License-Identifier: BSD-2-Clause */
/* lsss_check: compares our libLaunchServicesSupport.dylib with Apple's on a Mac (macOS 26.7.2).
 *   lsss_check APPLE.dylib OURS.dylib
 * OURS is a copy of our build with another install name (dyld would otherwise hand back Apple's image).
 * Every check calls the same symbol in both images on the same input and compares the results:
 * log objects, version symbols, the C++ CF helpers (asString on many object kinds), the string helpers,
 * the ObjC classes (methods, ivars, properties), _LSRegisterAsQuitReallyHelperClient without entitlements,
 * _LSSysdiagnoseStatus / _LSApplicationHasAVisibleWindowOrContext for Finder, and _LSForceQuitApplication
 * on a /bin/sleep this test starts itself (nothing else is killed). */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string>
#include <vector>
#include <map>

extern "C" char **environ;
typedef const struct __LSASN *LSASNRef;
extern "C" LSASNRef _LSASNCreateWithPid(CFAllocatorRef, pid_t);
extern "C" CFArrayRef _LSCopyRunningApplicationArray(int session) __attribute__((weak_import));

/* the selectors of LSExitedApplication the test calls (the class itself comes from dlsym) */
@protocol LSExitedApplicationCalls
+ (id)createApplicationWithASNRef:(LSASNRef)asn info:(NSDictionary *)info;
+ (void)removeApplication:(id)app;
+ (id)findApplicationWithASNRef:(LSASNRef)asn;
+ (BOOL)stillTrackingExitedApplication:(id)app;
+ (NSString *)statusString;
- (NSString *)displayName;
- (NSString *)bundleIdentifier;
- (NSURL *)bundleURL;
- (BOOL)isForeground;
- (BOOL)isUIElement;
- (unsigned long long)coalitionID;
- (BOOL)hasControlCenterItem;
- (BOOL)stillRunning;
@end
@interface NSObject (LSExitedApplicationCalls) <LSExitedApplicationCalls>
@end

static void *A, *O;
static int failures, checks;

static void report(bool ok, const std::string &what, const std::string &a = "", const std::string &o = "")
{
	checks++;
	if (ok) { printf("ok   %s\n", what.c_str()); return; }
	failures++;
	printf("FAIL %s\n     apple: %s\n     ours:  %s\n", what.c_str(), a.c_str(), o.c_str());
}

template <typename F> static void sym(const char *name, F &fa, F &fo)
{
	fa = (F)dlsym(A, name);
	fo = (F)dlsym(O, name);
	if (!fa || !fo) { printf("FAIL missing %s (apple %p ours %p)\n", name, (void *)fa, (void *)fo); failures++; exit(1); }
}

static std::string desc(id o)
{
	if (!o) return "(nil)";
	NSString *d = [o description];
	return d ? [d UTF8String] : "(nil description)";
}

/* object descriptions carry their address: drop "0x..." runs */
static std::string noAddresses(std::string s)
{
	std::string r;
	for (size_t i = 0; i < s.size(); i++) {
		if (s[i] == '0' && i + 1 < s.size() && s[i + 1] == 'x') {
			r += "0x?"; i += 2;
			while (i < s.size() && isxdigit((unsigned char)s[i])) i++;
			i--;
		} else r += s[i];
	}
	return r;
}

static bool same(CFTypeRef a, CFTypeRef b) { return a == b || (a && b && CFEqual(a, b)); }
static std::string cfdesc(CFTypeRef o) { return o ? desc((__bridge id)o) : "(NULL)"; }

int main(int argc, char **argv)
{
	@autoreleasepool {
	if (argc < 3) { fprintf(stderr, "usage: lsss_check APPLE.dylib OURS.dylib\n"); return 2; }
	A = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	O = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
	if (!A || !O) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
	if (A == O) { fprintf(stderr, "both paths gave the same image; give OURS another install name\n"); return 2; }

	/* ---- logs */
	const char *logs[] = { "_LSDefaultLog", "_LSAnalyticsLog", "_LSAppCheckInLog", "_LSExtensionsLog", "_LSFrontLog", "_LSInstallLog",
		"_LSProgressLog", "_LSDisseminationLog", "_LSPrivacyLog", "_LSDataSeparationLog", "_LSDatabaseGetLog", "_LSOpenLog",
		"_LSQuitSupportLog", "_LSRecordLog", "_LSRegistrationLog", "_LSTemplateAppLog", "_LSBindingLog", "_LSAppProtectionLog",
		"_LSCSUILog", "_LSPluginFaultLog", "_LSTelemetryLog" };
	for (const char *l : logs) {
		id (*fa)(void), (*fo)(void);
		sym(l, fa, fo);
		std::string a = noAddresses(desc(fa())), o = noAddresses(desc(fo()));
		report(a == o && fa() == fa() && fo() == fo(), std::string("log ") + l, a, o);
	}

	/* ---- version symbols */
	{
		const char *sa = (const char *)dlsym(A, "libLaunchServicesSupportVersionString"), *so = (const char *)dlsym(O, "libLaunchServicesSupportVersionString");
		const double *na = (const double *)dlsym(A, "libLaunchServicesSupportVersionNumber"), *no = (const double *)dlsym(O, "libLaunchServicesSupportVersionNumber");
		report(sa && so && !strcmp(sa, so), "libLaunchServicesSupportVersionString", sa ?: "", so ?: "");
		report(na && no && *na == *no, "libLaunchServicesSupportVersionNumber", std::to_string(na ? *na : -1), std::to_string(no ? *no : -1));
		const char *keys[] = { "_kLSForceQuitApplicationDoNotInformLibQuitKey", "_kLSForceQuitApplicationPresentFirstForceQuitDialogKey",
			"_kLSForceQuitApplicationSynchronousOperationKey" };
		for (const char *k : keys) {
			CFStringRef *ka = (CFStringRef *)dlsym(A, k), *ko = (CFStringRef *)dlsym(O, k);
			report(ka && ko && same(*ka, *ko), k, cfdesc(*ka), cfdesc(*ko));
		}
	}

	/* ---- sample objects */
	CFArrayRef arr = (__bridge_retained CFArrayRef)@[ @"b", @"a\nb", @1, @2.5, @YES, [NSNull null], @[ @"x" ] ];
	CFDictionaryRef dict = (__bridge_retained CFDictionaryRef)@{ @"zeta": @1, @"alpha": @"two", @"mid": @[ @3 ], @"data": [NSData dataWithBytes:"\x01\xab\x00" length:3] };
	CFSetRef set = (__bridge_retained CFSetRef)[NSSet setWithArray:@[ @"q", @"c", @"m" ]];
	char b8 = -5; short s16 = 300; long long ll = -1234567890123LL; float f = 1.5f; double d = 3.25; CFIndex ix = 77;
	std::vector<CFTypeRef> objs = {
		NULL, CFSTR("plain"), CFSTR("line\nbreak"), CFSTR("ünïcode ✓"), arr, dict, set, CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks),
		CFDictionaryCreate(NULL, NULL, NULL, 0, NULL, NULL), (__bridge_retained CFTypeRef)[NSData data],
		(__bridge_retained CFTypeRef)[NSData dataWithBytes:"\x00\x10\xff" length:3],
		CFNumberCreate(NULL, kCFNumberCharType, &b8), CFNumberCreate(NULL, kCFNumberShortType, &s16), CFNumberCreate(NULL, kCFNumberLongLongType, &ll),
		CFNumberCreate(NULL, kCFNumberFloatType, &f), CFNumberCreate(NULL, kCFNumberDoubleType, &d), CFNumberCreate(NULL, kCFNumberCFIndexType, &ix),
		kCFBooleanTrue, kCFBooleanFalse, kCFNull,
		CFURLCreateWithString(NULL, CFSTR("https://example.com/a?b"), NULL),
		CFURLCreateWithString(NULL, CFSTR("sub/file"), (__bridge CFURLRef)[NSURL URLWithString:@"file:///tmp/"]),
		(__bridge_retained CFTypeRef)[NSError errorWithDomain:@"dom" code:42 userInfo:@{ @"k": @"v" }],
		(__bridge_retained CFTypeRef)[NSError errorWithDomain:@"dom" code:-7 userInfo:nil],
		_LSASNCreateWithPid(NULL, getpid()), _LSASNCreateWithPid(NULL, 1),
		(__bridge_retained CFTypeRef)[NSDate dateWithTimeIntervalSinceReferenceDate:700000000.0],
		(__bridge_retained CFTypeRef)[NSDate dateWithTimeIntervalSinceNow:-0.5], (__bridge_retained CFTypeRef)[NSDate dateWithTimeIntervalSinceNow:120.4],
		(__bridge_retained CFTypeRef)[NSDate dateWithTimeIntervalSinceNow:-200.6], (__bridge_retained CFTypeRef)[NSDate dateWithTimeIntervalSinceNow:4000],
		CFUUIDCreate(NULL), CFTimeZoneCopyDefault(),
	};

	/* ---- asString */
	{
		std::string (*fa)(const void *), (*fo)(const void *);
		sym("_Z8asStringPKv", fa, fo);
		for (CFTypeRef o : objs) {
			std::string a = fa(o), b = fo(o);
			if (o && CFGetTypeID(o) == CFUUIDGetTypeID()) { a = noAddresses(a); b = noAddresses(b); }
			{ std::string n = o ? noAddresses(cfdesc(o)).substr(0, 40) : std::string("NULL"); for (char &ch : n) if (ch == '\n') ch = ' '; report(a == b, "asString(" + n + ")", a, b); }
		}
		std::string (*ta)(double, bool), (*to)(double, bool);
		sym("_Z8asStringdb", ta, to);
		double times[] = { 0, 1, 59.5, 90, 3600, 86400 * 3, 86400 * 400, 700000000.0, -5 };
		for (double t : times) for (int r = 0; r < 2; r++)
			report(ta(t, r) == to(t, r), "asString(" + std::to_string(t) + "," + std::to_string(r) + ")", ta(t, r), to(t, r));
		std::string (*ca)(CFStringRef, CFStringEncoding), (*co)(CFStringRef, CFStringEncoding);
		sym("_Z23CFStringConvertToStringPK10__CFStringj", ca, co);
		CFStringRef strs[] = { CFSTR("abc"), CFSTR("ünï"), NULL };
		CFStringEncoding encs[] = { kCFStringEncodingUTF8, kCFStringEncodingASCII, kCFStringEncodingMacRoman };
		for (CFStringRef s : strs) for (CFStringEncoding e : encs)
			report(ca(s, e) == co(s, e), "CFStringConvertToString(" + cfdesc(s) + "," + std::to_string(e) + ")", ca(s, e), co(s, e));
	}

	/* ---- hex */
	{
		CFStringRef (*ma)(const void *, unsigned long), (*mo)(const void *, unsigned long);
		sym("_Z33CFStringCreateByHexEncodingMemoryPKvm", ma, mo);
		report(same(ma("\x00\x7f\xff", 3), mo("\x00\x7f\xff", 3)), "CFStringCreateByHexEncodingMemory", cfdesc(ma("\x00\x7f\xff", 3)), cfdesc(mo("\x00\x7f\xff", 3)));
		report(same(ma(NULL, 0), mo(NULL, 0)), "CFStringCreateByHexEncodingMemory(empty)");
		CFStringRef (*da)(CFDataRef), (*dO)(CFDataRef);
		sym("_Z31CFStringCreateByHexEncodingDataPK8__CFData", da, dO);
		report(same(da((CFDataRef)objs[10]), dO((CFDataRef)objs[10])) && same(da(NULL), dO(NULL)), "CFStringCreateByHexEncodingData");
		CFDataRef (*ha)(CFStringRef), (*ho)(CFStringRef);
		sym("_Z32CFDataCreateFromHexEncodedStringPK10__CFString", ha, ho);
		CFStringRef hs[] = { CFSTR(""), CFSTR("00ff7A"), CFSTR("$0aFF0"), CFSTR("$0aFF"), CFSTR("abc"), CFSTR("zz"), CFSTR("12zz"), CFSTR("a") };
		for (CFStringRef s : hs) report(same(ha(s), ho(s)), "CFDataCreateFromHexEncodedString(" + cfdesc(s) + ")", cfdesc(ha(s)), cfdesc(ho(s)));
	}

	/* ---- arrays */
	{
		CFArrayRef (*ia)(const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *), (*io)(const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *);
		sym("_Z22CFArrayCreateWithItemsPKvS0_S0_S0_S0_S0_S0_S0_S0_S0_", ia, io);
		report(same(ia(CFSTR("a"), NULL, CFSTR("c"), NULL, NULL, NULL, NULL, NULL, NULL, CFSTR("j")), io(CFSTR("a"), NULL, CFSTR("c"), NULL, NULL, NULL, NULL, NULL, NULL, CFSTR("j"))) &&
		       same(ia(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL), io(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)), "CFArrayCreateWithItems");
		CFArrayRef (*sa)(CFArrayRef, unsigned long, CFComparisonResult (^)(const void *, const void *)), (*so)(CFArrayRef, unsigned long, CFComparisonResult (^)(const void *, const void *));
		sym("_Z11CFArraySortPK9__CFArraymU13block_pointerF18CFComparisonResultPKvS4_E", sa, so);
		CFArrayRef words = (__bridge CFArrayRef)@[ @"pear", @"apple", @"fig", @"kiwi", @"date", @"lime", @"plum", @"yuzu", @"nut", @"bean", @"corn", @"oat", @"rye", @"pea", @"gum", @"tea", @"zest", @"herb" ];
		auto cmp = ^CFComparisonResult(const void *x, const void *y) { return CFStringCompare((CFStringRef)x, (CFStringRef)y, 0); };
		report(same(sa(words, CFStringGetTypeID(), cmp), so(words, CFStringGetTypeID(), cmp)), "CFArraySort(strings)", cfdesc(sa(words, CFStringGetTypeID(), cmp)), cfdesc(so(words, CFStringGetTypeID(), cmp)));
		report(same(sa(words, 0, cmp), so(words, 0, cmp)) && same(sa(arr, CFStringGetTypeID(), cmp), so(arr, CFStringGetTypeID(), cmp)), "CFArraySort(type mismatch)");
		CFArrayRef (*ma)(CFArrayRef, CFArrayRef), (*mo)(CFArrayRef, CFArrayRef);
		sym("_Z23CFArrayCopyMergedArraysPK9__CFArrayS1_", ma, mo);
		CFArrayRef e = (CFArrayRef)objs[7];
		report(same(ma(arr, words), mo(arr, words)) && same(ma(NULL, words), mo(NULL, words)) && same(ma(arr, NULL), mo(arr, NULL)) && same(ma(e, e), mo(e, e)) && same(ma(NULL, NULL), mo(NULL, NULL)), "CFArrayCopyMergedArrays");
		CFArrayRef (*wa)(CFSetRef), (*wo)(CFSetRef);
		sym("_Z20CFArrayCreateWithSetPK7__CFSet", wa, wo);
		report(same(wa(set), wo(set)) && same(wa(NULL), wo(NULL)), "CFArrayCreateWithSet");
		bool (*aa)(CFArrayRef, bool (^)(const void *)), (*ao)(CFArrayRef, bool (^)(const void *));
		sym("_Z17CFArrayApplyBlockPK9__CFArrayU13block_pointerFbPKvE", aa, ao);
		__block int na = 0, no = 0;
		bool ra = aa(arr, ^bool(const void *) { return ++na < 3; }), ro = ao(arr, ^bool(const void *) { return ++no < 3; });
		report(ra == ro && na == no && aa(NULL, nil) == ao(NULL, nil), "CFArrayApplyBlock", std::to_string(ra) + "/" + std::to_string(na), std::to_string(ro) + "/" + std::to_string(no));
		bool (*ta)(CFArrayRef, unsigned long, bool (^)(const void *)), (*to)(CFArrayRef, unsigned long, bool (^)(const void *));
		sym("_Z17CFArrayApplyBlockPK9__CFArraymU13block_pointerFbPKvE", ta, to);
		na = no = 0;
		ra = ta(arr, CFStringGetTypeID(), ^bool(const void *) { na++; return true; }); ro = to(arr, CFStringGetTypeID(), ^bool(const void *) { no++; return true; });
		bool rb = ta(arr, CFDataGetTypeID(), ^bool(const void *) { return true; }), rc = to(arr, CFDataGetTypeID(), ^bool(const void *) { return true; });
		report(ra == ro && na == no && rb == rc, "CFArrayApplyBlock(typed)", std::to_string(ra) + "/" + std::to_string(na) + "/" + std::to_string(rb), std::to_string(ro) + "/" + std::to_string(no) + "/" + std::to_string(rc));
		CFArrayRef (*pa)(CFArrayRef, unsigned long, const void *(^)(const void *, bool *)), (*po)(CFArrayRef, unsigned long, const void *(^)(const void *, bool *));
		sym("_Z28CFArrayCreateByApplyingBlockPK9__CFArraymU13block_pointerFPKvS3_PbE", pa, po);
		auto map = ^const void *(const void *v, bool *stop) { if (CFEqual(v, CFSTR("x"))) *stop = true; return CFStringCreateWithFormat(NULL, NULL, CFSTR("<%@>"), v); };
		report(same(pa(arr, 0, map), po(arr, 0, map)) && same(pa(arr, CFStringGetTypeID(), map), po(arr, CFStringGetTypeID(), map)), "CFArrayCreateByApplyingBlock", cfdesc(pa(arr, 0, map)), cfdesc(po(arr, 0, map)));
		void (*xa)(CFMutableArrayRef, CFArrayRef), (*xo)(CFMutableArrayRef, CFArrayRef);
		sym("_Z18CFArrayAppendArrayP9__CFArrayPKS_", xa, xo);
		CFMutableArrayRef m1 = CFArrayCreateMutableCopy(NULL, 0, arr), m2 = CFArrayCreateMutableCopy(NULL, 0, arr);
		xa(m1, words); xo(m2, words); xa(m1, NULL); xo(m2, NULL);
		report(same(m1, m2), "CFArrayAppendArray");
		bool (*ra1)(CFMutableArrayRef, const void *), (*ro1)(CFMutableArrayRef, const void *);
		sym("_Z18CFArrayRemoveValueP9__CFArrayPKv", ra1, ro1);
		CFArrayAppendValue(m1, CFSTR("b")); CFArrayAppendValue(m2, CFSTR("b"));
		bool r1 = ra1(m1, CFSTR("b")), r2 = ro1(m2, CFSTR("b")), r3 = ra1(m1, CFSTR("none")), r4 = ro1(m2, CFSTR("none"));
		report(same(m1, m2) && r1 == r2 && r3 == r4, "CFArrayRemoveValue", cfdesc(m1), cfdesc(m2));
		bool (*rva)(CFMutableArrayRef, CFArrayRef), (*rvo)(CFMutableArrayRef, CFArrayRef);
		sym("_Z19CFArrayRemoveValuesP9__CFArrayPKS_", rva, rvo);
		CFArrayRef rm = (__bridge CFArrayRef)@[ @"pear", @1, @"kiwi" ];
		r1 = rva(m1, rm); r2 = rvo(m2, rm);
		report(same(m1, m2) && r1 == r2, "CFArrayRemoveValues", cfdesc(m1), cfdesc(m2));
	}

	/* ---- dictionaries */
	{
		CFDictionaryRef (*c2a)(const void *, const void *, const void *, const void *), (*c2o)(const void *, const void *, const void *, const void *);
		sym("_Z27CFDictionaryCreateWithItemsPKvS0_S0_S0_", c2a, c2o);
		report(same(c2a(CFSTR("k"), CFSTR("v"), NULL, CFSTR("w")), c2o(CFSTR("k"), CFSTR("v"), NULL, CFSTR("w"))) && same(c2a(NULL, NULL, NULL, NULL), c2o(NULL, NULL, NULL, NULL)) &&
		       same(c2a(NULL, CFSTR("v"), CFSTR("k2"), CFSTR("v2")), c2o(NULL, CFSTR("v"), CFSTR("k2"), CFSTR("v2"))), "CFDictionaryCreateWithItems(2)");
		typedef CFDictionaryRef (*C6)(const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *);
		C6 c6a, c6o;
		sym("_Z27CFDictionaryCreateWithItemsPKvS0_S0_S0_S0_S0_S0_S0_S0_S0_S0_S0_", c6a, c6o);
		report(same(c6a(CFSTR("a"), CFSTR("1"), CFSTR("b"), NULL, CFSTR("c"), CFSTR("3"), NULL, NULL, CFSTR("e"), CFSTR("5"), CFSTR("f"), CFSTR("6")),
		            c6o(CFSTR("a"), CFSTR("1"), CFSTR("b"), NULL, CFSTR("c"), CFSTR("3"), NULL, NULL, CFSTR("e"), CFSTR("5"), CFSTR("f"), CFSTR("6"))), "CFDictionaryCreateWithItems(6)");
		typedef CFDictionaryRef (*C3)(const void *, const void *, const void *, const void *, const void *, const void *);
		C3 c3a, c3o; sym("_Z27CFDictionaryCreateWithItemsPKvS0_S0_S0_S0_S0_", c3a, c3o);
		report(same(c3a(CFSTR("a"), CFSTR("1"), NULL, NULL, CFSTR("c"), CFSTR("3")), c3o(CFSTR("a"), CFSTR("1"), NULL, NULL, CFSTR("c"), CFSTR("3"))), "CFDictionaryCreateWithItems(3)");
		typedef CFDictionaryRef (*C4)(const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *);
		C4 c4a, c4o; sym("_Z27CFDictionaryCreateWithItemsPKvS0_S0_S0_S0_S0_S0_S0_", c4a, c4o);
		report(same(c4a(CFSTR("a"), CFSTR("1"), CFSTR("b"), CFSTR("2"), CFSTR("c"), CFSTR("3"), CFSTR("d"), CFSTR("4")), c4o(CFSTR("a"), CFSTR("1"), CFSTR("b"), CFSTR("2"), CFSTR("c"), CFSTR("3"), CFSTR("d"), CFSTR("4"))), "CFDictionaryCreateWithItems(4)");
		typedef CFDictionaryRef (*C5)(const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *);
		C5 c5a, c5o; sym("_Z27CFDictionaryCreateWithItemsPKvS0_S0_S0_S0_S0_S0_S0_S0_S0_", c5a, c5o);
		report(same(c5a(CFSTR("a"), CFSTR("1"), CFSTR("b"), CFSTR("2"), CFSTR("c"), CFSTR("3"), CFSTR("d"), CFSTR("4"), CFSTR("e"), CFSTR("5")), c5o(CFSTR("a"), CFSTR("1"), CFSTR("b"), CFSTR("2"), CFSTR("c"), CFSTR("3"), CFSTR("d"), CFSTR("4"), CFSTR("e"), CFSTR("5"))), "CFDictionaryCreateWithItems(5)");
		CFDictionaryRef (*i1a)(CFDictionaryRef, const void *, const void *), (*i1o)(CFDictionaryRef, const void *, const void *);
		sym("_Z30CFDictionaryCreateCopyWithItemPK14__CFDictionaryPKvS3_", i1a, i1o);
		report(same(i1a(dict, CFSTR("n"), CFSTR("v")), i1o(dict, CFSTR("n"), CFSTR("v"))) && same(i1a(NULL, CFSTR("n"), CFSTR("v")), i1o(NULL, CFSTR("n"), CFSTR("v"))) && same(i1a(dict, NULL, CFSTR("v")), i1o(dict, NULL, CFSTR("v"))), "CFDictionaryCreateCopyWithItem");
		typedef CFDictionaryRef (*CI)(CFDictionaryRef, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *, const void *);
		CI cia, cio; sym("_Z31CFDictionaryCreateCopyWithItemsPK14__CFDictionaryPKvS3_S3_S3_S3_S3_S3_S3_S3_S3_", cia, cio);
		CFDictionaryRef xa = cia(dict, CFSTR("1"), CFSTR("one"), NULL, CFSTR("x"), CFSTR("3"), CFSTR("three"), CFSTR("4"), CFSTR("four"), CFSTR("5"), CFSTR("five"));
		CFDictionaryRef xo = cio(dict, CFSTR("1"), CFSTR("one"), NULL, CFSTR("x"), CFSTR("3"), CFSTR("three"), CFSTR("4"), CFSTR("four"), CFSTR("5"), CFSTR("five"));
		report(same(xa, xo), "CFDictionaryCreateCopyWithItems", cfdesc(xa), cfdesc(xo));
		CFDictionaryRef (*wa)(CFDictionaryRef, const void *, const void *), (*wo)(CFDictionaryRef, const void *, const void *);
		sym("_Z24CFDictionaryCopyWithItemPK14__CFDictionaryPKvS3_", wa, wo);
		report(same(wa(dict, CFSTR("n"), CFSTR("v")), wo(dict, CFSTR("n"), CFSTR("v"))) && same(wa(NULL, CFSTR("n"), CFSTR("v")), wo(NULL, CFSTR("n"), CFSTR("v"))) && same(wa(NULL, NULL, NULL), wo(NULL, NULL, NULL)) && same(wa(dict, NULL, NULL), wo(dict, NULL, NULL)), "CFDictionaryCopyWithItem");
		CFDictionaryRef (*mga)(CFDictionaryRef, CFDictionaryRef), (*mgo)(CFDictionaryRef, CFDictionaryRef);
		sym("_Z21CFDictionaryCopyMergePK14__CFDictionaryS1_", mga, mgo);
		CFDictionaryRef d2 = (__bridge CFDictionaryRef)@{ @"zeta": @"new", @"omega": @0 };
		CFDictionaryRef ed = (CFDictionaryRef)objs[8];
		report(same(mga(dict, d2), mgo(dict, d2)) && same(mga(NULL, d2), mgo(NULL, d2)) && same(mga(dict, NULL), mgo(dict, NULL)) && same(mga(ed, NULL), mgo(ed, NULL)) && same(mga(dict, ed), mgo(dict, ed)), "CFDictionaryCopyMerge");
		CFArrayRef (*ka)(CFDictionaryRef), (*ko)(CFDictionaryRef);
		sym("_Z23CFDictionaryCopyAllKeysPK14__CFDictionary", ka, ko);
		report(same(ka(dict), ko(dict)) && same(ka(ed), ko(ed)), "CFDictionaryCopyAllKeys");
		sym("_Z25CFDictionaryCopyAllValuesPK14__CFDictionary", ka, ko);
		report(same(ka(dict), ko(dict)) && same(ka(NULL), ko(NULL)), "CFDictionaryCopyAllValues");
		CFDictionaryRef nums = (__bridge CFDictionaryRef)@{ @"i": @42, @"d": @2.75, @"b": @YES, @"s": @"str", @"big": @(1ULL << 40), @"neg": @-3 };
		CFStringRef nk[] = { CFSTR("i"), CFSTR("d"), CFSTR("b"), CFSTR("s"), CFSTR("big"), CFSTR("neg"), CFSTR("none") };
		bool (*ba)(CFDictionaryRef, CFStringRef, bool), (*bo)(CFDictionaryRef, CFStringRef, bool); sym("_Z27CFDictionaryGetBooleanValuePK14__CFDictionaryPK10__CFStringb", ba, bo);
		long (*la)(CFDictionaryRef, const void *, long), (*lo)(CFDictionaryRef, const void *, long); sym("_Z26CFDictionaryGetValueAsLongPK14__CFDictionaryPKvl", la, lo);
		double (*fa)(CFDictionaryRef, CFStringRef, double), (*fo)(CFDictionaryRef, CFStringRef, double); sym("_Z28CFDictionaryGetValueAsDoublePK14__CFDictionaryPK10__CFStringd", fa, fo);
		int (*na)(CFDictionaryRef, CFStringRef, int), (*no)(CFDictionaryRef, CFStringRef, int); sym("_Z25CFDictionaryGetValueAsIntPK14__CFDictionaryPK10__CFStringi", na, no);
		unsigned long long (*ua)(CFDictionaryRef, CFStringRef, unsigned long long), (*uo)(CFDictionaryRef, CFStringRef, unsigned long long); sym("_Z28CFDictionaryGetValueAsUInt64PK14__CFDictionaryPK10__CFStringy", ua, uo);
		for (CFStringRef k : nk) {
			std::string n = cfdesc(k);
			report(ba(nums, k, true) == bo(nums, k, true) && ba(nums, k, false) == bo(nums, k, false), "CFDictionaryGetBooleanValue(" + n + ")");
			report(la(nums, k, -9) == lo(nums, k, -9), "CFDictionaryGetValueAsLong(" + n + ")", std::to_string(la(nums, k, -9)), std::to_string(lo(nums, k, -9)));
			report(fa(nums, k, -9.5) == fo(nums, k, -9.5), "CFDictionaryGetValueAsDouble(" + n + ")", std::to_string(fa(nums, k, -9.5)), std::to_string(fo(nums, k, -9.5)));
			report(na(nums, k, -9) == no(nums, k, -9), "CFDictionaryGetValueAsInt(" + n + ")", std::to_string(na(nums, k, -9)), std::to_string(no(nums, k, -9)));
			report(ua(nums, k, 9) == uo(nums, k, 9), "CFDictionaryGetValueAsUInt64(" + n + ")", std::to_string(ua(nums, k, 9)), std::to_string(uo(nums, k, 9)));
		}
		report(na(NULL, CFSTR("i"), 5) == no(NULL, CFSTR("i"), 5) && la(nums, NULL, 5) == lo(nums, NULL, 5), "CFDictionaryGetValueAs*(NULL)");
		bool (*pa)(CFDictionaryRef, bool (^)(const void *, const void *)), (*po)(CFDictionaryRef, bool (^)(const void *, const void *));
		sym("_Z22CFDictionaryApplyBlockPK14__CFDictionaryU13block_pointerFbPKvS3_E", pa, po);
		__block int ca = 0, co = 0;
		bool r1 = pa(nums, ^bool(const void *, const void *) { return ++ca < 2; }), r2 = po(nums, ^bool(const void *, const void *) { return ++co < 2; });
		report(r1 == r2 && ca == co, "CFDictionaryApplyBlock", std::to_string(r1) + "/" + std::to_string(ca), std::to_string(r2) + "/" + std::to_string(co));
		bool (*qa)(CFDictionaryRef, unsigned long, bool (^)(const void *, const void *)), (*qo)(CFDictionaryRef, unsigned long, bool (^)(const void *, const void *));
		sym("_Z22CFDictionaryApplyBlockPK14__CFDictionarymU13block_pointerFbPKvS3_E", qa, qo);
		unsigned long types[] = { 0, 1, CFNumberGetTypeID(), CFStringGetTypeID() };
		for (unsigned long t : types) {
			ca = co = 0;
			r1 = qa(nums, t, ^bool(const void *, const void *) { ca++; return true; }); r2 = qo(nums, t, ^bool(const void *, const void *) { co++; return true; });
			report(r1 == r2 && ca == co, "CFDictionaryApplyBlock(type " + std::to_string(t) + ")", std::to_string(r1) + "/" + std::to_string(ca), std::to_string(r2) + "/" + std::to_string(co));
		}
	}

	/* ---- sets and strings */
	{
		CFSetRef (*wa)(CFArrayRef), (*wo)(CFArrayRef); sym("_Z20CFSetCreateWithArrayPK9__CFArray", wa, wo);
		report(same(wa(arr), wo(arr)) && same(wa(NULL), wo(NULL)) && same(wa((CFArrayRef)objs[7]), wo((CFArrayRef)objs[7])), "CFSetCreateWithArray");
		CFSetRef (*ma)(CFSetRef, CFSetRef), (*mo)(CFSetRef, CFSetRef); sym("_Z20CFSetCreateMergedSetPK7__CFSetS1_", ma, mo);
		CFSetRef s2 = (__bridge CFSetRef)[NSSet setWithArray:@[ @"q", @"zz" ]];
		report(same(ma(set, s2), mo(set, s2)) && same(ma(NULL, s2), mo(NULL, s2)) && same(ma(set, NULL), mo(set, NULL)), "CFSetCreateMergedSet");
		void (*pa)(CFMutableSetRef, CFSetRef), (*po)(CFMutableSetRef, CFSetRef); sym("_Z14CFSetAppendSetP7__CFSetPKS_", pa, po);
		CFMutableSetRef x1 = CFSetCreateMutableCopy(NULL, 0, set), x2 = CFSetCreateMutableCopy(NULL, 0, set);
		pa(x1, s2); po(x2, s2);
		report(same(x1, x2), "CFSetAppendSet", cfdesc(x1), cfdesc(x2));
		bool (*aa)(CFSetRef, bool (^)(const void *)), (*ao)(CFSetRef, bool (^)(const void *)); sym("_Z15CFSetApplyBlockPK7__CFSetU13block_pointerFbPKvE", aa, ao);
		__block int na = 0, no = 0;
		bool r1 = aa(set, ^bool(const void *) { return ++na < 2; }), r2 = ao(set, ^bool(const void *) { return ++no < 2; });
		bool r3 = aa(set, ^bool(const void *) { return true; }), r4 = ao(set, ^bool(const void *) { return true; });
		report(r1 == r2 && na == no && r3 == r4 && aa(NULL, nil) == ao(NULL, nil), "CFSetApplyBlock");
		bool (*sa)(CFSetRef, CFComparisonResult (^)(const void *, const void *), bool (^)(const void *)), (*so)(CFSetRef, CFComparisonResult (^)(const void *, const void *), bool (^)(const void *));
		sym("_Z15CFSetApplyBlockPK7__CFSetU13block_pointerF18CFComparisonResultPKvS4_EU13block_pointerFbS4_E", sa, so);
		NSMutableString *oa = [NSMutableString string], *oo = [NSMutableString string];
		auto cmp = ^CFComparisonResult(const void *x, const void *y) { return CFStringCompare((CFStringRef)x, (CFStringRef)y, 0); };
		r1 = sa(set, cmp, ^bool(const void *v) { [oa appendString:(__bridge NSString *)v]; return true; });
		r2 = so(set, cmp, ^bool(const void *v) { [oo appendString:(__bridge NSString *)v]; return true; });
		report(r1 == r2 && [oa isEqual:oo], "CFSetApplyBlock(sorted)", [oa UTF8String], [oo UTF8String]);
		long (*la)(CFStringRef, CFStringRef), (*lo)(CFStringRef, CFStringRef); sym("_Z27CFStringLongestCommonPrefixPK10__CFStringS1_", la, lo);
		report(la(CFSTR("prefix-one"), CFSTR("prefix-two")) == lo(CFSTR("prefix-one"), CFSTR("prefix-two")) && la(CFSTR("same"), CFSTR("same")) == lo(CFSTR("same"), CFSTR("same")) && la(NULL, CFSTR("x")) == lo(NULL, CFSTR("x")), "CFStringLongestCommonPrefix");
		NSString *(*pna)(int), *(*pno)(int); sym("_Z11processNamei", pna, pno);
		report(desc(pna(getpid())) == desc(pno(getpid())) && desc(pna(999999)) == desc(pno(999999)) && desc(pna(1)) == desc(pno(1)), "processName", desc(pna(getpid())), desc(pno(getpid())));
		NSString *(*ua)(NSURL *), *(*uo)(NSURL *); sym("loggableURL", ua, uo);
		NSURL *urls[] = { [NSURL fileURLWithPath:@"/Applications/Safari.app"], [NSURL URLWithString:@"https://secret.example/x?token=1"], [NSURL URLWithString:@"mailto:a@b.c"] };
		for (NSURL *u : urls) report([ua(u) isEqual:uo(u)], "loggableURL(" + desc(u) + ")", desc(ua(u)), desc(uo(u)));
		NSString *(*bta)(void), *(*bto)(void); sym("backtraceString", bta, bto);
		NSString *b1 = bta(), *b2 = bto();
		report([[b1 componentsSeparatedByString:@" / "] count] == [[b2 componentsSeparatedByString:@" / "] count] && [b1 hasSuffix:@"start + 1"] == [b2 hasSuffix:@"start + 1"], "backtraceString (shape)", desc(b1), desc(b2));
		NSString *(*cba)(void), *(*cbo)(void); sym("copyBacktraceString", cba, cbo);
		report([cba() length] > 0 && [cbo() length] > 0, "copyBacktraceString");
	}

	/* ---- ObjC classes */
	{
		const char *classes[] = { "_OBJC_CLASS_$_LSExitedApplication", "_OBJC_CLASS_$_BTMManagerSupport", "_OBJC_METACLASS_$_LSExitedApplication", "_OBJC_METACLASS_$_BTMManagerSupport" };
		for (const char *c : classes) {
			Class ca = (__bridge Class)dlsym(A, c + 1), co = (__bridge Class)dlsym(O, c + 1);
			if (!ca || !co) { report(false, std::string("class ") + c, ca ? "found" : "missing", co ? "found" : "missing"); continue; }
			auto methods = [](Class k) { std::map<std::string, std::string> m; unsigned n; Method *l = class_copyMethodList(k, &n);
				for (unsigned i = 0; i < n; i++) m[sel_getName(method_getName(l[i]))] = method_getTypeEncoding(l[i]); free(l); return m; };
			auto ivars = [](Class k) { std::string s; unsigned n; Ivar *l = class_copyIvarList(k, &n);
				for (unsigned i = 0; i < n; i++) s += std::string(ivar_getName(l[i])) + ":" + ivar_getTypeEncoding(l[i]) + "@" + std::to_string(ivar_getOffset(l[i])) + " "; free(l); return s; };
			auto props = [](Class k) { std::string s; unsigned n; objc_property_t *l = class_copyPropertyList(k, &n);
				std::map<std::string, std::string> m; for (unsigned i = 0; i < n; i++) m[property_getName(l[i])] = property_getAttributes(l[i]); free(l);
				for (auto &p : m) s += p.first + "=" + p.second + " "; return s; };
			auto ma = methods(ca), mo = methods(co);
			std::string sa, so;
			for (auto &p : ma) sa += p.first + p.second + " ";
			for (auto &p : mo) so += p.first + p.second + " ";
			report(sa == so, std::string("methods ") + c, sa, so);
			report(ivars(ca) == ivars(co), std::string("ivars ") + c, ivars(ca), ivars(co));
			report(props(ca) == props(co), std::string("properties ") + c, props(ca), props(co));
			report(class_getInstanceSize(ca) == class_getInstanceSize(co) && !strcmp(class_getName(class_getSuperclass(ca)), class_getName(class_getSuperclass(co))), std::string("size/superclass ") + c);
			unsigned pn; Protocol *__unsafe_unretained *pl = class_copyProtocolList(ca, &pn); std::string pa; for (unsigned i = 0; i < pn; i++) pa += protocol_getName(pl[i]); free(pl);
			pl = class_copyProtocolList(co, &pn); std::string po; for (unsigned i = 0; i < pn; i++) po += protocol_getName(pl[i]); free(pl);
			report(pa == po, std::string("protocols ") + c, pa, po);
		}
		/* behaviour of the tracker on our own ASN */
		Class ea = (__bridge Class)dlsym(A, "OBJC_CLASS_$_LSExitedApplication"), eo = (__bridge Class)dlsym(O, "OBJC_CLASS_$_LSExitedApplication");
		LSASNRef me = _LSASNCreateWithPid(NULL, getpid());
		NSDictionary *info = @{ @"LSDisplayName": @"lsss_check", @"CFBundleIdentifier": @"org.pearos.lsss_check", @"LSBundlePath": @"/tmp/lsss_check.app" };
		id xa = [ea createApplicationWithASNRef:me info:info], xo = [eo createApplicationWithASNRef:me info:info];
		report(noAddresses(desc(xa)) == noAddresses(desc(xo)), "LSExitedApplication description", desc(xa), desc(xo));
		report(desc([xa bundleURL]) == desc([xo bundleURL]) && desc([xa bundleIdentifier]) == desc([xo bundleIdentifier]) && desc([xa displayName]) == desc([xo displayName]) &&
		       [xa isForeground] == [xo isForeground] && [xa isUIElement] == [xo isUIElement] && [xa coalitionID] == [xo coalitionID] && [xa hasControlCenterItem] == [xo hasControlCenterItem] &&
		       [xa stillRunning] == [xo stillRunning] && [ea stillTrackingExitedApplication:xa] == [eo stillTrackingExitedApplication:xo] &&
		       ([ea findApplicationWithASNRef:me] == xa) == ([eo findApplicationWithASNRef:me] == xo), "LSExitedApplication accessors");
		NSString *sta = noAddresses(desc([ea statusString])).c_str() ? [NSString stringWithUTF8String:noAddresses(desc([ea statusString])).c_str()] : nil;
		NSString *sto = [NSString stringWithUTF8String:noAddresses(desc([eo statusString])).c_str()];
		auto stripDate = [](NSString *s) { NSRange r = [s rangeOfString:@"\n"]; return r.location == NSNotFound ? s : [s substringFromIndex:r.location]; };
		report([stripDate(sta) isEqual:stripDate(sto)], "LSExitedApplication statusString", [sta UTF8String], [sto UTF8String]);
		[ea removeApplication:xa]; [eo removeApplication:xo];
		report([ea stillTrackingExitedApplication:xa] == [eo stillTrackingExitedApplication:xo], "LSExitedApplication removeApplication");
	}

	/* ---- quit support entry points (no entitlements: must fail the same way) */
	{
		BOOL (*ra)(NSDictionary *, NSError **), (*ro)(NSDictionary *, NSError **);
		sym("_LSRegisterAsQuitReallyHelperClient", ra, ro);
		NSError *ea = nil, *eo = nil;
		BOOL a = ra(@{ @"DontTakeAction": @YES }, &ea), o = ro(@{ @"DontTakeAction": @YES }, &eo);
		report(a == o && [ea.domain isEqual:eo.domain] && ea.code == eo.code && [ea.userInfo isEqual:eo.userInfo], "_LSRegisterAsQuitReallyHelperClient (unentitled)", desc(ea), desc(eo));

		pid_t finder = 0;
		NSArray *apps = [[NSWorkspace sharedWorkspace] runningApplications];
		for (NSRunningApplication *r in apps) if ([r.bundleIdentifier isEqual:@"com.apple.finder"]) finder = r.processIdentifier;
		LSASNRef fa = finder ? _LSASNCreateWithPid(NULL, finder) : NULL;
		Boolean (*va)(LSASNRef), (*vo)(LSASNRef); sym("_LSApplicationHasAVisibleWindowOrContext", va, vo);
		report(va(fa) == vo(fa) && va(NULL) == vo(NULL), "_LSApplicationHasAVisibleWindowOrContext(Finder)", std::to_string(va(fa)), std::to_string(vo(fa)));
		BOOL (*sa)(NSDictionary *, void (^)(NSDictionary *, NSError *)), (*so)(NSDictionary *, void (^)(NSDictionary *, NSError *));
		sym("_LSSysdiagnoseStatus", sa, so);
		__block NSDictionary *da = nil, *dO = nil;
		__block int calls_a = 0, calls_o = 0;
		BOOL ka = sa(fa ? @{ @"LSASN": (__bridge id)fa } : @{}, ^(NSDictionary *d, NSError *e) { da = d; calls_a++; });
		BOOL ko = so(fa ? @{ @"LSASN": (__bridge id)fa } : @{}, ^(NSDictionary *d, NSError *e) { dO = d; calls_o++; });
		report(ka == ko && calls_a == calls_o && (da == dO || [da isEqual:dO]), "_LSSysdiagnoseStatus(Finder)", desc(da), desc(dO));
		calls_a = calls_o = 0;
		ka = sa(@{}, ^(NSDictionary *d, NSError *e) { calls_a++; }); ko = so(@{}, ^(NSDictionary *d, NSError *e) { calls_o++; });
		report(ka == ko && calls_a == calls_o, "_LSSysdiagnoseStatus(all)", std::to_string(calls_a), std::to_string(calls_o));

		/* _LSForceQuitApplication: bad arguments, then a /bin/sleep we start (synchronous) */
		Boolean (*qa)(int, LSASNRef, CFDictionaryRef, void (^)(BOOL, NSError *)), (*qo)(int, LSASNRef, CFDictionaryRef, void (^)(BOOL, NSError *));
		sym("_LSForceQuitApplication", qa, qo);
		__block BOOL okA = 2, okO = 2; __block NSError *erA = nil, *erO = nil;
		Boolean rA = qa(-2, NULL, NULL, ^(BOOL s, NSError *e) { okA = s; erA = e; }), rO = qo(-2, NULL, NULL, ^(BOOL s, NSError *e) { okO = s; erO = e; });
		report(rA == rO && okA == okO && erA.code == erO.code && [erA.domain isEqual:erO.domain], "_LSForceQuitApplication(NULL asn)", desc(erA), desc(erO));
		CFStringRef syncKey = *(CFStringRef *)dlsym(A, "_kLSForceQuitApplicationSynchronousOperationKey");
		CFDictionaryRef syncOpts = (__bridge CFDictionaryRef)@{ (__bridge NSString *)syncKey: @YES, @"remove": @NO };
		for (int which = 0; which < 2; which++) {
			pid_t child; char *args[] = { (char *)"/bin/sleep", (char *)"60", NULL };
			posix_spawn(&child, "/bin/sleep", NULL, NULL, args, environ);
			LSASNRef ca = _LSASNCreateWithPid(NULL, child);
			__block BOOL ok = 2; __block NSError *er = nil;
			(which ? qo : qa)(-2, ca, syncOpts, ^(BOOL s, NSError *e) { ok = s; er = e; });
			int status; pid_t w = waitpid(child, &status, WNOHANG);
			printf("     %s: completion %d error %s, sleep %s\n", which ? "ours " : "apple", ok, desc(er).c_str(), w == child ? "ended" : "still running");
			if (which == 0) { okA = ok; erA = er; } else { okO = ok; erO = er; }
			kill(child, SIGKILL); waitpid(child, &status, 0);
		}
		report(okA == okO && erA.code == erO.code, "_LSForceQuitApplication(own /bin/sleep, synchronous)", desc(erA), desc(erO));

		/* a real application the test starts itself (LSSS_APP, default Calculator); LQReportHang is
		 * skipped (DoNotInformLibQuit = NO, which is what turns it off) so no hang report is written */
		const char *appID = getenv("LSSS_APP") ?: "com.apple.calculator";
		CFStringRef libquitKey = *(CFStringRef *)dlsym(A, "_kLSForceQuitApplicationDoNotInformLibQuitKey");
		CFDictionaryRef appOpts = (__bridge CFDictionaryRef)@{ (__bridge NSString *)syncKey: @YES, (__bridge NSString *)libquitKey: @NO };
		NSString *bid = [NSString stringWithUTF8String:appID];
		NSURL *appURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bid];
		for (int which = 0; appURL && which < 2; which++) {
			NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
			cfg.activates = NO;
			dispatch_semaphore_t launched = dispatch_semaphore_create(0);
			__block pid_t apid = 0;
			[[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL configuration:cfg completionHandler:^(NSRunningApplication *app, NSError *e) {
				apid = app.processIdentifier; dispatch_semaphore_signal(launched); }];
			dispatch_semaphore_wait(launched, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
			if (!apid) { printf("     could not start %s\n", appID); break; }
			sleep(2);
			LSASNRef aa = _LSASNCreateWithPid(NULL, apid);
			__block BOOL ok = 2; __block NSError *er = nil;
			(which ? qo : qa)(-2, aa, appOpts, ^(BOOL s, NSError *e) { ok = s; er = e; });
			bool gone = false;
			for (int i = 0; i < 50 && !gone; i++) { gone = kill(apid, 0) != 0; if (!gone) usleep(100000); }
			printf("     %s: %s pid %d completion %d error %s, app %s\n", which ? "ours " : "apple", appID, apid, ok, desc(er).c_str(), gone ? "gone" : "STILL RUNNING");
			if (which == 0) { okA = ok; erA = er; rA = gone; } else { okO = ok; erO = er; rO = gone; }
			if (!gone) kill(apid, SIGKILL);
			sleep(1);
		}
		if (appURL) report(okA == okO && erA.code == erO.code && rA == rO && rO, std::string("_LSForceQuitApplication(") + appID + ", synchronous)", desc(erA), desc(erO));
	}

	printf("%d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
	}
}
