/* SPDX-License-Identifier: BSD-2-Clause */
/* Included first by build-bsd.sh only: the Foundation API of macOS 10.6..13 that the ravynOS Foundation headers of the
 * FreeBSD header tree do not declare.  Declarations only; the implementations are the Mac's Foundation at run time. */
#ifndef LSS_FOUNDATION_COMPAT_H
#define LSS_FOUNDATION_COMPAT_H
#ifdef __OBJC__
#import <Foundation/Foundation.h>
@interface NSArray (LSSupportCompat)
- (void)enumerateObjectsUsingBlock:(void (^)(id obj, NSUInteger idx, BOOL *stop))block;
@end
@interface NSSet (LSSupportCompat)
- (void)enumerateObjectsUsingBlock:(void (^)(id obj, BOOL *stop))block;
@end
@interface NSString (LSSupportCompat)
- (BOOL)containsString:(NSString *)str;
@end
@interface NSURL (LSSupportCompat)
+ (NSURL *)fileURLWithPath:(NSString *)path isDirectory:(BOOL)isDir;
@end
@interface NSDate (LSSupportCompat)
+ (NSDate *)now;
@end
#ifdef __cplusplus
extern "C" {
#endif
extern NSString *const NSMultipleUnderlyingErrorsKey;
extern NSString *const NSURLFileResourceIdentifierKey;
extern NSString *const NSDebugDescriptionErrorKey;
#ifdef __cplusplus
}
#endif
static inline NSRect NSRectFromCGRect(CGRect r) { NSRect n; n.origin.x = r.origin.x; n.origin.y = r.origin.y; n.size.width = r.size.width; n.size.height = r.size.height; return n; }
#endif
#endif
