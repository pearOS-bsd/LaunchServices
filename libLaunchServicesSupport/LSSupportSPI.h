/* SPDX-License-Identifier: BSD-2-Clause */
/* libLaunchServicesSupport: the private interfaces of other Apple libraries that Apple's
 * /usr/lib/libLaunchServicesSupport.dylib (macOS 26.7.2) imports.  Names and argument lists come from
 * the import table of Apple's binary and from how its code calls them (research/docs/LAUNCHSERVICESSUPPORT.md);
 * nothing here is copied from Apple headers. */
#ifndef LSSUPPORTSPI_H
#define LSSUPPORTSPI_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* CoreServices / LaunchServices (re-exported by CoreServices.framework) */
typedef const struct __LSASN *LSASNRef;
typedef int LSSessionID;
enum { kLSDefaultSessionID = -2 };

extern CFTypeID _LSASNGetTypeID(void);
extern LSASNRef _LSASNCreateWithPid(CFAllocatorRef allocator, pid_t pid);
extern Boolean _LSASNExtractHighAndLowParts(LSASNRef asn, uint32_t *high, uint32_t *low);
extern CFTypeRef _LSCopyApplicationInformationItem(LSSessionID session, LSASNRef asn, CFStringRef key);
extern CFDictionaryRef _LSCopyApplicationInformation(LSSessionID session, LSASNRef asn, CFArrayRef keys);
extern CFArrayRef _LSCopyMatchingApplications(LSSessionID session, CFDictionaryRef options);
extern Boolean _LSIsApplicationRunning(LSSessionID session, LSASNRef asn);
extern int _LSApplicationQuitting(LSSessionID session, LSASNRef asn, int flags);
extern const char *GetMacOSStatusErrorString(int err);

extern const CFStringRef _kLSPIDKey;
extern const CFStringRef _kLSDisplayNameKey;
extern const CFStringRef _kLSBundlePathKey;
extern const CFStringRef _kLSApplicationTypeKey;
extern const CFStringRef _kLSApplicationForegroundTypeKey;
extern const CFStringRef _kLSApplicationUIElementTypeKey;
extern const CFStringRef _kLSApplicationCoalitionIDKey;
extern const CFStringRef _kLSApplicationCoalitionPIDsKey;
extern const CFStringRef _kLSApplicationChildApplicationASNsArrayKey;
extern const CFStringRef _kLSApplicationAllRelatedApplicationASNsArrayKey;
extern const CFStringRef _kLSApplicationAllRelatedApplicationCoalitionPIDsArrayKey;
extern const CFStringRef _kLSApplicationRelatedApplicationCoalitionPIDsArrayKey;
extern const CFStringRef _kLSApplicationRelatedCoalitionsIDsArrayKey;
extern const CFStringRef _kLSApplicationCopyMatchingApplicationsIncludeExitedApplicationsKey;
extern const CFStringRef _kLSApplicationExitedButHasRemainingCoalitionPIDsOrNonForegroundChildrenApplicationsKey;

/* CoreGraphics / SkyLight */
typedef struct CGRegion *CGRegionRef;
extern Boolean CGRegionIsRect(CGRegionRef region, CGRect *rect);
extern CGRect CGRegionGetBoundingBox(CGRegionRef region);
extern CFDictionaryRef SLSGetUserAccessibilityReportForPid(pid_t pid);
extern const CFStringRef kSLSUserAccessibilityReportRemoteContextsKey;
extern const CFStringRef kSLSUserAccessibilityReportRemoteContextWindowShapeKey;
extern const CFStringRef kSLSUserAccessibilityReportSpacesKey;
extern const CFStringRef kSLSUserAccessibilityReportSpaceTypeKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowsKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowLevelKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowSpaceIDsKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowOrderingStatusKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowOrderingStatusOrderedOut;
extern const CFStringRef kSLSUserAccessibilityReportWindowShapeKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowAlphaKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowScreenVisibleShapeKey;
extern const CFStringRef kSLSUserAccessibilityReportWindowTransformKey;

/* libquit (weak import, as Apple links it) */
extern void LQReportHang(pid_t pid, void *queue, void (^completion)(void)) __attribute__((weak_import));

/* libSystem: the task port variable mach_task_self() reads */
#include <mach/mach.h>
extern mach_port_t mach_task_self_;

/* libxpc */
extern void *xpc_copy_entitlement_for_token(const char *entitlement, const void *audit_token);

/* os_state (libSystem) */
typedef struct os_state_hints_s {
	uint32_t osh_version;
	const char *osh_requestor;
	uint32_t osh_api;
	uint32_t osh_data_size;
} *os_state_hints_t;
typedef struct os_state_data_decoder_s {
	char osdd_library[64];
	char osdd_type[64];
} os_state_data_decoder_s;
typedef struct os_state_data_s {
	uint32_t osd_type;
	union { uint32_t osd_size : 32; uint32_t osd_data_size; };
	os_state_data_decoder_s osd_decoder;
	char osd_title[64];
	uint8_t osd_data[];
} *os_state_data_t;
enum { OS_STATE_DATA_SERIALIZED_NSCF_OBJECT = 1 };
typedef uint64_t os_state_handle_t;
#ifdef __BLOCKS__
typedef os_state_data_t (^os_state_block_t)(os_state_hints_t hints);
extern os_state_handle_t os_state_add_handler(void *queue, os_state_block_t block);
#endif

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
/* QuartzCore */
struct CATransform3D { CGFloat m11, m12, m13, m14, m21, m22, m23, m24, m31, m32, m33, m34, m41, m42, m43, m44; };
#ifdef __cplusplus
extern "C"
#else
extern
#endif
CGRect CA_CGRectApplyTransform(CGRect rect, struct CATransform3D t);
@interface NSValue (LSSupportCA)
- (struct CATransform3D)CATransform3DValue;
@end

/* AppServerSupport */
@interface OSLaunchdJobInfo : NSObject
- (id)instance;
- (id)program;
@end
@interface OSLaunchdJob : NSObject
+ (NSArray *)copyJobsLoadedByCoalition:(uint64_t)coalition error:(NSError **)error;
+ (OSLaunchdJob *)copyJobWithPid:(pid_t)pid;
- (BOOL)remove:(NSError **)error;
- (OSLaunchdJobInfo *)getCurrentJobInfo;
@end

/* RunningBoard launch properties (AppServerSupport) */
@interface LASSProperties4RB : NSObject
+ (instancetype)propertiesForJob:(OSLaunchdJob *)job error:(NSError **)error;
- (int)hostPID;
- (NSString *)label;
- (NSString *)path;
- (unsigned long long)serviceType;
@end

/* BackgroundTaskManagement */
@protocol BTMForceQuitHandler <NSObject>
- (void)forceQuitAppURL:(NSURL *)url;
@end
@interface BTMManager : NSObject
+ (instancetype)shared;
- (BOOL)registerForceQuitHandler:(id<BTMForceQuitHandler>)handler;
- (id)getItemWithIdentifier:(id)identifier uid:(uid_t)uid error:(NSError **)error;
@end
#ifdef __cplusplus
extern "C"
#else
extern
#endif
id BTMItemIdentifierForURLAndType(long type, NSURL *url);
#endif /* __OBJC__ */

#endif
