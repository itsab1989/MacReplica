// MacReplica corner plugin for the Ammonia tweak loader (advanced, at the user's own risk).
//
// Changes the corner radius of menus, popovers and the outer Quick Look panel inside every app it is loaded into.
// Ammonia only runs with System Integrity Protection turned off; MacReplica never turns it off. The plugin is
// deliberately inert unless everything is exactly as tested:
//   - only on the macOS builds listed in kTestedBuilds (after any macOS update it does nothing),
//   - only in processes with AppKit, and never in system daemons (see the .blacklist file installed next to it),
//   - only for the surfaces the user chose (global defaults MacReplicaMenuCornerRadius, MacReplicaPopoverCornerRadius,
//     MacReplicaQuickLookCornerRadius, MacReplicaToolbarCornerRadius: 2…24 points; MacReplicaRoundedButtons: buttons
//     as rounded rectangles instead of capsules),
//   - only for methods that exist with the expected names; anything missing is skipped.
// The inner preview area of Quick Look is drawn by a separate Apple service and keeps its own corners.
// Proven in a test app on macOS 27.0.1 (26A434): menus 11.9 → radius, popovers and Quick Look 20 → radius, toolbar
// groups 18 → radius, capsule buttons → rounded rectangles.

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

// The macOS builds the hooks were verified on. Overridable at compile time only for the self-test (`-DTESTED_BUILDS`).
#ifndef TESTED_BUILDS
#define TESTED_BUILDS "26A434"
#endif
static const char *kTestedBuilds[] = {TESTED_BUILDS};
static CGFloat gMenuRadius = 0, gPopoverRadius = 0, gQuickLookRadius = 0, gToolbarRadius = 0;
static BOOL gRoundedButtons = NO;
static IMP gPresent, gOrder, gPath, gButtonMove, gPlatterLayout;

static BOOL TestedBuild(void) {
    char build[32] = {0};
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) != 0) return NO;
    for (size_t i = 0; i < sizeof(kTestedBuilds) / sizeof(kTestedBuilds[0]); i++) {
        if (strcmp(build, kTestedBuilds[i]) == 0) return YES;
    }
    return NO;
}

static void ApplyToWindow(NSWindow *window, CGFloat radius) {
    @try {
        NSView *frame = window.contentView.superview;
        if (!frame) return;
        NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:frame];
        SEL setRadius = NSSelectorFromString(@"setCornerRadius:");
        while (stack.count) {
            NSView *view = stack.lastObject;
            [stack removeLastObject];
            if ([NSStringFromClass(view.class) hasPrefix:@"NSGlass"] && [view respondsToSelector:setRadius]) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(view, setRadius, radius);
            }
            [stack addObjectsFromArray:view.subviews];
        }
        SEL windowRadius = NSSelectorFromString(@"_setCornerRadius:");
        if ([window respondsToSelector:windowRadius]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(window, windowRadius, radius);
    } @catch (__unused NSException *exception) {
        // Never take the app down: leave this window as macOS drew it.
    }
}

// Menus: after AppKit presents a menu window.
static void HookedPresent(id self, SEL _cmd, id view, BOOL animated) {
    ((void (*)(id, SEL, id, BOOL))gPresent)(self, _cmd, view, animated);
    ApplyToWindow(self, gMenuRadius);
}

// Buttons: rounded rectangle instead of capsule. NSButton.borderShape (macOS 26 and later): 0 = automatic (a capsule
// for large and glass buttons), 1 = capsule, 2 = rounded rectangle, 3 = circle (left alone). AppKit reads the stored
// value, so it is set on the button rather than reported differently.
static void RoundButton(NSView *view) {
    SEL getShape = NSSelectorFromString(@"borderShape"), setShape = NSSelectorFromString(@"setBorderShape:");
    if (![view isKindOfClass:[NSButton class]] || ![view respondsToSelector:getShape] || ![view respondsToSelector:setShape]) return;
    NSInteger shape = ((NSInteger (*)(id, SEL))objc_msgSend)(view, getShape);
    if (shape == 0 || shape == 1) ((void (*)(id, SEL, NSInteger))objc_msgSend)(view, setShape, 2);
}

static void RoundButtons(NSView *view) {
    @try {
        RoundButton(view);
        for (NSView *subview in view.subviews) RoundButtons(subview);
    } @catch (__unused NSException *exception) {
    }
}

static void HookedButtonMove(id self, SEL _cmd) {
    ((void (*)(id, SEL))gButtonMove)(self, _cmd);
    @try { RoundButton(self); } @catch (__unused NSException *exception) {}
}

// Toolbar groups: the glass view inside NSToolbarPlatterView, after AppKit laid it out (it sets a capsule radius).
static void HookedPlatterLayout(id self, SEL _cmd) {
    ((void (*)(id, SEL))gPlatterLayout)(self, _cmd);
    @try {
        SEL setRadius = NSSelectorFromString(@"setCornerRadius:");
        for (NSView *view in [(NSView *)self subviews]) {
            if ([NSStringFromClass(view.class) hasPrefix:@"NSGlass"] && [view respondsToSelector:setRadius]) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(view, setRadius, gToolbarRadius);
            }
        }
    } @catch (__unused NSException *exception) {
    }
}

