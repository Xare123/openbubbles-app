#import "OBRelayIdentifiers.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/utsname.h>

// System ABI fact: MobileGestalt answers by key. Declared here rather than
// linked, resolved once with dlsym so absence is a clean capability failure.
typedef CFTypeRef _Nullable (*OBMGCopyAnswerFn)(CFStringRef _Nonnull);

static NSString * _Nullable OBMobileGestaltString(NSString *key) {
    static OBMGCopyAnswerFn copyAnswer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW | RTLD_LOCAL);
        if (handle) copyAnswer = (OBMGCopyAnswerFn)dlsym(handle, "MGCopyAnswer");
    });
    if (!copyAnswer) return nil;
    CFTypeRef value = copyAnswer((__bridge CFStringRef)key);
    if (!value) return nil;
    NSString *result = [(__bridge id)value isKindOfClass:NSString.class]
        ? [(__bridge NSString *)value copy] : nil;
    CFRelease(value);
    return result.length ? result : nil;
}

@implementation OBRelayIdentifiers
+ (NSString *)hardwareModel {
    struct utsname system;
    if (uname(&system) != 0) return nil;
    NSString *machine = [NSString stringWithUTF8String:system.machine];
    return machine.length ? machine : nil;
}

+ (NSDictionary<NSString *, NSString *> *)versionIdentifiers {
    NSMutableDictionary *values = [NSMutableDictionary new];
    NSString *machine = [self hardwareModel];
    if (machine) values[@"hardware_version"] = machine;
    values[@"software_name"] = @"iPhone OS";
    NSString *systemVersion = UIDevice.currentDevice.systemVersion;
    if (systemVersion.length) values[@"software_version"] = systemVersion;
    for (NSArray *pair in @[@[@"software_build_id", @"BuildVersion"],
                            @[@"unique_device_id", @"UniqueDeviceID"],
                            @[@"serial_number", @"SerialNumber"]]) {
        NSString *value = OBMobileGestaltString(pair[1]);
        if (value) values[pair[0]] = value;
    }
    return [values copy];
}
@end
