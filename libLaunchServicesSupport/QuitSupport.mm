/* SPDX-License-Identifier: BSD-2-Clause */
/* libLaunchServicesSupport: force quit and "quit really" support, as in Apple's /usr/lib/libLaunchServicesSupport.dylib
 * (macOS 26.7.2): _LSForceQuitApplication (Dock, loginwindow), _LSRegisterAsQuitReallyHelperClient (loginwindow),
 * the LSExitedApplication tracker, the BTM force-quit handler and the sysdiagnose state handlers.
 * Built from the decompiled binary; per-function evidence in research/docs/LAUNCHSERVICESSUPPORT.md.
 * Log texts, option keys, entitlement names and error codes are Apple's. */
#import <Foundation/Foundation.h>
#include "LSSupportSPI.h"
#include <CoreGraphics/CoreGraphics.h>
#include <os/log.h>
#include <os/lock.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <libproc.h>

#define LSS_EXPORT __attribute__((visibility("default")))

extern "C" os_log_t _LSQuitSupportLog(void);

/* The option keys (CFStrings in __DATA,__data, like Apple's). */
extern "C" {
LSS_EXPORT CFStringRef _kLSForceQuitApplicationDoNotInformLibQuitKey = CFSTR("LSForceQuitApplicationDoNotInformLibQuitKey");
LSS_EXPORT CFStringRef _kLSForceQuitApplicationPresentFirstForceQuitDialogKey = CFSTR("LSForceQuitApplicationPresentFirstForceQuitDialogKey");
LSS_EXPORT CFStringRef _kLSForceQuitApplicationSynchronousOperationKey = CFSTR("LSForceQuitApplicationSynchronousOperationKey");
}

typedef void (^LSForceQuitCompletion)(BOOL success, NSError *error);
extern "C" LSS_EXPORT Boolean _LSForceQuitApplication(LSSessionID session, LSASNRef asn, CFDictionaryRef options, LSForceQuitCompletion completion);

/* C++ helpers of CFSupport.mm (same image) */
bool CFArrayApplyBlock(CFArrayRef array, bool (^block)(const void *));
CFDictionaryRef CFDictionaryCreateWithItems(const void *k1, const void *v1, const void *k2, const void *v2);
CFDictionaryRef CFDictionaryCreateCopyWithItem(CFDictionaryRef dict, const void *key, const void *value);

template <typename T> struct CFReleaser {
	T fItem;
	CFReleaser() : fItem(NULL) {}
	~CFReleaser() { if (fItem) CFRelease(fItem); fItem = NULL; }
	CFReleaser(const CFReleaser &o) : fItem(o.fItem) { if (fItem) CFRetain(fItem); }
	CFReleaser &operator=(const CFReleaser &) = delete;
};

/* Typed apply: an item that is NULL or of another type stops the walk (as Apple's template). */
template <typename T> static bool CFArrayApplyBlock(CFArrayRef array, CFTypeID typeID, bool (^block)(T))
{
	CFArrayApplyBlock(array, ^bool(const void *v) {
		if (!v) return false;
		if (typeID && typeID != CFGetTypeID(v)) return false;
		return block((T)v);
	});
	return true;
}

/* ---------------------------------------------------------------- application information */

static NSString *asnDescription(LSASNRef asn)
{
	if (!asn) return @"-";
	uint32_t hl[2];
	_LSASNExtractHighAndLowParts(asn, &hl[0], &hl[1]);
	CFTypeRef name = _LSCopyApplicationInformationItem(kLSDefaultSessionID, asn, _kLSDisplayNameKey);
	if (!name) return [NSString stringWithFormat:@"0x%x-0x%x", hl[0], hl[1]];
	NSString *s = [NSString stringWithFormat:@"0x%x-0x%x \"%@\"", hl[0], hl[1], name];
	CFRelease(name);
	return s;
}

static CFTypeRef copyTypedItem(LSASNRef asn, CFStringRef key, CFTypeID type)
{
	CFTypeRef v = _LSCopyApplicationInformationItem(kLSDefaultSessionID, asn, key);
	if (!v) return NULL;
	CFTypeRef r = NULL;
	if (type == 0 || CFGetTypeID(v) == type) r = CFRetain(v);
	CFRelease(v);
	return r;
}

static int applicationPID(LSASNRef asn)
{
	int pid = 0;
	CFTypeRef v = _LSCopyApplicationInformationItem(kLSDefaultSessionID, asn, _kLSPIDKey);
	CFTypeID t = CFNumberGetTypeID();
	if (v) {
		if (t == 0 || CFGetTypeID(v) == t) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &pid);
		CFRelease(v);
	}
	return pid;
}

static unsigned long long applicationCoalitionID(LSASNRef asn)
{
	long long cid = 0;
	CFTypeRef v = _LSCopyApplicationInformationItem(kLSDefaultSessionID, asn, _kLSApplicationCoalitionIDKey);
	if (v) {
		CFTypeID t = CFNumberGetTypeID();
		if (t == 0 || CFGetTypeID(v) == t) CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &cid);
		CFRelease(v);
	}
	return cid;
}

static bool applicationTypeIs(LSASNRef asn, CFStringRef type)
{
	CFTypeRef v = _LSCopyApplicationInformationItem(kLSDefaultSessionID, asn, _kLSApplicationTypeKey);
	if (!v) return false;
	bool r = CFEqual(v, type);
	CFRelease(v);
	return r;
}
static bool applicationIsForeground(LSASNRef asn) { return applicationTypeIs(asn, _kLSApplicationForegroundTypeKey); }
static bool applicationIsUIElement(LSASNRef asn) { return applicationTypeIs(asn, _kLSApplicationUIElementTypeKey); }

static NSArray *applicationCopyCoalitionPIDs(LSASNRef asn) NS_RETURNS_RETAINED;
static NSArray *applicationCopyCoalitionPIDs(LSASNRef asn) { return (__bridge_transfer NSArray *)copyTypedItem(asn, _kLSApplicationCoalitionPIDsKey, CFArrayGetTypeID()); }
static CFArrayRef applicationCopyApplicationChildrenASNs(LSASNRef asn) { return (CFArrayRef)copyTypedItem(asn, _kLSApplicationChildApplicationASNsArrayKey, CFArrayGetTypeID()); }
static CFArrayRef applicationCopyChildAndRelatedApplicationASNsArray(LSASNRef asn) { return (CFArrayRef)copyTypedItem(asn, _kLSApplicationAllRelatedApplicationASNsArrayKey, CFArrayGetTypeID()); }
static CFArrayRef applicationCopyRelatedCoalitionIDs(LSASNRef asn) { return (CFArrayRef)copyTypedItem(asn, _kLSApplicationRelatedCoalitionsIDsArrayKey, CFArrayGetTypeID()); }
static NSArray *applicationCopyAppAndRelatedCoalitionPIDs(LSASNRef asn)
{
	return CFBridgingRelease(copyTypedItem(asn, _kLSApplicationAllRelatedApplicationCoalitionPIDsArrayKey, CFArrayGetTypeID()));
}

