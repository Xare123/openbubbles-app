// Synthetic serializer probe only. No CKContainer, account, keychain, XPC,
// CloudKit operation, application profile, or network request is used here.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>

static void Require(BOOL condition, NSString *reason) {
    if (!condition) @throw [NSException exceptionWithName:@"ProbeFailure"
        reason:reason userInfo:nil];
}

static BOOL Signature(id object, NSString *name, const char *result,
                      const char *argument) {
    NSMethodSignature *s = [object methodSignatureForSelector:NSSelectorFromString(name)];
    return s && strcmp(s.methodReturnType, result) == 0 &&
        s.numberOfArguments == (argument ? 3u : 2u) &&
        (!argument || strcmp([s getArgumentTypeAtIndex:2], argument) == 0);
}

static id Get(id object, NSString *name) {
    Require(Signature(object, name, "@", NULL), @"Unexpected object getter signature");
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}

static void Set(id object, NSString *name, id value) {
    Require(Signature(object, name, "v", "@"), @"Unexpected object setter signature");
    ((void (*)(id, SEL, id))objc_msgSend)(object, NSSelectorFromString(name), value);
}

static NSData *Data(id object) {
    id data = Get(object, @"data");
    Require([data isKindOfClass:NSData.class] && [data length] <= 4096,
            @"Serializer did not return bounded NSData");
    return data;
}

static NSString *Hex(NSData *data) {
    NSMutableString *hex = [NSMutableString new];
    const unsigned char *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; ++i) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static uint64_t Varint(NSData *data, NSUInteger *offset) {
    const uint8_t *bytes = data.bytes;
    uint64_t value = 0;
    for (unsigned int shift = 0; shift < 64; shift += 7) {
        Require(*offset < data.length, @"Truncated varint");
        uint8_t byte = bytes[(*offset)++];
        Require(shift != 63 || byte <= 1, @"Overflowing varint");
        value |= (uint64_t)(byte & 127) << shift;
        if (!(byte & 128)) return value;
    }
    Require(NO, @"Overlong varint");
    return 0;
}

// Each fresh request is populated with just one property. Fail if the
// serializer includes anything else; do not guess which field corresponds.
static NSNumber *StringField(NSData *data, NSString *expected) {
    NSUInteger offset = 0;
    uint64_t key = Varint(data, &offset);
    Require((key & 7) == 2 && (key >> 3) > 0 && (key >> 3) < (1u << 29),
            @"Expected one string field");
    uint64_t length = Varint(data, &offset);
    Require(length == data.length - offset, @"Unexpected additional fields");
    NSData *payload = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)length)];
    Require([payload isEqualToData:[expected dataUsingEncoding:NSUTF8StringEncoding]],
            @"String bytes do not match synthetic input");
    return @(key >> 3);
}

static id Decode(Class cls, NSData *data) {
    id allocated = [cls alloc];
    Require(Signature(allocated, @"initWithData:", "@", "@"),
            @"Missing initWithData decoder");
    id decoded = ((id (*)(id, SEL, id))objc_msgSend)(
        allocated, NSSelectorFromString(@"initWithData:"), data);
    Require(decoded != nil && [Data(decoded) isEqualToData:data],
            @"Serializer/decoder round trip changed bytes");
    return decoded;
}

static NSDictionary *ImageInfo(Class cls) {
    Dl_info info = {0};
    IMP imp = class_getMethodImplementation(cls, NSSelectorFromString(@"writeTo:"));
    Require(imp && dladdr((const void *)imp, &info) && info.dli_fname,
            @"Cannot locate serializer image");
    NSMutableDictionary *result = [@{@"path": @(info.dli_fname)} mutableCopy];
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if ((const void *)header != info.dli_fbase || header->magic != MH_MAGIC_64) continue;
        const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        const uint8_t *end = cursor + header->sizeofcmds;
        for (uint32_t n = 0; n < header->ncmds; ++n) {
            Require(cursor + sizeof(struct load_command) <= end, @"Invalid image header");
            const struct load_command *command = (const struct load_command *)cursor;
            Require(command->cmdsize >= sizeof(*command) && command->cmdsize <= (size_t)(end - cursor),
                    @"Invalid image command");
            if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
                result[@"uuid"] = [[NSUUID alloc]
                    initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
            }
            cursor += command->cmdsize;
        }
        result[@"cpu_type"] = @(header->cputype);
        break;
    }
    return result;
}

