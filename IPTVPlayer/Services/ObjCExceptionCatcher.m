#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"ObjCException"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Unknown ObjC exception"}];
        }
        return NO;
    }
}

@end