static NSString *applicationDisplayName(LSASNRef asn)
{
	CFTypeRef v = _LSCopyApplicationInformationItem(kLSDefaultSessionID, asn, _kLSDisplayNameKey);
	if (v) {
		CFTypeID t = CFStringGetTypeID();
		if (t == 0 || CFGetTypeID(v) == t) return CFBridgingRelease(v);
		CFRelease(v);
	}
	return nil;
}

static NSURL *applicationBundleURL(LSASNRef asn)
{
	CFTypeRef path = copyTypedItem(asn, _kLSBundlePathKey, CFStringGetTypeID());
	if (!path) return nil;
	CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)path, kCFURLPOSIXPathStyle, false);
	CFRelease(path);
	return CFBridgingRelease(url);
}

/* As Apple: looks the bundle identifier up and always answers false. */
static bool applicationHasControlCenterIcon(LSASNRef asn)
{
	if (!asn) return false;
	CFTypeRef bid = copyTypedItem(asn, kCFBundleIdentifierKey, CFStringGetTypeID());
	if (bid) CFRelease(bid);
	return false;
}

static bool pidIsRunningApplication(int pid)
{
	LSASNRef asn = _LSASNCreateWithPid(kCFAllocatorDefault, pid);
	bool r = _LSIsApplicationRunning(kLSDefaultSessionID, asn);
	if (asn) CFRelease(asn);
	return r;
}

/* ---------------------------------------------------------------- visible windows (SkyLight's accessibility report) */

static bool applicationHasAVisibleWindowOrContext(LSASNRef asn)
{
	int pid;
	if (!asn || (pid = applicationPID(asn)) == 0) return false;
	NSDictionary *report = (__bridge NSDictionary *)SLSGetUserAccessibilityReportForPid(pid);
	if (!report) return false;

	CGDirectDisplayID ids[32];
	uint32_t count = 0;
	if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess) count = 0;
	NSMutableArray *displays = [NSMutableArray arrayWithCapacity:count];
	for (uint32_t i = 0; i < count; i++) [displays addObject:[NSValue valueWithRect:NSRectFromCGRect(CGDisplayBounds(ids[i]))]];
	if (!displays) return false;

	/* a remote context of at least 16x16 */
	NSDictionary *contexts = report[(__bridge NSString *)kSLSUserAccessibilityReportRemoteContextsKey];
	for (id key in contexts) {
		NSDictionary *ctx = contexts[key];
		id shape = ctx[(__bridge NSString *)kSLSUserAccessibilityReportRemoteContextWindowShapeKey];
		if (shape) {
			CGRect b = CGRegionGetBoundingBox((__bridge CGRegionRef)shape);
			if (b.size.width >= 16.0 && b.size.height >= 16.0) return true;
		}
	}

	/* the spaces that can be seen (type < 6, not 3) */
	NSMutableSet *spaces = [NSMutableSet set];
	NSDictionary *spaceInfo = report[(__bridge NSString *)kSLSUserAccessibilityReportSpacesKey];
	for (id key in spaceInfo) {
		NSDictionary *space = spaceInfo[key];
		if (!space) continue;
		unsigned type = (unsigned)[space[(__bridge NSString *)kSLSUserAccessibilityReportSpaceTypeKey] intValue];
		if (type < 6 && type != 3) [spaces addObject:key];
	}

	NSDictionary *windows = report[(__bridge NSString *)kSLSUserAccessibilityReportWindowsKey];
	NSString *orderedOut = (__bridge NSString *)kSLSUserAccessibilityReportWindowOrderingStatusOrderedOut;
	for (id key in windows) {
		NSDictionary *w = windows[key];
		NSString *status;
		/* a status-bar level window (25) of at least 16x16, unless it is ordered out with y >= 0 */
		if ([w[(__bridge NSString *)kSLSUserAccessibilityReportWindowLevelKey] intValue] == 25 &&
		    [w[(__bridge NSString *)kSLSUserAccessibilityReportWindowSpaceIDsKey] count] != 0) {
			status = w[(__bridge NSString *)kSLSUserAccessibilityReportWindowOrderingStatusKey];
			id shape = w[(__bridge NSString *)kSLSUserAccessibilityReportWindowShapeKey];
			CGRect r;
			if (CGRegionIsRect((__bridge CGRegionRef)shape, &r) && !(r.origin.y >= 0.0 && [status isEqualToString:orderedOut])) {
				if (r.size.width >= 16.0 && r.size.height >= 16.0) return true;
			}
		}
		status = w[(__bridge NSString *)kSLSUserAccessibilityReportWindowOrderingStatusKey];
		if ([status isEqualToString:orderedOut]) continue;
		if ([w[(__bridge NSString *)kSLSUserAccessibilityReportWindowLevelKey] intValue] <= -0x7fffffe7) continue;
		if ([w[(__bridge NSString *)kSLSUserAccessibilityReportWindowAlphaKey] floatValue] < 0.5f) continue;
		NSSet *ws = [NSSet setWithArray:w[(__bridge NSString *)kSLSUserAccessibilityReportWindowSpaceIDsKey]];
		if (![spaces intersectsSet:ws]) continue;
		id visible = w[(__bridge NSString *)kSLSUserAccessibilityReportWindowScreenVisibleShapeKey];
		if (visible) {
			CGRect b = CGRegionGetBoundingBox((__bridge CGRegionRef)visible);
			if (!(b.size.width < 32.0) && !(b.size.height < 32.0)) return true;
		}
		/* else: the window shape moved by the window transform, against each display */
		CGRect bounds = CGRegionGetBoundingBox((__bridge CGRegionRef)w[(__bridge NSString *)kSLSUserAccessibilityReportWindowShapeKey]);
		NSValue *tv = w[(__bridge NSString *)kSLSUserAccessibilityReportWindowTransformKey];
		struct CATransform3D t;
		if (tv) t = [tv CATransform3DValue]; else memset(&t, 0, sizeof t);
		CGRect moved = CA_CGRectApplyTransform(bounds, t);
		for (NSValue *d in displays) {
			CGRect i = CGRectIntersection(moved, NSRectToCGRect([d rectValue]));
			if (i.size.width >= 32.0 && i.size.height >= 32.0) return true;
		}
	}
	return false;
}

static bool applicationRepresentsAnApplicationWhichIsUserVisible(LSASNRef asn)
{
	if (!asn) return false;
	if (applicationIsForeground(asn)) {
		os_log_debug(_LSQuitSupportLog(), "applicationRepresentsAnApplicationWhichIsUserVisible: app=%{public}@ is a Foreground application, ignoring.", asnDescription(asn));
		return true;
	}
	if (applicationIsUIElement(asn) && applicationHasAVisibleWindowOrContext(asn)) {
		os_log_debug(_LSQuitSupportLog(), "applicationRepresentsAnApplicationWhichIsUserVisible: app=%{public}@ in coalition is a uielement with a visible window", asnDescription(asn));
		return true;
	}
	applicationHasControlCenterIcon(asn);
	return false;
}

/* ---------------------------------------------------------------- launchd jobs */

