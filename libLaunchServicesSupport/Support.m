/* SPDX-License-Identifier: BSD-2-Clause */
/* libLaunchServicesSupport: the log objects, the version symbols and the small string helpers of Apple's
 * /usr/lib/libLaunchServicesSupport.dylib (macOS 26.7.2); evidence in research/docs/LAUNCHSERVICESSUPPORT.md. */
#import <Foundation/Foundation.h>
#include <os/log.h>
#include <execinfo.h>
#include <ctype.h>
#include <stdlib.h>

#define LSS_EXPORT __attribute__((visibility("default")))

/* declared here too: the ravynOS Foundation headers of the FreeBSD build lack it */
@interface NSURL (LSSupportFileSystemRepresentation)
- (const char *)fileSystemRepresentation;
@end

/* What Apple's build stamps (the project version is empty in the shipped binary). */
LSS_EXPORT const unsigned char libLaunchServicesSupportVersionString[] __attribute__((aligned(16))) =
	"@(#)PROGRAM:libLaunchServicesSupport  PROJECT:LaunchServices-\n";
LSS_EXPORT const double libLaunchServicesSupportVersionNumber = 0.0;

/* Every getter makes its log once (dispatch_once) in subsystem "com.apple.launchservices". */
#define LS_LOG(fn, category) \
	LSS_EXPORT os_log_t fn(void) \
	{ \
		static dispatch_once_t onceToken; \
		static os_log_t log; \
		dispatch_once(&onceToken, ^{ log = os_log_create("com.apple.launchservices", category); }); \
		return log; \
	}

LS_LOG(_LSDefaultLog, "default")
LS_LOG(_LSAnalyticsLog, "analytics")
LS_LOG(_LSAppCheckInLog, "appcheckin")
LS_LOG(_LSExtensionsLog, "extensions")
LS_LOG(_LSFrontLog, "front")
LS_LOG(_LSInstallLog, "appinstallation")
LS_LOG(_LSProgressLog, "progress")
LS_LOG(_LSDisseminationLog, "dissemination")
LS_LOG(_LSPrivacyLog, "privacy")
LS_LOG(_LSDataSeparationLog, "datasep")
LS_LOG(_LSDatabaseGetLog, "db")
LS_LOG(_LSOpenLog, "open")
LS_LOG(_LSQuitSupportLog, "quitsupport")
LS_LOG(_LSRecordLog, "record")
LS_LOG(_LSRegistrationLog, "registration")
LS_LOG(_LSTemplateAppLog, "templateapp")
LS_LOG(_LSBindingLog, "binding")
LS_LOG(_LSAppProtectionLog, "appprotection")
LS_LOG(_LSCSUILog, "csui")
LS_LOG(_LSPluginFaultLog, "pluginfault")
LS_LOG(_LSTelemetryLog, "telemetry")

/* A file URL is logged as its path, any other URL only as "<scheme>:..." (no private data). */
LSS_EXPORT NSString *loggableURL(NSURL *url)
{
	if ([url isFileURL]) return [NSString stringWithUTF8String:[url fileSystemRepresentation]];
	return [NSString stringWithFormat:@"%@:...", [url scheme]];
}

/* The caller's stack (frame 0 left out) as "symbol + offset / symbol + offset / ...": each line of
 * backtrace_symbols() without its frame number, image name and address. */
LSS_EXPORT NSString *backtraceString(void)
{
	NSMutableArray *frames = [NSMutableArray array];
	void **buf = malloc(800);
	if (buf) {
		int n = backtrace(buf, 100);
		if (n > 0) {
			char **sym = backtrace_symbols(buf, n);
			for (int i = 1; i < n && sym[i]; i++) {
				const char *p = sym[i];
				while (isdigit((unsigned char)*p)) p++;
				while (*p && isspace(*p)) p++;
				while (*p && !isspace(*p)) p++;
				while (*p && isspace(*p)) p++;
				while (*p && !isspace(*p)) p++;
				while (*p && isspace(*p)) p++;
				if (*p) [frames addObject:[NSString stringWithCString:p encoding:NSUTF8StringEncoding]];
			}
			free(sym);
		}
		free(buf);
	}
	return [frames componentsJoinedByString:@" / "];
}

LSS_EXPORT NSString *copyBacktraceString(void) NS_RETURNS_RETAINED;
NSString *copyBacktraceString(void)
{
	return backtraceString();
}
