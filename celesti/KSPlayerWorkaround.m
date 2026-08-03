// KSPlayerWorkaround.m
//
// tvOS 26/27 removed the private _setContext: selector from OS_dispatch_mach_msg.
// KSPlayer's FFmpeg stack still sends it during initialization, causing an
// unrecognized-selector crash at launch. This file adds a no-op implementation
// as early as possible (+load runs before C/C++ constructors).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void KSPlayerWorkaroundSetContext(id self, SEL _cmd, void *context) {
    (void)self;
    (void)_cmd;
    (void)context;
}

@interface KSPlayerWorkaround : NSObject
@end

@implementation KSPlayerWorkaround

+ (void)load {
    Class cls = objc_getClass("OS_dispatch_mach_msg");
    if (cls) {
        SEL sel = sel_registerName("_setContext:");
        if (!class_respondsToSelector(cls, sel)) {
            class_addMethod(cls, sel, (IMP)KSPlayerWorkaroundSetContext, "v@:^v");
        }
    }
}

@end