int main(void) {
    @autoreleasepool {
        NSMutableDictionary *report = [@{
            @"schema": @1, @"scope": @"synthetic-local-serialization-only",
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"server_semantics_proven": @NO, @"enum_exhaustive": @NO
        } mutableCopy];
        int exitCode = 0;
        @try {
            NSMutableArray *loads = [NSMutableArray new];
            for (NSString *path in @[
                @"/System/Library/Frameworks/CloudKit.framework/CloudKit",
                @"/System/Library/PrivateFrameworks/CloudKitDaemon.framework/CloudKitDaemon"
            ]) {
                void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
                [loads addObject:@{@"path": path, @"loaded": @(handle != NULL)}];
            }
            report[@"frameworks"] = loads;
            Class cls = NSClassFromString(@"CKDPRecordSaveRequest");
            Require(cls != Nil, @"CKDPRecordSaveRequest unavailable on this runtime");
            report[@"class"] = NSStringFromClass(cls);
            report[@"image"] = ImageInfo(cls);
            Require(Data([cls new]).length == 0, @"Fresh request is not empty");
            NSMutableDictionary *strings = [NSMutableDictionary new];
            report[@"string_properties"] = strings;
            for (NSArray<NSString *> *property in @[
                @[@"etag", @"setEtag:"],
                @[@"zoneProtectionInfoTag", @"setZoneProtectionInfoTag:"],
                @[@"recordProtectionInfoTag", @"setRecordProtectionInfoTag:"]
            ]) {
                id request = [cls new];
                NSString *value = [@"ob-synthetic-" stringByAppendingString:property[0]];
                Set(request, property[1], value);
                NSData *data = Data(request);
                NSNumber *field = StringField(data, value);
                Require([Get(Decode(cls, data), property[0]) isEqual:value],
                        @"Decoded string does not match input");
                strings[property[0]] = @{@"field": field, @"hex": Hex(data),
                    @"roundtrip": @YES};
            }
            id converter = [cls new];
            Require(Signature(converter, @"saveSemanticsAsString:", "@", "i") &&
                    Signature(converter, @"StringAsSaveSemantics:", "i", "@") &&
                    Signature(converter, @"setSaveSemantics:", "v", "i") &&
                    Signature(converter, @"saveSemantics", "i", NULL),
                    @"Unexpected enum method signatures");
            NSMutableArray *semantics = [NSMutableArray new];
            report[@"save_semantics"] = semantics;
            report[@"enum_scan_min"] = @(-1);
            report[@"enum_scan_max"] = @32;
            for (int value = -1; value <= 32; ++value) {
                id label = ((id (*)(id, SEL, int))objc_msgSend)(converter,
                    NSSelectorFromString(@"saveSemanticsAsString:"), value);
                Require(!label || ([label isKindOfClass:NSString.class] && [label length] <= 128),
                        @"Unexpected enum label");
                id inverse = label ? @(((int (*)(id, SEL, id))objc_msgSend)(converter,
                    NSSelectorFromString(@"StringAsSaveSemantics:"), label)) : NSNull.null;
                id request = [cls new];
                ((void (*)(id, SEL, int))objc_msgSend)(request,
                    NSSelectorFromString(@"setSaveSemantics:"), value);
                NSData *data = Data(request);
                NSUInteger offset = 0;
                uint64_t key = Varint(data, &offset);
                Require((key & 7) == 0 && (key >> 3) > 0 && (key >> 3) < (1u << 29),
                        @"Expected one enum varint field");
                uint64_t encoded = Varint(data, &offset);
                Require(offset == data.length && encoded == (uint64_t)(int64_t)value,
                        @"Unexpected enum wire value or additional fields");
                NSMutableDictionary *row = [@{@"value": @(value), @"label": label ?: NSNull.null,
                    @"label_inverse": inverse, @"field": @(key >> 3),
                    @"hex": Hex(data)} mutableCopy];
                @try {
                    int decoded = ((int (*)(id, SEL))objc_msgSend)(Decode(cls, data),
                        NSSelectorFromString(@"saveSemantics"));
                    row[@"decoded"] = @(decoded);
                    row[@"roundtrip"] = @(decoded == value);
                } @catch (NSException *exception) {
                    row[@"roundtrip"] = @NO;
                    row[@"decode_error"] = exception.reason ?: @"unknown";
                }
                [semantics addObject:row];
            }
            report[@"status"] = @"observed";
        } @catch (NSException *exception) {
            report[@"status"] = @"unavailable-or-incompatible";
            report[@"reason"] = exception.reason ?: @"unknown";
            exitCode = 2;
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:report
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
        [[NSFileHandle fileHandleWithStandardOutput] writeData:[@"\n"
            dataUsingEncoding:NSUTF8StringEncoding]];
        return exitCode;
    }
}
