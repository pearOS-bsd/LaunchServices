#import <Foundation/Foundation.h>
int main(void) { @autoreleasepool { NSData *v = nil; NSError *e = nil; BOOL ok = [[NSURL fileURLWithPath: @"/"] getResourceValue: &v forKey: NSURLVolumeIdentifierKey error: &e]; fprintf(stderr, "ok %d class %s value %s error %s\n", ok, v ? object_getClassName(v) : "-", v ? [[v description] UTF8String] : "-", e ? [[e description] UTF8String] : "-"); } return 0; }