static id _btmItemForPlistPath(NSString *path, long type)
{
	if (!path) return nil;
	NSURL *url = [NSURL fileURLWithPath:path];
	id ident = BTMItemIdentifierForURLAndType(type, url);
	NSError *error = nil;
	return [[BTMManager shared] getItemWithIdentifier:ident uid:geteuid() error:&error];
}

static NSString *OSLaunchdJobDescription(OSLaunchdJob *job)
{
	LASSProperties4RB *p = [LASSProperties4RB propertiesForJob:job error:nil];
	if (p) return [NSString stringWithFormat:@"[OSLaunchdJob %@ : %@]", [p path], [p label]];
	OSLaunchdJobInfo *info = [job getCurrentJobInfo];
	if (!info) return [job description];
	return [NSString stringWithFormat:@"[OSLaunchdJob %@ : %@]", [info instance], [info program]];
}

static bool launchJobIsAllowedInBackground(LSASNRef asn, OSLaunchdJob *job)
{
	LASSProperties4RB *p = nil;
	if (job) {
		NSError *error = nil;
		p = [LASSProperties4RB propertiesForJob:job error:&error];
		if (!p) os_log_error(_LSQuitSupportLog(), "Failed to get launch properties for %@: %@", OSLaunchdJobDescription(job), error);
	}
	int host = [p hostPID];
	if (host > 1) {
		os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ hostPid=%{public}d job=%{public}@ PID domain job allowed by quit.", asnDescription(asn), host, [p label]);
		return true;
	}
	switch ([p serviceType]) {
	case 1:
		if (_btmItemForPlistPath([p path], 0x10) || _btmItemForPlistPath([p path], 0x10010)) {
			os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ job %{public}@ daemon managed by BTM.", asnDescription(asn), [p label]);
			return true;
		}
		os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ job %{public}@ daemon not managed by BTM so is not allowed.", asnDescription(asn), [p label]);
		return false;
	case 2:
		if (_btmItemForPlistPath([p path], 8) || _btmItemForPlistPath([p path], 0x10008)) {
			os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ job %{public}@ agent managed by BTM.", asnDescription(asn), [p label]);
			return true;
		}
		os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ job %{public}@ agent not managed by BTM so is not allowed.", asnDescription(asn), [p label]);
		return false;
	case 3: case 5: case 6:
		os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ job %{public}@ allowed by quit", asnDescription(asn), [p label]);
		return true;
	case 4: {
		NSArray *exceptions = @[ @"com.apple.CoreSimulator.simdiskimaged", @"com.apple.Siri.agent", @"com.apple.install.osinstallersetupd",
			@"com.apple.install.osisstashhelper", @"com.apple.sear.ac-sign.agent" ];
		if ([exceptions containsObject:[p label]]) {
			os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ job %{public}@ allowed by exception, submitted.", asnDescription(asn), [p label]);
			return true;
		}
		os_log_debug(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ job %{public}@ not allowed, submitted.", asnDescription(asn), [p label]);
		return false;
	}
	default:
		return true;
	}
}

static NSArray *oneShotJobsForCoalition(LSASNRef asn, unsigned long long coalition)
{
	if (!asn) return nil;
	NSMutableArray *out = [NSMutableArray new];
	NSError *error = nil;
	NSArray *jobs = [OSLaunchdJob copyJobsLoadedByCoalition:coalition error:&error];
	if (!jobs)
		os_log_error(_LSQuitSupportLog(), "launchJobCheck: app=%{public}@ coalitionID=%{public}lld failed to get coalition jobs, error=%{public}@.", asnDescription(asn), coalition, error);
	else
		for (OSLaunchdJob *job in jobs)
			if (!launchJobIsAllowedInBackground(asn, job)) [out addObject:job];
	return [out count] ? [out copy] : nil;
}

static bool applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses(LSASNRef asn)
{
	__block bool lingering = false;
	if (!asn) return false;
	NSArray *pids = applicationCopyAppAndRelatedCoalitionPIDs(asn);
	if ([pids count])
		os_log_debug(_LSQuitSupportLog(), "applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses: app=%{public}@ has %{public}d coalition and related coalition pids", asnDescription(asn), (int)[pids count]);
	[pids enumerateObjectsUsingBlock:^(NSNumber *n, NSUInteger idx, BOOL *stop) {
		int pid = [n intValue];
		if (pid == 0) { *stop = lingering; return; }
		if (pidIsRunningApplication(pid)) {
			LSASNRef a = _LSASNCreateWithPid(kCFAllocatorDefault, pid);
			if (applicationIsForeground(a))
				os_log_debug(_LSQuitSupportLog(), "applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses: app=%{public}@ related coalitions pid %{public}d is a foreground app so this app does not yet have lingering subprocesses.", asnDescription(asn), pid);
			else if (applicationRepresentsAnApplicationWhichIsUserVisible(a))
				os_log_debug(_LSQuitSupportLog(), "applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses: app=%{public}@ related coalitions pid %{public}d is an app which is user-visible so this app does not yet have lingering subprocesses.", asnDescription(asn), pid);
			else
				lingering = true;
			if (a) CFRelease(a);
		}
		if (!lingering) {
			OSLaunchdJob *job = [OSLaunchdJob copyJobWithPid:pid];
			if (!job) {
				os_log_debug(_LSQuitSupportLog(), "applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses: app=%{public}@ child coalition pid %{public}d is non-foreground so app still has lingering subprocesses.", asnDescription(asn), pid);
				lingering = true;
			} else if (!launchJobIsAllowedInBackground(asn, job)) {
				os_log_debug(_LSQuitSupportLog(), "applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses: app=%{public}@ related coalition pid %{public}d is a job but not managed by launchd so this application has a lingering subprocess, job=%{public}@.", asnDescription(asn), pid, job);
				lingering = true;
			} else
				os_log_debug(_LSQuitSupportLog(), "applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses: app=%{public}@ child coalition pid %{public}d is a job managed by launchd so this app does not yet have lingering subprocesses, job=%{public}@", asnDescription(asn), pid, job);
		}
		*stop = lingering;
	}];
	return lingering;
}

static NSString *arrayString(NSArray *array)
{
	NSMutableString *s = [NSMutableString new];
	[s appendString:@"[ "];
	[array enumerateObjectsUsingBlock:^(NSObject *o, NSUInteger idx, BOOL *stop) {
		if (idx) [s appendString:@", "];
		[s appendString:[o description]];
	}];
	[s appendString:@" ]"];
	return [s copy];
}

static NSString *dictionaryString(CFDictionaryRef dict)
{
	NSString *d = [(__bridge NSDictionary *)dict description];
	if ([d containsString:@"\n"]) d = [d stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
	return d;
}

/* ---------------------------------------------------------------- LSExitedApplication */

static os_unfair_lock sExitedApplicationsSetLock = OS_UNFAIR_LOCK_INIT;

LSS_EXPORT @interface LSExitedApplication : NSObject {
	CFReleaser<LSASNRef> _asnRef;
	NSDictionary *_info;
}
@property (readonly, nonatomic) LSASNRef asnRef;
@property (readonly, nonatomic) NSString *displayName;
@property (readonly, nonatomic) NSString *bundleIdentifier;
@property (readonly, nonatomic) NSDictionary *info;
@property (readonly, nonatomic) unsigned long long coalitionID;
@property (readonly, nonatomic) NSString *description;
+ (instancetype)createApplicationWithASNRef:(LSASNRef)asn;
+ (instancetype)createApplicationWithASNRef:(LSASNRef)asn info:(NSDictionary *)info;
+ (void)removeApplication:(LSExitedApplication *)app;
+ (LSExitedApplication *)findApplicationWithASNRef:(LSASNRef)asn;
+ (BOOL)stillTrackingExitedApplication:(LSExitedApplication *)app;
+ (BOOL)enumerateExitedApplications:(void (^)(LSExitedApplication *app, BOOL *stop))block;
+ (dispatch_queue_t)quitReallySchedulingQueue;
+ (void)addExitedApplication:(LSExitedApplication *)app;
+ (void)removeExitedApplication:(LSExitedApplication *)app;
+ (BOOL)containsExitedApplication:(LSExitedApplication *)app;
+ (LSExitedApplication *)findExitedApplication:(LSASNRef)asn;
+ (NSSet *)copyExitedApplicationsSet;
+ (NSMutableSet *)getExitedApplicationsSet;
+ (NSString *)statusString;
- (instancetype)initWithASNRef:(LSASNRef)asn info:(NSDictionary *)info;
- (BOOL)isForeground;
- (BOOL)isUIElement;
- (NSURL *)bundleURL;
- (NSArray *)coalitionPIDsArray;
- (BOOL)hasControlCenterItem;
- (BOOL)hasAVisibleWindowOrContext;
- (BOOL)stillRunning;
- (NSArray *)childrenAppASNsArray;
- (void)killSubordinateProcesses;
- (NSArray *)oneShotJobs;
- (void)unloadLaunchdJobs;
- (void)forceQuitAppURL:(NSURL *)url;
- (BOOL)doesApplicationStillHaveRunningCoalitionProcesses;
- (BOOL)doesApplicationStillHaveRunningLaunchdJobs;
@end

@implementation LSExitedApplication
@synthesize info = _info;

- (instancetype)initWithASNRef:(LSASNRef)asn info:(NSDictionary *)info
{
	self = [super init];
	if (self) {
		if (asn) CFRetain(asn);
		LSASNRef old = _asnRef.fItem;
		if (old != asn) { _asnRef.fItem = asn; asn = old; }
		if (asn) CFRelease(asn);
		_info = info;
		[[self class] addExitedApplication:self];
	}
	return self;
}

- (void)dealloc
{
	[[self class] removeExitedApplication:self];
}

+ (instancetype)createApplicationWithASNRef:(LSASNRef)asn
{
	if (!asn) return nil;
	CFDictionaryRef info = _LSCopyApplicationInformation(kLSDefaultSessionID, asn, NULL);
	if (!info) return nil;
	LSExitedApplication *app = [[self alloc] initWithASNRef:asn info:(__bridge NSDictionary *)info];
	CFRelease(info);
	return app;
}

+ (instancetype)createApplicationWithASNRef:(LSASNRef)asn info:(NSDictionary *)info
{
	if (!info || !asn) return nil;
	return [[self alloc] initWithASNRef:asn info:info];
}

+ (void)removeApplication:(LSExitedApplication *)app
{
	if (app) [self removeExitedApplication:app];
}

- (BOOL)isForeground { return applicationIsForeground(_asnRef.fItem); }
- (BOOL)isUIElement { return applicationIsUIElement(_asnRef.fItem); }
- (LSASNRef)asnRef { return _asnRef.fItem; }
- (NSString *)displayName { return [self info][(__bridge NSString *)_kLSDisplayNameKey]; }
- (NSString *)bundleIdentifier { return [self info][(__bridge NSString *)kCFBundleIdentifierKey]; }

- (NSURL *)bundleURL
{
	NSString *path = [self info][(__bridge NSString *)_kLSBundlePathKey];
	return path ? [NSURL fileURLWithPath:path isDirectory:NO] : nil;
}

- (unsigned long long)coalitionID { return applicationCoalitionID(_asnRef.fItem); }
- (NSArray *)coalitionPIDsArray { return applicationCopyCoalitionPIDs([self asnRef]); }

- (BOOL)hasControlCenterItem
{
	if (_LSIsApplicationRunning(kLSDefaultSessionID, [self asnRef]) && [self isUIElement])
		return applicationHasControlCenterIcon([self asnRef]);
	return NO;
}

- (BOOL)hasAVisibleWindowOrContext { return applicationHasAVisibleWindowOrContext(_asnRef.fItem); }
- (BOOL)stillRunning { return [[self class] stillTrackingExitedApplication:self]; }
- (NSArray *)childrenAppASNsArray { return CFBridgingRelease(applicationCopyApplicationChildrenASNs([self asnRef])); }

- (void)killSubordinateProcesses
{
	_LSForceQuitApplication(kLSDefaultSessionID, [self asnRef], NULL, ^(BOOL success, NSError *error) {
		if (!success)
			os_log_error(_LSQuitSupportLog(), "schedule: Failed to kill application %{public}@, error=%{public}@", self, error);
		else
			os_log_info(_LSQuitSupportLog(), "schedule: Successfully killed application %{public}@", self);
	});
}

- (NSArray *)oneShotJobs
{
	unsigned long long cid = [self coalitionID];
	if (!cid) return nil;
	NSArray *jobs = oneShotJobsForCoalition([self asnRef], cid);
	if (!jobs || ![jobs count]) return nil;
	return [jobs copy];
}

- (void)unloadLaunchdJobs
{
	NSArray *jobs = [self oneShotJobs];
	for (OSLaunchdJob *job in jobs) {
		os_log_info(_LSQuitSupportLog(), "unloadJobs: unloading job %{public}@", OSLaunchdJobDescription(job));
		NSError *error = nil;
		if (![job remove:&error] && [error code] != 36) {
			os_log_error(_LSQuitSupportLog(), "Failed to remove job %@ with error %@", OSLaunchdJobDescription(job), error);
			__builtin_trap(); /* as Apple */
		}
	}
}

- (void)forceQuitAppURL:(NSURL *)url
{
	if (url && [self stillRunning]) {
		os_log_info(_LSQuitSupportLog(), "forceQuitAppURL: app=%{public}@ forcing quit for URL=%{public}@", [self description], url);
		[self killSubordinateProcesses];
	}
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"\"%@ \"%@\"", _asnRef.fItem, [self displayName]];
}

+ (LSExitedApplication *)findApplicationWithASNRef:(LSASNRef)asn { return [self findExitedApplication:asn]; }
+ (BOOL)stillTrackingExitedApplication:(LSExitedApplication *)app { return app ? [self containsExitedApplication:app] : NO; }

- (BOOL)doesApplicationStillHaveRunningCoalitionProcesses
{
	os_log_info(_LSQuitSupportLog(), "check: app=%{public}@ about to check for running coalition processes", [self description]);
	if (![self stillRunning]) return NO;
	os_log_debug(_LSQuitSupportLog(), "check: app=%{public}@ still running", [self description]);
	return applicationStillHasRunningCoalitionOrRelatedCoalitionProcesses([self asnRef]);
}

- (BOOL)doesApplicationStillHaveRunningLaunchdJobs
{
	if (![self stillRunning]) return NO;
	NSArray *jobs = [self oneShotJobs];
	if (![jobs count]) return NO;
	os_log_debug(_LSQuitSupportLog(), "check: app=%{public}@ loaded jobs is non-empty so this app still has lingering subprocesses, %{public}@", [self description], jobs);
	return YES;
}

+ (BOOL)enumerateExitedApplications:(void (^)(LSExitedApplication *, BOOL *))block
{
	dispatch_assert_queue([self quitReallySchedulingQueue]);
	NSSet *set = [self copyExitedApplicationsSet];
	if (set) [set enumerateObjectsUsingBlock:^(id obj, BOOL *stop) { block(obj, stop); }];
	return set != nil;
}

+ (dispatch_queue_t)quitReallySchedulingQueue
{
	static dispatch_once_t sOnce;
	static dispatch_queue_t sResult;
	dispatch_once(&sOnce, ^{ sResult = dispatch_queue_create("quitReallyScheduling", NULL); });
	return sResult;
}

+ (void)addExitedApplication:(LSExitedApplication *)app
{
	os_unfair_lock_lock(&sExitedApplicationsSetLock);
	[[self getExitedApplicationsSet] addObject:app];
	os_unfair_lock_unlock(&sExitedApplicationsSetLock);
}

+ (void)removeExitedApplication:(LSExitedApplication *)app
{
	os_unfair_lock_lock(&sExitedApplicationsSetLock);
	[[self getExitedApplicationsSet] removeObject:app];
	os_unfair_lock_unlock(&sExitedApplicationsSetLock);
}

+ (BOOL)containsExitedApplication:(LSExitedApplication *)app
{
	os_unfair_lock_lock(&sExitedApplicationsSetLock);
	BOOL r = [[self getExitedApplicationsSet] containsObject:app];
	os_unfair_lock_unlock(&sExitedApplicationsSetLock);
	return r;
}

+ (LSExitedApplication *)findExitedApplication:(LSASNRef)asn
{
	if (!asn) return nil;
	LSExitedApplication *found = nil;
	os_unfair_lock_lock(&sExitedApplicationsSetLock);
	for (LSExitedApplication *app in [self getExitedApplicationsSet])
		if (CFEqual(asn, [app asnRef])) { found = app; break; }
	os_unfair_lock_unlock(&sExitedApplicationsSetLock);
	return found;
}

+ (NSSet *)copyExitedApplicationsSet
{
	os_unfair_lock_lock(&sExitedApplicationsSetLock);
	NSSet *s = [[self getExitedApplicationsSet] copy];
	os_unfair_lock_unlock(&sExitedApplicationsSetLock);
	return s;
}

+ (NSMutableSet *)getExitedApplicationsSet
{
	static dispatch_once_t sOnce;
	static NSMutableSet *sResult;
	dispatch_once(&sOnce, ^{ sResult = [NSMutableSet set]; });
	return sResult;
}

+ (NSString *)statusString
{
	__block NSString *result = nil;
	dispatch_assert_queue_not([self quitReallySchedulingQueue]);
	dispatch_sync([self quitReallySchedulingQueue], ^{
		NSSet *set = [self copyExitedApplicationsSet];
		if (!set || ![set count]) return;
		NSMutableString *s = [NSMutableString stringWithFormat:@"LSExitedApplicationStatus  %@\n", [NSDate now]];
		[set enumerateObjectsUsingBlock:^(LSExitedApplication *app, BOOL *stop) {
			[s appendFormat:@" - %@\n", [app description]];
			NSArray *children = [app childrenAppASNsArray];
			if (children) [s appendFormat:@" -- childrenASNs=%@\n", arrayString(children)];
			NSArray *pids = [app coalitionPIDsArray];
			if (pids) [s appendFormat:@" -- coalitionID=%lld coalitionPIDs=%@\n", [app coalitionID], arrayString(pids)];
			NSArray *jobs = [app oneShotJobs];
			if (jobs) [s appendFormat:@" -- coalitionID=%lld jobs=%@\n", [app coalitionID], arrayString(jobs)];
		}];
		result = [s copy];
	});
	return result;
}
@end

/* ---------------------------------------------------------------- force quit */

static dispatch_queue_t forceQuitApplicationQueue(void)
{
	static dispatch_once_t sOnce;
	static dispatch_queue_t sResult;
	dispatch_once(&sOnce, ^{ sResult = dispatch_queue_create("forceQuitApplicationQ", NULL); });
	return sResult;
}

static bool boolOptionWithDefault(CFDictionaryRef options, CFStringRef key, bool def)
{
	if (options && CFDictionaryContainsKey(options, key)) return CFEqual(CFDictionaryGetValue(options, key), kCFBooleanTrue);
	return def;
}

static NSError *pidError(NSString *domain, NSInteger code, int pid)
{
	return [NSError errorWithDomain:domain code:code userInfo:@{ @"pid": @(pid) }];
}

/* SIGTERM, or SIGKILL when hard.  An exited process (ESRCH) counts as success. */
static bool killPID(int pid, bool hard, NSError *__autoreleasing *error)
{
	if (pid < 2) { *error = pidError(NSOSStatusErrorDomain, -50, pid); return false; }
	if (kill(pid, hard ? SIGKILL : SIGTERM) == 0) {
		os_log_debug(_LSQuitSupportLog(), "killPID: pid=%{public}d hard=%{BOOL}d succeeded", pid, hard);
		return true;
	}
	int e = errno;
	if (e == EPERM) {
		os_log_error(_LSQuitSupportLog(), "killPID: EPERM, pid=%{public}d no permission.", pid);
		*error = pidError(NSPOSIXErrorDomain, 1, pid);
	} else if (e == EINVAL) {
		os_log_error(_LSQuitSupportLog(), "killPID: EPERM, pid=%{public}d EINVAL.", pid);
		*error = pidError(NSPOSIXErrorDomain, 22, pid);
	} else if (e == ESRCH) {
		os_log_debug(_LSQuitSupportLog(), "killPID: pid=%{public}d has already exited, ignoring", pid);
		return true;
	} else {
		os_log_error(_LSQuitSupportLog(), "killPID: pid=%{public}d errno=%{public}d.", pid, e);
		*error = pidError(NSPOSIXErrorDomain, e, pid);
	}
	return false;
}

static void forciblyRemoveApplication(LSASNRef asn)
{
	if (!asn) return;
	os_log_info(_LSQuitSupportLog(), "forciblyRemoveApplication: app=%{public}@", asnDescription(asn));
	int err = _LSApplicationQuitting(kLSDefaultSessionID, asn, 0x89);
	if (err)
		os_log_error(_LSQuitSupportLog(), "forciblyRemoveApplication: app=%{public}@ err=%{public}ld%{public}s", asnDescription(asn), (long)err, GetMacOSStatusErrorString(err));
}

/* Options: "remove" (default true: tell LaunchServices the application quit), DoNotInformLibQuit (default true;
 * as Apple, true is what makes it call LQReportHang), Synchronous (default false: the work is redone on a
 * global queue with the key set), PresentFirstForceQuitDialog (read, not used).  Always returns true; the
 * result goes to the completion block. */
Boolean _LSForceQuitApplication(LSSessionID session, LSASNRef asn, CFDictionaryRef options, LSForceQuitCompletion completion)
{
	os_log_info(_LSQuitSupportLog(), "_LSForceQuitApplication(asn=%{public}@ options=%{public}@", asnDescription(asn), dictionaryString(options));
	if (!completion || !asn || !session) {
		if (completion) completion(NO, [NSError errorWithDomain:NSOSStatusErrorDomain code:-50 userInfo:@{}]);
		return true;
	}
	bool remove = boolOptionWithDefault(options, CFSTR("remove"), true);
	bool informLibQuit = boolOptionWithDefault(options, _kLSForceQuitApplicationDoNotInformLibQuitKey, true);
	bool synchronous = boolOptionWithDefault(options, _kLSForceQuitApplicationSynchronousOperationKey, false);
	boolOptionWithDefault(options, _kLSForceQuitApplicationPresentFirstForceQuitDialogKey, false);

	if (!synchronous) {
		CFDictionaryRef syncOptions = CFDictionaryCreateCopyWithItem(options, _kLSForceQuitApplicationSynchronousOperationKey, kCFBooleanTrue);
		CFRetain(asn);
		CFReleaser<CFDictionaryRef> opts;
		opts.fItem = syncOptions;
		if (syncOptions) CFRetain(syncOptions);
		dispatch_async(dispatch_get_global_queue(0, 0), ^{
			_LSForceQuitApplication(session, asn, opts.fItem, ^(BOOL success, NSError *error) {
				os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: Completed async _forceQuit, calling completion block with %{BOOL}d eror=%{public}@", success, error);
				completion(success, error);
			});
			if (asn) CFRelease(asn);
		});
		if (syncOptions) CFRelease(syncOptions);
		return true;
	}

	NSMutableArray *errors = [NSMutableArray new];
	int pid = applicationPID(asn);
	unsigned long long coalition = applicationCoalitionID(asn);
	os_log_info(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ appPID=%{public}d coalition=%{public}lld option=%{public}@", asn, pid, coalition, dictionaryString(options));
	__block BOOL success = YES;
	dispatch_semaphore_t libquitDone = nil;
	if (pid != 0 && informLibQuit) {
		libquitDone = dispatch_semaphore_create(0);
		os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: calling LQReportHang for pid=%{public}d", pid);
		dispatch_semaphore_t sema = libquitDone;
		LQReportHang(pid, (__bridge void *)forceQuitApplicationQueue(), ^{
			os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: finished LQReportHang for pid=%{public}d", pid);
			dispatch_semaphore_signal(sema);
		});
	}

	NSArray *pids = applicationCopyAppAndRelatedCoalitionPIDs(asn);
	if (pids) {
		if ([pids count])
			os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ killing coalition pids %{public}@.", asn, arrayString(pids));
		bool hard = false;
		[pids enumerateObjectsUsingBlock:^(NSNumber *n, NSUInteger idx, BOOL *stop) {
			int p = [n intValue];
			if (p == 0) return;
			LSASNRef a = _LSASNCreateWithPid(kCFAllocatorDefault, p);
			if (p == pid || CFEqual(asn, a))
				os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: Skipping pid %{public}d in coalition because it matches the application being killed, %{public}@.", p, asn);
			else if (applicationIsForeground(a))
				os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: Skipping pid %{public}d in coalition because it is a foreground application, app=%{public}@.", p, asnDescription(a));
			else if (applicationIsUIElement(a) && applicationRepresentsAnApplicationWhichIsUserVisible(a))
				os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: Skipping pid %{public}d in coalition because it is a uielement application with a visible attribute, app=%{public}@.", p, asnDescription(a));
			else {
				os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: killing coalition %{public}lld pid %{public}d", coalition, p);
				NSError *error = nil;
				if (!killPID(p, hard, &error)) { [errors addObject:error]; success = NO; }
			}
			if (a) CFRelease(a);
		}];
	}

	if (pid != 0) {
		if (libquitDone) {
			os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ blocking waiting for LQReportHang for pid %{public}d.", asnDescription(asn), pid);
			dispatch_semaphore_wait(libquitDone, DISPATCH_TIME_FOREVER);
		}
		os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ killing with SIGTERM main application pid %{public}d.", asnDescription(asn), pid);
		dispatch_semaphore_t died = dispatch_semaphore_create(0);
		dispatch_queue_t q = dispatch_queue_create("procDeath", NULL);
		dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, q);
		if (src) {
			CFRetain(asn);
			dispatch_source_set_event_handler(src, ^{
				os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ notified about the death of main application pid %{public}d.", asnDescription(asn), pid);
				dispatch_semaphore_signal(died);
				dispatch_source_cancel(src);
			});
			dispatch_source_set_cancel_handler(src, ^{
				os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ cancellation handler for the death of main application pid %{public}d.", asnDescription(asn), pid);
				if (asn) CFRelease(asn);
			});
			dispatch_resume(src);
		}
		NSError *error = nil;
		if (killPID(pid, false, &error) && dispatch_semaphore_wait(died, dispatch_time(DISPATCH_TIME_NOW, 3000000000LL)) != 0) {
			os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@, timeout waiting for SIGTERM so sending SIGKILL on main application pid %{public}d.", asnDescription(asn), pid);
			NSError *hardError = error;
			bool ok = killPID(pid, true, &hardError);
			error = ok ? nil : hardError;
		}
		os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ cancelling dispatch source after completion about the death of main application pid %{public}d.", asnDescription(asn), pid);
		dispatch_source_cancel(src);
		if (error) {
			os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ failed attempting to kill main application pid %{public}d with error %{public}@.", asnDescription(asn), pid, error);
			[errors addObject:error];
			success = NO;
		}
	}

	if (remove) {
		os_log_debug(_LSQuitSupportLog(), "_LSForceQuitApplication: asn=%{public}@ forcibly removing from application list.", asnDescription(asn));
		forciblyRemoveApplication(asn);
	}
	if (!success)
		completion(NO, [NSError errorWithDomain:NSOSStatusErrorDomain code:-600 userInfo:@{ NSMultipleUnderlyingErrorsKey: errors }]);
	else
		completion(YES, nil);
	return true;
}

extern "C" LSS_EXPORT Boolean _LSApplicationHasAVisibleWindowOrContext(LSASNRef asn)
{
	if (!asn) return false;
	return applicationHasAVisibleWindowOrContext(asn);
}

/* ---------------------------------------------------------------- BTM force-quit handler */

LSS_EXPORT @interface BTMManagerSupport : NSObject <BTMForceQuitHandler>
@end

@implementation BTMManagerSupport
- (void)forceQuitAppURL:(NSURL *)url
{
	os_log_info(_LSQuitSupportLog(), "forceQuitAppURLFromBTM:%{private}@, terminating applications running because of a notification from BTM", url);
	if (!url) return;
	static dispatch_once_t sOnce;
	static dispatch_queue_t q;
	dispatch_once(&sOnce, ^{ q = dispatch_queue_create("btmForceQuitQ", NULL); });
	dispatch_async(q, ^{
		CFDictionaryRef opts = CFDictionaryCreateWithItems(_kLSApplicationCopyMatchingApplicationsIncludeExitedApplicationsKey, kCFBooleanTrue,
			_kLSApplicationExitedButHasRemainingCoalitionPIDsOrNonForegroundChildrenApplicationsKey, kCFBooleanTrue);
		CFArrayRef apps = _LSCopyMatchingApplications(kLSDefaultSessionID, opts);
		if (apps) {
			CFArrayApplyBlock<LSASNRef>(apps, _LSASNGetTypeID(), ^bool(LSASNRef asn) {
				NSURL *bundleURL = applicationBundleURL(asn);
				if (!bundleURL) return true;
				BOOL match;
				if (bundleURL == url) match = YES;
				else {
					id a = nil, b = nil;
					if ([bundleURL getResourceValue:&a forKey:NSURLFileResourceIdentifierKey error:nil] &&
					    [url getResourceValue:&b forKey:NSURLFileResourceIdentifierKey error:nil])
						match = [a isEqual:b];
					else
						match = [bundleURL isEqual:url] || [[bundleURL path] isEqual:[url path]];
				}
				if (!match) return true;
				os_log_info(_LSQuitSupportLog(), "forceQuitAppURLFromBTM: app=%{public}@ being force quit.", asnDescription(asn));
				dispatch_semaphore_t done = dispatch_semaphore_create(0);
				_LSForceQuitApplication(kLSDefaultSessionID, asn, NULL, ^(BOOL success, NSError *error) {
					if (!success)
						os_log_error(_LSQuitSupportLog(), "forceQuitAppURLFromBTM: app=%{public}@ not terminated, error=%{public}@.", asnDescription(asn), error);
					else
						os_log_debug(_LSQuitSupportLog(), "forceQuitAppURLFromBTM: app=%{public}@ successfully terminated.", asnDescription(asn));
					dispatch_semaphore_signal(done);
				});
				dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
				return true;
			});
			CFRelease(apps);
		}
		if (opts) CFRelease(opts);
	});
}
@end

/* ---------------------------------------------------------------- sysdiagnose */

static NSDictionary *appDictionary(LSASNRef asn);

static void addApplications(NSMutableDictionary *into, CFArrayRef asns)
{
	CFArrayApplyBlock<LSASNRef>(asns, _LSASNGetTypeID(), ^bool(LSASNRef a) {
		NSString *k = asnDescription(a);
		if (k) { NSDictionary *d = appDictionary(a); if (d) into[k] = d; }
		return true;
	});
}

static NSDictionary *appDictionary(LSASNRef asn)
{
	if (!asn) return nil;
	NSMutableDictionary *d = [NSMutableDictionary new];
	int pid = applicationPID(asn);
	NSString *name = applicationDisplayName(asn);
	d[@"name"] = name ?: @"-";
	d[@"type"] = applicationIsForeground(asn) ? @"foreground" : (applicationIsUIElement(asn) ? @"uielement" : @"background");
	if (pid) d[@"pid"] = @(pid);
	if (applicationRepresentsAnApplicationWhichIsUserVisible(asn)) d[@"uservisible"] = @YES;
	if (applicationHasAVisibleWindowOrContext(asn)) d[@"visiblewindoworcontext"] = @YES;
	applicationHasControlCenterIcon(asn);

	/* children that have a visible window (Apple's filter block) */
	CFArrayRef children = applicationCopyApplicationChildrenASNs(asn);
	if (children) {
		CFMutableArrayRef kept = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
		CFArrayApplyBlock<LSASNRef>(children, _LSASNGetTypeID(), ^bool(LSASNRef a) {
			if (applicationHasAVisibleWindowOrContext(a)) CFArrayAppendValue(kept, a);
			return true;
		});
		if (kept) {
			CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, kept);
			CFRelease(kept);
			CFRelease(children);
			children = copy;
			if (copy) {
				NSMutableDictionary *c = [NSMutableDictionary new];
				addApplications(c, copy);
				if ([c count]) d[@"childApps"] = [c copy];
			}
		}
		if (children) CFRelease(children);
	}
	children = applicationCopyApplicationChildrenASNs(asn);
	if (children) {
		NSMutableDictionary *c = [NSMutableDictionary new];
		addApplications(c, children);
		if ([c count]) d[@"childApps"] = [c copy];
		CFRelease(children);
	}
	CFArrayRef related = applicationCopyChildAndRelatedApplicationASNsArray(asn);
	if (related) {
		NSMutableDictionary *c = [NSMutableDictionary new];
		addApplications(c, related);
		if ([c count]) d[@"relatedApps"] = [c copy];
		CFRelease(related);
	}
	unsigned long long cid = applicationCoalitionID(asn);
	if (!cid) return [d copy];
	d[@"coalitionID"] = @(cid);
	NSArray *cpids = applicationCopyCoalitionPIDs(asn);
	if (cpids) {
		NSMutableDictionary *c = [NSMutableDictionary new];
		CFArrayApplyBlock<CFNumberRef>((__bridge CFArrayRef)cpids, CFNumberGetTypeID(), ^bool(CFNumberRef n) {
			int p = 0;
			if (!n || !CFNumberGetValue(n, kCFNumberIntType, &p) || p == 0 || p == pid) return true;
			NSDictionary *info = nil;
			if (pidIsRunningApplication(p)) {
				LSASNRef a = _LSASNCreateWithPid(kCFAllocatorDefault, p);
				info = appDictionary(a);
				if (a) CFRelease(a);
			}
			if (!info) {
				char pname[4096];
				if (proc_name(p, pname, sizeof pname) < 1) info = @{ @"pid": @(p) };
				else info = @{ @"pid": @(p), @"name": [NSString stringWithCString:pname encoding:NSUTF8StringEncoding] };
			}
			c[@(p)] = info;
			return true;
		});
		if ([c count]) d[@"coalitionPIDs"] = [c copy];
	}
	CFArrayRef rids = applicationCopyRelatedCoalitionIDs(asn);
	if (rids) { d[@"relatedCoalitionIDs"] = (__bridge NSArray *)rids; CFRelease(rids); }
	CFArrayRef rpids = (CFArrayRef)copyTypedItem(asn, _kLSApplicationRelatedApplicationCoalitionPIDsArrayKey, CFArrayGetTypeID());
	if (rpids) { d[@"relatedCoalitionPIDS"] = (__bridge_transfer NSArray *)rpids; }
	NSArray *jobs = oneShotJobsForCoalition(asn, cid);
	if (jobs) {
		NSMutableArray *j = [NSMutableArray new];
		[jobs enumerateObjectsUsingBlock:^(OSLaunchdJob *job, NSUInteger idx, BOOL *stop) {
			NSString *s = OSLaunchdJobDescription(job);
			if (s) [j addObject:s];
		}];
		if ([j count]) d[@"jobs"] = [j copy];
	}
	return [d copy];
}

