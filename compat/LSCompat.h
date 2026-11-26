/* Declarations the open headers of the FreeBSD build (build-bsd.sh) lack; prototypes and values are Apple's (the symbols bind at run time to the Mac's frameworks). */
#import <Foundation/Foundation.h>
#include <uuid/uuid.h>
Protocol *NSProtocolFromString(NSString *namestr);
@interface NSString (LSCompat)
- (BOOL)containsString:(NSString *)str;
@end
@interface NSUUID : NSObject <NSCopying, NSSecureCoding>
- (instancetype)initWithUUIDBytes:(const unsigned char *)bytes;
- (void)getUUIDBytes:(unsigned char *)uuid;
@property (readonly, copy) NSString *UUIDString;
@end
/* NSXPCConnection.h */
enum { NSXPCConnectionPrivileged = (1 << 12) };
typedef NSUInteger NSXPCConnectionOptions;
@class NSXPCListener, NSXPCConnection;
@interface NSXPCInterface : NSObject
+ (NSXPCInterface *)interfaceWithProtocol:(Protocol *)protocol;
@end
@protocol NSXPCListenerDelegate <NSObject>
@optional
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection;
@end
@interface NSXPCConnection : NSObject
- (instancetype)initWithMachServiceName:(NSString *)name options:(NSXPCConnectionOptions)options;
@property (retain) NSXPCInterface *exportedInterface;
@property (retain) id exportedObject;
@property (retain) NSXPCInterface *remoteObjectInterface;
@property (copy) void (^invalidationHandler)(void);
@property (copy) void (^interruptionHandler)(void);
- (void)resume;
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *error))handler;
- (id)synchronousRemoteObjectProxyWithErrorHandler:(void (^)(NSError *error))handler;
@end
@interface NSXPCListener : NSObject
- (instancetype)initWithMachServiceName:(NSString *)name;
@property (weak) id <NSXPCListenerDelegate> delegate;
- (void)resume;
@end
#ifndef NS_FORMAT_FUNCTION
#define NS_FORMAT_FUNCTION(F, A) __attribute__((format(__NSString__, F, A)))
#endif
@interface NSURL (LSCompat)
+ (NSURL *)fileURLWithPath:(NSString *)path isDirectory:(BOOL)isDir;
@end
#ifndef NSDataReadingMappedIfSafe
#define NSDataReadingMappedIfSafe ((NSDataReadingOptions)1)
#endif
@interface NSUUID (LSCompat)
+ (instancetype)UUID;
@end
@interface NSArray (LSCompatBlocks)
- (void)enumerateObjectsUsingBlock:(void (^)(id obj, NSUInteger idx, BOOL *stop))block;
@end
@interface NSDictionary (LSCompatBlocks)
- (void)enumerateKeysAndObjectsUsingBlock:(void (^)(id key, id obj, BOOL *stop))block;
@end
@interface NSURL (LSCompatBookmark)
- (NSData *)bookmarkDataWithOptions:(NSUInteger)options includingResourceValuesForKeys:(NSArray *)keys relativeToURL:(NSURL *)relativeURL error:(NSError **)error;
@end