static void ApplyToQuickLook(NSWindow *panel) {
    if (gQuickLookRadius > 0) ApplyToWindow(panel, gQuickLookRadius);
    if (gRoundedButtons && panel.contentView.superview) RoundButtons(panel.contentView.superview);
}

// Quick Look: when the panel is ordered in (and again shortly after, when its buttons exist).
static void HookedOrder(id self, SEL _cmd, NSWindowOrderingMode place, NSInteger relativeTo) {
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))gOrder)(self, _cmd, place, relativeTo);
    static Class quickLook;
    if (!quickLook) quickLook = NSClassFromString(@"QLPreviewPanel");
    if (place != NSWindowOut && quickLook && [self isKindOfClass:quickLook]) {
        ApplyToQuickLook(self);
        dispatch_async(dispatch_get_main_queue(), ^{ ApplyToQuickLook(self); });
        __weak NSWindow *panel = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (panel) ApplyToQuickLook(panel);
        });
    }
}

// Popovers (and the Quick Look panel's frame, which is a popover frame): the mask path with the body's corners
// replaced, arrow kept.
static CGPathRef HookedPath(id self, SEL _cmd, CGRect rect) {
    CGPathRef original = ((CGPathRef (*)(id, SEL, CGRect))gPath)(self, _cmd, rect);
    if (!original) return original;
    static Class quickLook;
    if (!quickLook) quickLook = NSClassFromString(@"QLPreviewPanel");
    NSWindow *window = [self respondsToSelector:@selector(window)] ? [self window] : nil;
    CGFloat wanted = (quickLook && [window isKindOfClass:quickLook]) ? gQuickLookRadius : gPopoverRadius;
    if (wanted <= 0) return original;
    __block CGFloat x0 = CGFLOAT_MAX, y0 = CGFLOAT_MAX, x1 = -CGFLOAT_MAX, y1 = -CGFLOAT_MAX;
    CGPathApplyWithBlock(original, ^(const CGPathElement *element) {
        if (element->type == kCGPathElementMoveToPoint || element->type == kCGPathElementAddLineToPoint) {
            x0 = MIN(x0, element->points[0].x); y0 = MIN(y0, element->points[0].y);
            x1 = MAX(x1, element->points[0].x); y1 = MAX(y1, element->points[0].y);
        }
    });
    if (x0 >= x1 || y0 >= y1) return original;
    CGRect body = CGRectMake(x0, y0, x1 - x0, y1 - y0);
    CGFloat radius = MIN(wanted, MIN(body.size.width, body.size.height) / 2);
    CGPathRef rounded = CGPathCreateWithRoundedRect(body, radius, radius, NULL);
    CGPathRef box = CGPathCreateWithRect(body, NULL);
    CGPathRef arrow = CGPathCreateCopyBySubtractingPath(original, box, false);
    CGPathRef result = arrow ? CGPathCreateCopyByUnioningPath(rounded, arrow, false) : CGPathRetain(rounded);
    CGPathRelease(rounded);
    CGPathRelease(box);
    if (arrow) CGPathRelease(arrow);
    if (!result) return original;
    CGPathRelease(original);
    return result;
}

// Replaces the method on exactly this class. If the class only inherits it, an override is added to this class
// (calling the inherited implementation), so superclasses and their other subclasses stay untouched.
static IMP Replace(NSString *className, NSString *selector, IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selector);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) return original;
    return method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void MacReplicaCornersInit(void) {
    @autoreleasepool {
        if (!NSClassFromString(@"NSApplication") || !TestedBuild()) return;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        CGFloat (^radius)(NSString *) = ^CGFloat(NSString *key) {
            NSInteger value = [defaults integerForKey:key];
            return (value >= 2 && value <= 24) ? (CGFloat)value : 0;
        };
        gMenuRadius = radius(@"MacReplicaMenuCornerRadius");
        gPopoverRadius = radius(@"MacReplicaPopoverCornerRadius");
        gQuickLookRadius = radius(@"MacReplicaQuickLookCornerRadius");
        gToolbarRadius = radius(@"MacReplicaToolbarCornerRadius");
        gRoundedButtons = [defaults boolForKey:@"MacReplicaRoundedButtons"];
        // Each hook only when its surface was chosen.
        if (gMenuRadius > 0) gPresent = Replace(@"NSPopupMenuWindow", @"_commonPresentFromView:animated:", (IMP)HookedPresent);
        if (gPopoverRadius > 0 || gQuickLookRadius > 0) gPath = Replace(@"NSPopoverFrame", @"_copyFrameMaskPathInRect:", (IMP)HookedPath);
        // Quick Look lives in QuickLookUI, which an app may load later; NSWindow's method is always there.
        if (gQuickLookRadius > 0 || gRoundedButtons) gOrder = Replace(@"NSWindow", @"orderWindow:relativeTo:", (IMP)HookedOrder);
        if (gRoundedButtons) gButtonMove = Replace(@"NSButton", @"viewDidMoveToWindow", (IMP)HookedButtonMove);
        if (gToolbarRadius > 0) gPlatterLayout = Replace(@"NSToolbarPlatterView", @"layout", (IMP)HookedPlatterLayout);
    }
}