static os_state_data_t stateData(id plist, const char *title)
{
	NSData *data = CFBridgingRelease(CFPropertyListCreateData(kCFAllocatorDefault, (__bridge CFPropertyListRef)plist, kCFPropertyListBinaryFormat_v1_0, 0, NULL));
	if ([data length] >= 0xffffffff) return NULL;
	os_state_data_t sd = (os_state_data_t)malloc([data length] + 200);
	sd->osd_type = OS_STATE_DATA_SERIALIZED_NSCF_OBJECT;
	sd->osd_data_size = (uint32_t)[data length];
	memset(&sd->osd_decoder, 0, sizeof sd->osd_decoder + sizeof sd->osd_title);
	strlcpy(sd->osd_title, title, 64);
	memcpy(sd->osd_data, [data bytes], sd->osd_data_size);
	return sd;
}

static os_state_handle_t sStateHandle;

static void registerSysdiagonoseHandler(NSDictionary *options, NSError *__autoreleasing *error)
{
	static dispatch_once_t sOnce;
	dispatch_once(&sOnce, ^{
		sStateHandle = os_state_add_handler((__bridge void *)dispatch_get_global_queue(0, 0), ^os_state_data_t(os_state_hints_t hints) {
			NSString *status = [LSExitedApplication statusString];
			if (!status) return NULL;
			return stateData(status, "QuitReallyTrackedApps");
		});
		os_state_add_handler((__bridge void *)dispatch_get_global_queue(-2, 0), ^os_state_data_t(os_state_hints_t hints) {
			CFDictionaryRef opts = CFDictionaryCreateWithItems(_kLSApplicationCopyMatchingApplicationsIncludeExitedApplicationsKey, kCFBooleanTrue,
				_kLSApplicationExitedButHasRemainingCoalitionPIDsOrNonForegroundChildrenApplicationsKey, kCFBooleanTrue);
			CFArrayRef apps = _LSCopyMatchingApplications(kLSDefaultSessionID, opts);
			os_state_data_t sd = NULL;
			if (apps) {
				if (CFArrayGetCount(apps) > 0) {
					NSMutableDictionary *all = [NSMutableDictionary new];
					addApplications(all, apps);
					if (all && [all count]) {
						sd = stateData(all, "ExitedApps");
						if (sd) os_log_debug(_LSQuitSupportLog(), "sysDiagnose: Returning all-info, %{public}d bytes of data", sd->osd_data_size);
					}
				}
				CFRelease(apps);
			}
			if (opts) CFRelease(opts);
			return sd;
		});
	});
}

