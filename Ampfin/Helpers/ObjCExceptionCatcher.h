// ObjCExceptionCatcher.h
// Swift cannot catch Objective-C exceptions; AVAudioEngine raises them
// (for example while rewiring the graph), and uncaught they abort the app.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the exception it raised, if any.
NSException * _Nullable AmpfinCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
