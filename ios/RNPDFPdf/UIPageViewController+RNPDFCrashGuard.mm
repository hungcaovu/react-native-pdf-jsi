/**
 * Swallows a known Apple bug inside UIPageViewController/PDFKit's
 * usePageViewController: mode.
 *
 * Symptom (confirmed via 4 device crash reports on 2026-10-01, all the same
 * stack): a hard/edge-case swipe at the first or last page - sometimes a
 * single clean swipe, not just a double-swipe - makes UIPageViewController's
 * private _UIQueuingScrollView delegate callback throw
 * NSInternalInconsistencyException while tearing down the manual-scroll
 * transition, which aborts the whole process. This happens entirely inside
 * UIKit's own call stack (triggered by the scroll view itself ending a user
 * drag), not from any call site of ours, so the @try/@catch already added in
 * -reconfigureUsePageViewControllerIfNeededWithRetriesLeft: (see that
 * method's comment) cannot reach it - there is no call of ours to wrap.
 * Swizzling the method itself is the only way to intercept it.
 *
 * -[UIPageViewController queuingScrollView:didEndManualScroll:toRevealView:
 *   direction:animated:didFinish:didComplete:] is undocumented private API
 * (part of UIPageViewController's conformance to _UIQueuingScrollView's
 * delegate protocol). Its selector and argument types below are not from an
 * Apple header - they come from community reverse-engineering of UIKit
 * (e.g. the iOS-Runtime-Headers project) and have been stable across iOS
 * versions for as long as this bug has been reported. If a future iOS
 * version changes this method's name or signature, +load below simply finds
 * nothing to swizzle and logs that once - it fails safe (crash guard absent,
 * not a bad swizzle) rather than mismatching the calling convention.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#if __has_include(<React/RCTLog.h>)
#import <React/RCTLog.h>
#else
#import "RCTLog.h"
#endif

@interface UIPageViewController (RNPDFCrashGuard)
@end

@implementation UIPageViewController (RNPDFCrashGuard)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"UIPageViewController");
        SEL originalSelector = NSSelectorFromString(
            @"queuingScrollView:didEndManualScroll:toRevealView:direction:animated:didFinish:didComplete:");
        SEL replacementSelector = @selector(rnpdf_queuingScrollView:didEndManualScroll:toRevealView:direction:animated:didFinish:didComplete:);

        Method originalMethod = class_getInstanceMethod(cls, originalSelector);
        Method replacementMethod = class_getInstanceMethod(cls, replacementSelector);

        if (!originalMethod || !replacementMethod) {
            RCTLogWarn(@"⚠️ [RNPDFCrashGuard] Expected UIPageViewController private method not found on this "
                       @"iOS version - crash guard NOT installed (page-boundary swipe crash is unprotected).");
            return;
        }

        method_exchangeImplementations(originalMethod, replacementMethod);
        RCTLogInfo(@"🛡️ [RNPDFCrashGuard] Installed UIPageViewController teardown crash guard.");
    });
}

// After the exchange above, sending this exact selector to self invokes
// whatever implementation UIKit originally had - NOT this method again.
- (void)rnpdf_queuingScrollView:(id)queuingScrollView
             didEndManualScroll:(BOOL)didEndManualScroll
                   toRevealView:(UIView *)toRevealView
                      direction:(NSInteger)direction
                       animated:(BOOL)animated
                      didFinish:(BOOL)didFinish
                    didComplete:(BOOL)didComplete {
    @try {
        [self rnpdf_queuingScrollView:queuingScrollView
                    didEndManualScroll:didEndManualScroll
                          toRevealView:toRevealView
                             direction:direction
                              animated:animated
                             didFinish:didFinish
                           didComplete:didComplete];
    } @catch (NSException *exception) {
        RCTLogError(@"⚠️ [RNPDFCrashGuard] Swallowed UIPageViewController internal teardown exception "
                    @"(page-boundary swipe race): %@ - %@", exception.name, exception.reason);
    }
}

@end