/* true only for the boolean true object (xpc_bool_true), as Apple checks */
extern "C" const struct _xpc_bool_s _xpc_bool_true;
static BOOL entitled(const char *name, const void *token)
{
	void *v = xpc_copy_entitlement_for_token(name, token);
	return v == (const void *)&_xpc_bool_true;
}

/* loginwindow calls this once: options DontTakeAction / DontSendAnalytics (NSNumber YES), then the process must
 * hold four entitlements; it installs the two sysdiagnose state handlers and registers a BTMManagerSupport with
 * BTMManager as the force-quit handler. */
extern "C" LSS_EXPORT BOOL _LSRegisterAsQuitReallyHelperClient(NSDictionary *options, NSError *__autoreleasing *outError);
static bool sDontTakeAction, sDontSendAnalytics;

BOOL _LSRegisterAsQuitReallyHelperClient(NSDictionary *options, NSError *__autoreleasing *outError)
{
	if (!options) { sDontTakeAction = false; sDontSendAnalytics = false; }
	else {
		sDontTakeAction = options[@"DontTakeAction"] ? [options[@"DontTakeAction"] isEqual:@YES] : false;
		sDontSendAnalytics = options[@"DontSendAnalytics"] ? [options[@"DontSendAnalytics"] isEqual:@YES] : false;
	}
	audit_token_t token;
	mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
	if (task_info(mach_task_self_, TASK_AUDIT_TOKEN, (task_info_t)&token, &count) != KERN_SUCCESS) abort();
	static const char *const kEntitlements[] = {
		"com.apple.private.backgroundtaskmanagement.manage",
		"com.apple.private.SkyLight.user-accessibility-report",
		"com.apple.private.controlcenter.controlcentermodule",
	};
	NSError *error = nil;
	const char *missing = NULL;
	if (!xpc_copy_entitlement_for_token("com.apple.private.xpc.launchd.job-manager", &token)) missing = "com.apple.private.xpc.launchd.job-manager";
	else
		for (const char *e : kEntitlements) if (!entitled(e, &token)) { missing = e; break; }
	if (missing)
		error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-54
			userInfo:@{ NSDebugDescriptionErrorKey: [NSString stringWithFormat:@"Missing entitlement %s", missing] }];
	else {
		registerSysdiagonoseHandler(options, &error);
		if (sStateHandle) {
			static dispatch_once_t sOnce;
			dispatch_once(&sOnce, ^{
				static BTMManagerSupport *sBTMSupport;
				sBTMSupport = [[BTMManagerSupport alloc] init];
				BOOL ok = [[BTMManager shared] registerForceQuitHandler:sBTMSupport];
				os_log_info(_LSQuitSupportLog(), "_LSRegisterAsQuitReallyHelperClient, registered with btm %{BOOL}d", ok);
			});
			return YES;
		}
	}
	if (outError) *outError = error;
	os_log_error(_LSQuitSupportLog(), "quitSupport: _LSRegisterAsQuitReallyHelperClient( %{public}@ ) failing with error %{public}@", options, error);
	return NO;
}

