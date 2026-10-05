// ObjCExceptionCatcher.m

#import "ObjCExceptionCatcher.h"

NSException * _Nullable AmpfinCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
