#import "OBRelayNativePush.h"
#import "OBRelayPushProtocol.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

NSDictionary *OBRelayNativePushResult(NSDictionary *request) {
    void *framework=NULL;
    SecIdentityRef identity=NULL; SecCertificateRef certificate=NULL;
    SecKeyRef privateKey=NULL, certificateKey=NULL, publicKey=NULL;
    CFDataRef publicBytes=NULL, certificateBytes=NULL, der=NULL, signature=NULL;
    NSDictionary *result=nil;
    @try {
        framework=dlopen("/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",RTLD_LAZY|RTLD_LOCAL);
        if (!framework) return nil;
        Class cls=NSClassFromString(@"APSConnection"); SEL selector=NSSelectorFromString(@"copyIdentity");
        Method method=cls ? class_getClassMethod(cls,selector):NULL;
        if (!method || method_getNumberOfArguments(method)!=2) return nil;
        char type[64]={0},receiver[16]={0},argument[16]={0};
        method_getReturnType(method,type,sizeof(type));method_getArgumentType(method,0,receiver,sizeof(receiver));
        method_getArgumentType(method,1,argument,sizeof(argument));
        if (strcmp(type,"^{__SecIdentity=}")!=0 || (receiver[0]!='@' && receiver[0]!='#') || argument[0]!=':') return nil;
        identity=((SecIdentityRef (*)(id,SEL))objc_msgSend)(cls,selector);
        if (!identity || CFGetTypeID(identity)!=SecIdentityGetTypeID()
            || SecIdentityCopyCertificate(identity,&certificate)!=errSecSuccess
            || SecIdentityCopyPrivateKey(identity,&privateKey)!=errSecSuccess || !certificate || !privateKey) return nil;
        NSDictionary *attributes=CFBridgingRelease(SecKeyCopyAttributes(privateKey));
        NSNumber *bits=attributes[(__bridge id)kSecAttrKeySizeInBits];
        if (![attributes[(__bridge id)kSecAttrKeyType] isEqual:(__bridge id)kSecAttrKeyTypeRSA]
            || ![bits isKindOfClass:NSNumber.class] || ![@[@1024,@2048,@3072,@4096] containsObject:bits]) return nil;
        certificateKey=SecCertificateCopyKey(certificate);publicKey=SecKeyCopyPublicKey(privateKey);
        if (!certificateKey || !publicKey) return nil;
        // PUBLIC representations only. Never copy/export a private key.
        certificateBytes=SecKeyCopyExternalRepresentation(certificateKey,NULL);
        publicBytes=SecKeyCopyExternalRepresentation(publicKey,NULL);
        if (!certificateBytes || !publicBytes || CFDataGetLength(publicBytes)<=0
            || !CFEqual(certificateBytes,publicBytes)) return nil;
        der=SecCertificateCopyData(certificate);
        if (!der || CFDataGetLength(der)<129 || CFDataGetLength(der)>8192) return nil;
        NSData *cert=(__bridge NSData *)der;
        NSUInteger operation=[request[@"operation"] unsignedIntegerValue];
        NSData *sig=NSData.data;
        if (operation!=0) {
            uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(cert.bytes,(CC_LONG)cert.length,digest);
            if (!OBRelayPushConstantEqual([NSData dataWithBytes:digest length:sizeof(digest)],request[@"certificate_pin"])) return nil;
            NSData *payload=operation==1?request[@"nonce"]:request[@"digest"];
            if ((operation==1 && payload.length!=17) || (operation==2 && payload.length!=20) || operation>2) return nil;
            SecKeyAlgorithm algorithm=operation==1?kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1
                :kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1;
            if (!SecKeyIsAlgorithmSupported(privateKey,kSecKeyOperationTypeSign,algorithm)) return nil;
            signature=SecKeyCreateSignature(privateKey,algorithm,(__bridge CFDataRef)payload,NULL);
            if (!signature || CFDataGetLength(signature)!=bits.unsignedIntegerValue/8
                || !SecKeyVerifySignature(certificateKey,algorithm,(__bridge CFDataRef)payload,signature,NULL)) return nil;
            sig=[(__bridge NSData *)signature copy];
        }
        result=@{@"certificate":[cert copy],@"signature":sig};
    } @catch (__unused NSException *exception) { result=nil; }
    @finally {
        if (signature) CFRelease(signature);if (der) CFRelease(der);
        if (publicBytes) CFRelease(publicBytes);if (certificateBytes) CFRelease(certificateBytes);
        if (publicKey) CFRelease(publicKey);if (certificateKey) CFRelease(certificateKey);
        if (privateKey) CFRelease(privateKey);if (certificate) CFRelease(certificate);
        if (identity) CFRelease(identity);if (framework) dlclose(framework);
    }
    return result;
}