/* sysdiagnose / "lsappinfo"-style status: with options[@"LSASN"] the one application, else (as Apple) the
 * matching applications are walked but the reply block is not called. */
extern "C" LSS_EXPORT BOOL _LSSysdiagnoseStatus(NSDictionary *options, void (^reply)(NSDictionary *status, NSError *error))
{
	LSASNRef asn = (__bridge LSASNRef)options[@"LSASN"];
	if (asn) {
		NSDictionary *d = appDictionary(asn);
		if (reply) reply(d, nil);
		return YES;
	}
	NSDictionary *opts = @{ (__bridge NSString *)_kLSApplicationCopyMatchingApplicationsIncludeExitedApplicationsKey: @YES,
		(__bridge NSString *)_kLSApplicationExitedButHasRemainingCoalitionPIDsOrNonForegroundChildrenApplicationsKey: @YES };
	CFArrayRef apps = _LSCopyMatchingApplications(kLSDefaultSessionID, (__bridge CFDictionaryRef)opts);
	if (!apps) {
		if (reply) reply(nil, nil);
		return YES;
	}
	NSMutableDictionary *all = [NSMutableDictionary new];
	CFArrayApplyBlock<LSASNRef>(apps, _LSASNGetTypeID(), ^bool(LSASNRef a) {
		all[asnDescription(a)] = appDictionary(a);
		return true;
	});
	CFRelease(apps);
	return YES;
}
