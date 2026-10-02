/**
 * Copyright (c) 2017-present, Wonday (@wonday.org)
 * All rights reserved.
 *
 * This source code is licensed under the MIT-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RNPDFPdfView.h"
#import "SearchRegistry.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>

#if __has_include(<React/RCTAssert.h>)
#import <React/RCTBridgeModule.h>
#import <React/RCTEventDispatcher.h>
#import <React/UIView+React.h>
#import <React/RCTLog.h>
#import <React/RCTBlobManager.h>
#else
#import "RCTBridgeModule.h"
#import "RCTEventDispatcher.h"
#import "UIView+React.h"
#import "RCTLog.h"
#import <RCTBlobManager.h">
#endif

#ifdef RCT_NEW_ARCH_ENABLED
#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>
#import <react/renderer/components/rnpdf/ComponentDescriptors.h>
#import <react/renderer/components/rnpdf/Props.h>
#import <react/renderer/components/rnpdf/RCTComponentViewHelpers.h>

// Some RN private method hacking below similar to how it is done in RNScreens:
// https://github.com/software-mansion/react-native-screens/blob/90e548739f35b5ded2524a9d6410033fc233f586/ios/RNSScreenStackHeaderConfig.mm#L30
@interface RCTBridge (Private)
+ (RCTBridge *)currentBridge;
@end

#endif

#ifndef __OPTIMIZE__
// only output log when debug
#define DLog( s, ... ) NSLog( @"<%p %@:(%d)> %@", self, [[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__, [NSString stringWithFormat:(s), ##__VA_ARGS__] )
#else
#define DLog( s, ... )
#endif

// output log both debug and release
#define RLog( s, ... ) NSLog( @"<%p %@:(%d)> %@", self, [[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__, [NSString stringWithFormat:(s), ##__VA_ARGS__] )

// Page-number pipeline trace (native -> JS -> page indicator). Every hop logs with this
// tag - native here, JS in index.js and ReaderPdfScreen.tsx - so one log filtered on
// "PGDBG" shows the whole chain in order. Each native line is also forwarded to JS (see
// RNPDFPgdbgLog below), so it shows up in Metro next to the JS side's lines.
// Debug builds only: in release the macro compiles to nothing, arguments included.
#ifndef __OPTIMIZE__
#define PGDBG( s, ... ) RNPDFPgdbgLog( [NSString stringWithFormat:@"🧷 [PGDBG][native] " s, ##__VA_ARGS__] )
#else
#define PGDBG( s, ... ) do {} while (0)
#endif

const float MAX_SCALE = 3.0f;
const float MIN_SCALE = 1.0f;


/** A highlight/skip-zone rect, pre-parsed once when the data arrives — not re-parsed from
 *  its wire-format string on every -drawRect: call (see HighlightOverlayView below). */
@interface RNPDFParsedRect : NSObject
@property (nonatomic) NSInteger page;      // 1-based, matches the wire format
@property (nonatomic) CGRect pageRect;     // PDF page-point space, already numeric
@end
@implementation RNPDFParsedRect
@end

/** Overlay that draws highlight rects (and skip-zone hatch bands) on top of the PDF view. */
@interface HighlightOverlayView : UIView
@property (nonatomic, weak) PDFView *pdfView;
@property (nonatomic, copy) NSArray<NSDictionary *> *highlightRects;
@property (nonatomic, copy) NSArray<NSDictionary *> *skipZoneRects;
@property (nonatomic, copy) NSArray<RNPDFParsedRect *> *parsedHighlightRects;
@property (nonatomic, copy) NSArray<RNPDFParsedRect *> *parsedSkipZoneRects;
@end

@implementation HighlightOverlayView

/** Parses the "left,top,right,bottom" wire strings once per data change (setHighlightRects:/
 *  setSkipZoneRects: below) — NSString splitting + doubleValue parsing has no reason to run
 *  again on every -drawRect: call, which -refreshHighlightOverlayContainer triggers on every
 *  single scroll/zoom delta (up to 60-120x/sec during a live pinch). This was found to be
 *  real, measurable per-frame overhead contributing to the highlight lagging a live pinch —
 *  independent of the live PDFKit geometry conversion below, which still has to run every
 *  frame (it genuinely depends on the current zoom scale) but is now the only remaining
 *  per-frame cost. */
- (NSArray<RNPDFParsedRect *> *)parseRectItems:(NSArray<NSDictionary *> *)items {
    NSMutableArray<RNPDFParsedRect *> *result = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSNumber *pageNum = item[@"page"];
        NSString *rectStr = item[@"rect"];
        if (!pageNum || !rectStr.length) continue;
        NSArray<NSString *> *parts = [rectStr componentsSeparatedByString:@","];
        if (parts.count != 4) continue;
        CGFloat left = parts[0].doubleValue, top = parts[1].doubleValue, right = parts[2].doubleValue, bottom = parts[3].doubleValue;
        RNPDFParsedRect *parsed = [RNPDFParsedRect new];
        parsed.page = pageNum.integerValue;
        parsed.pageRect = CGRectMake(left, bottom, right - left, top - bottom);
        [result addObject:parsed];
    }
    return result;
}

- (void)setHighlightRects:(NSArray<NSDictionary *> *)highlightRects {
    _highlightRects = [highlightRects copy];
    self.parsedHighlightRects = [self parseRectItems:highlightRects];
}

- (void)setSkipZoneRects:(NSArray<NSDictionary *> *)skipZoneRects {
    _skipZoneRects = [skipZoneRects copy];
    self.parsedSkipZoneRects = [self parseRectItems:skipZoneRects];
}

/** The one part of the conversion that genuinely must run every -drawRect: — it queries
 *  PDFKit's live, current-zoom-scale page-to-view mapping, which is the whole reason this
 *  redraw has to happen every frame in the first place (see -refreshHighlightOverlayContainer's
 *  comment). No string parsing left here. */
- (CGRect)viewRectForParsedRect:(RNPDFParsedRect *)parsed onPage:(PDFPage *)page inView:(PDFView *)pv {
    // parsed.pageRect is in "CropBox-local" space — (0,0) at the visible page's own
    // bottom-left — because the JS side builds it from PDFText.getPageSize, which hands
    // back the CropBox's *size* only (see PDFTextModule.m). -convertRect:fromPage:,
    // like every other PDFPage geometry API, expects coordinates in the page's own
    // untranslated space, where the CropBox can start at a non-zero origin (real for a
    // scanned/trimmed book's PDF). Skipping this offset left highlight/skip-zone rects
    // shifted by a constant amount, top and bottom alike, once the CropBox-vs-MediaBox
    // *size* mismatch was fixed but the CropBox's *origin* was still being ignored.
    CGRect cropBox = [page boundsForBox:kPDFDisplayBoxCropBox];
    CGRect pageRect = CGRectOffset(parsed.pageRect, cropBox.origin.x, cropBox.origin.y);
    CGRect pdfViewRect = [pv convertRect:pageRect fromPage:page];
    return [self convertRect:pdfViewRect fromView:pv];
}

- (void)drawRect:(CGRect)rect {
    PDFView *pv = self.pdfView;
    if (!pv || !pv.document) return;
    PDFDocument *doc = pv.document;

    NSArray<RNPDFParsedRect *> *skipItems = self.parsedSkipZoneRects;
    if (skipItems.count) {
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        for (RNPDFParsedRect *parsed in skipItems) {
            if (parsed.page < 1) continue;
            PDFPage *page = [doc pageAtIndex:(NSUInteger)(parsed.page - 1)];
            if (!page) continue;
            CGRect viewRect = [self viewRectForParsedRect:parsed onPage:page inView:pv];

            CGContextSaveGState(ctx);
            CGContextClipToRect(ctx, viewRect);
            [[UIColor colorWithWhite:0.5 alpha:0.22] setFill];
            CGContextFillRect(ctx, viewRect);
            // Diagonal hatch, matching the old JS SvgPattern (9pt spacing, 3pt stroke, rotated 45°).
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.25 alpha:0.55].CGColor);
            CGContextSetLineWidth(ctx, 3);
            CGContextTranslateCTM(ctx, CGRectGetMidX(viewRect), CGRectGetMidY(viewRect));
            CGContextRotateCTM(ctx, M_PI_4);
            CGFloat diag = hypot(viewRect.size.width, viewRect.size.height);
            for (CGFloat x = -diag; x <= diag; x += 9) {
                CGContextMoveToPoint(ctx, x, -diag);
                CGContextAddLineToPoint(ctx, x, diag);
            }
            CGContextStrokePath(ctx);
            CGContextRestoreGState(ctx);
        }
    }

    NSArray<RNPDFParsedRect *> *items = self.parsedHighlightRects;
    if (items.count) {
        [[UIColor colorWithRed:1 green:1 blue:0 alpha:0.35] setFill];
        for (RNPDFParsedRect *parsed in items) {
            if (parsed.page < 1) continue;
            PDFPage *page = [doc pageAtIndex:(NSUInteger)(parsed.page - 1)];
            if (!page) continue;
            CGRect viewRect = [self viewRectForParsedRect:parsed onPage:page inView:pv];
            CGContextFillRect(UIGraphicsGetCurrentContext(), viewRect);
        }
    }
}
@end

/**
 *  Sits between one of PDFKit's internal scroll views and that scroll view's original
 *  delegate (PDFKit's own controller), fanning callbacks out to both it and RNPDFPdfView.
 *
 *  Lifetime: UIScrollView.delegate is weak, so each proxy is retained by the scroll view
 *  it is installed on (objc associated object, see -hookScrollViewDelegateIfNeeded:).
 *  This used to be a single `_scrollDelegateProxy` ivar shared by every scroll view
 *  configureScrollView: found - in paged mode there are several (UIPageViewController's
 *  page-turn scroller plus one zoom scroller per page), so each new proxy released the
 *  previous one, the previous scroll view's delegate silently became nil, and the next
 *  configure pass installed RNPDFPdfView as its bare delegate with no forwarding. Device
 *  logs (2026-10-01) showed exactly that: PDFDocumentViewController and
 *  PDFPageViewController were cut off from their own scroll views, so the page-turn
 *  bookkeeping and per-page zoom state drifted out of sync with what was on screen.
 */
@interface RNPDFScrollViewDelegateProxy : NSObject <UIScrollViewDelegate>
- (instancetype)initWithPrimary:(id<UIScrollViewDelegate>)primary secondary:(id<UIScrollViewDelegate>)secondary;
- (id<UIScrollViewDelegate>)primaryDelegate;
- (id<UIScrollViewDelegate>)secondaryDelegate;
/// YES for UIPageViewController's own page-turn scroller (paged mode) - see -isPageTurnScrollView:.
@property (nonatomic, assign) BOOL isPageTurnScrollView;
@end

@implementation RNPDFScrollViewDelegateProxy {
    __weak id<UIScrollViewDelegate> _primary;
    __weak id<UIScrollViewDelegate> _secondary;
}

- (instancetype)initWithPrimary:(id<UIScrollViewDelegate>)primary secondary:(id<UIScrollViewDelegate>)secondary {
    if (self = [super init]) {
        _primary = primary;
        _secondary = secondary;
    }
    return self;
}

- (id<UIScrollViewDelegate>)primaryDelegate {
    return _primary;
}

- (id<UIScrollViewDelegate>)secondaryDelegate {
    return _secondary;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector]
        || (_primary && [_primary respondsToSelector:aSelector])
        || (_secondary && [_secondary respondsToSelector:aSelector]);
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if (_primary && [_primary respondsToSelector:aSelector]) {
        return _primary;
    }
    if (_secondary && [_secondary respondsToSelector:aSelector]) {
        return _secondary;
    }
    return [super forwardingTargetForSelector:aSelector];
}

// UIScrollView decides which optional callbacks to send when its delegate is set (it caches
// respondsToSelector:). _primary is weak, and this proxy now lives as long as its scroll
// view, so if PDFKit's controller is freed first, a callback only it implemented would
// reach forwardingTargetForSelector: with no target and raise unrecognized-selector.
// Swallow those instead - limited to scroll-view delegate callbacks, anything else still
// fails normally.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *signature = [super methodSignatureForSelector:aSelector];
    if (signature) {
        return signature;
    }
    struct objc_method_description description =
        protocol_getMethodDescription(@protocol(UIScrollViewDelegate), aSelector, NO, YES);
    if (description.types) {
        return [NSMethodSignature signatureWithObjCTypes:description.types];
    }
    if ([NSStringFromSelector(aSelector) hasPrefix:@"queuingScrollView"]) {
        // _UIQueuingScrollView's private callbacks to its UIPageViewController.
        return [NSMethodSignature signatureWithObjCTypes:"v@:"];
    }
    return nil;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    NSUInteger returnLength = invocation.methodSignature.methodReturnLength;
    if (returnLength > 0) {
        void *zeroed = calloc(1, returnLength);
        [invocation setReturnValue:zeroed];
        free(zeroed);
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (_primary && [_primary respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [_primary scrollViewDidScroll:scrollView];
    }
    if (_secondary && [_secondary respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [_secondary scrollViewDidScroll:scrollView];
    }
}

// NOTE: forwardingTargetForSelector: only relays to a single target, so any
// drag/decelerate callback PDFKit's own primary delegate also implements
// (very likely, since it drives UIPageViewController's transition) would
// otherwise starve our secondary (self) of these calls. Explicitly fan them
// out to both, same as scrollViewDidScroll: above.
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (_primary && [_primary respondsToSelector:@selector(scrollViewWillBeginDragging:)]) {
        [_primary scrollViewWillBeginDragging:scrollView];
    }
    if (_secondary && [_secondary respondsToSelector:@selector(scrollViewWillBeginDragging:)]) {
        [_secondary scrollViewWillBeginDragging:scrollView];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (_primary && [_primary respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
        [_primary scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
    }
    if (_secondary && [_secondary respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
        [_secondary scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (_primary && [_primary respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        [_primary scrollViewDidEndDecelerating:scrollView];
    }
    if (_secondary && [_secondary respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        [_secondary scrollViewDidEndDecelerating:scrollView];
    }
}

// Same problem as the drag/decelerate callbacks above: PDFKit's own primary
// delegate implements these to keep its internal page layout in sync during a
// live pinch, so forwardingTargetForSelector: would route every zoom frame to
// it exclusively and starve our secondary (self) — which is what redraws the
// highlight overlay per-frame in -scrollViewDidZoom:. Without this, the
// overlay only catches up via the coalesced scrollViewDidScroll: calls and
// the final settle, which reads as the highlight lagging behind a pinch and
// then snapping into place once the gesture ends.
- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (_primary && [_primary respondsToSelector:@selector(scrollViewDidZoom:)]) {
        [_primary scrollViewDidZoom:scrollView];
    }
    if (_secondary && [_secondary respondsToSelector:@selector(scrollViewDidZoom:)]) {
        [_secondary scrollViewDidZoom:scrollView];
    }
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    if (_primary && [_primary respondsToSelector:@selector(scrollViewWillBeginZooming:withView:)]) {
        [_primary scrollViewWillBeginZooming:scrollView withView:view];
    }
    if (_secondary && [_secondary respondsToSelector:@selector(scrollViewWillBeginZooming:withView:)]) {
        [_secondary scrollViewWillBeginZooming:scrollView withView:view];
    }
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    if (_primary && [_primary respondsToSelector:@selector(scrollViewDidEndZooming:withView:atScale:)]) {
        [_primary scrollViewDidEndZooming:scrollView withView:view atScale:scale];
    }
    if (_secondary && [_secondary respondsToSelector:@selector(scrollViewDidEndZooming:withView:atScale:)]) {
        [_secondary scrollViewDidEndZooming:scrollView withView:view atScale:scale];
    }
}

// PDFKit's own controller is the authority on what its scroll view zooms (PDFDocumentView
// in continuous mode, PDFTextInputView per page in paged mode - confirmed in device logs).
// A nil answer from it is respected, not overridden by guessing a subview: that guess is
// what used to make UIPageViewController's page-turn scroller "zoomable" with a scroll
// indicator as its zoom view. Only a scroll view whose original delegate has no opinion
// at all falls through to RNPDFPdfView, which also returns nil for the page-turn scroller.
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    id<UIScrollViewDelegate> primary = _primary;
    if (primary && [primary respondsToSelector:@selector(viewForZoomingInScrollView:)]) {
        return [primary viewForZoomingInScrollView:scrollView];
    }
    id<UIScrollViewDelegate> secondary = _secondary;
    if (secondary && [secondary respondsToSelector:@selector(viewForZoomingInScrollView:)]) {
        return [secondary viewForZoomingInScrollView:scrollView];
    }
    return nil;
}

@end

@interface RNPDFPdfView() <PDFDocumentDelegate, PDFViewDelegate
#ifdef RCT_NEW_ARCH_ENABLED
, RCTRNPDFPdfViewViewProtocol
#endif
>
#ifndef __OPTIMIZE__
- (void)pgdbgForwardToJS:(NSString *)line;
#endif
@end

#ifndef __OPTIMIZE__
// Most recently created PDF view - the one the PGDBG trace is forwarded through.
static __weak RNPDFPdfView *sPgdbgForwardView = nil;

static void RNPDFPgdbgLog(NSString *line) {
    RCTLogInfo(@"%@", line);
    RNPDFPdfView *view = sPgdbgForwardView;
    if (view) {
        [view pgdbgForwardToJS:line];
    }
}
#endif

// Gesture/transition state for the paging (UIPageViewController) mode's
// finger-driven scroll vs. UIKit's own internal transition cleanup — see the
// _pageTransitionState ivar comment below for why a plain bool wasn't enough.
typedef NS_ENUM(NSInteger, RNPDFPageTransitionState) {
    RNPDFPageTransitionIdle = 0,
    RNPDFPageTransitionUserDriven,
    RNPDFPageTransitionSettling,
};

// Associated-object keys on PDFKit's scroll views (see RNPDFScrollViewDelegateProxy).
static const void *kRNPDFScrollDelegateProxyKey = &kRNPDFScrollDelegateProxyKey;
static const void *kRNPDFPagingCarryTokenKey = &kRNPDFPagingCarryTokenKey;

@implementation RNPDFPdfView
{
    RCTBridge *_bridge;
    PDFDocument *_pdfDocument;
    PDFView *_pdfView;
    // Continuous mode: PDFKit's single scroll view (scrolls between pages AND zooms).
    // Paged mode: not used for zoom - each page has its own zoom scroller there, see
    // -activeZoomScrollView / -visiblePageZoomScrollView. Weak: in paged mode it may be a
    // page scroller UIPageViewController has since dropped, which must not be kept alive.
    __weak UIScrollView *_internalScrollView;
    // Scale values reported to JS (scaleChanged) that JS hasn't echoed back as the `scale`
    // prop yet, oldest first - see the scale handling in updateProps:.
    NSMutableArray<NSNumber *> *_pendingScaleEchoes;
    // The scale JS currently believes in: the last one we reported, or one JS set itself.
    float _jsKnownScale;
    PDFOutline *root;
    float _fixScaleFactor;
    // Set true for the duration of a live two-finger pinch (scrollViewWillBeginZooming/
    // scrollViewDidEndZooming below). Guards the `scale` prop re-application in
    // updateProps: — see that call site for why forcing scaleFactor while this is YES
    // causes the zoom to visibly judder.
    BOOL _isLiveZooming;
    bool _initialed;
    NSArray<NSString *> *_changedProps;
    UITapGestureRecognizer *_doubleTapRecognizer;
    UITapGestureRecognizer *_singleTapRecognizer;
    UILongPressGestureRecognizer *_longPressRecognizer;
    UITapGestureRecognizer *_doubleTapEmptyRecognizer;
    
    // Enhanced progressive loading properties
    BOOL _enableCaching;
    BOOL _enablePreloading;
    int _preloadRadius;
    BOOL _enableTextSelection;
    BOOL _showPerformanceMetrics;
    int _cacheSize;
    int _renderQuality;
    
    // Performance tracking
    CFAbsoluteTime _loadStartTime;
    CFAbsoluteTime _loadTime;
    int _pageCount;
    NSMutableDictionary *_pageCache;
    NSMutableSet *_preloadedPages;
    NSMutableDictionary *_performanceMetrics;
    NSMutableDictionary *_searchCache;
    NSString *_currentPdfId;
    NSOperationQueue *_preloadQueue;
    
    // Page navigation state tracking
    int _previousPage;
    BOOL _isNavigating;
    BOOL _documentLoaded;
    // Continuous-scroll-only "which page is actually on screen" tracker, display
    // purposes only (see updateDisplayPageForScrollIfNeeded below) — deliberately
    // never written back into _page/_previousPage or any navigation call, so a
    // transient bad reading here can't trigger the "drag jumps through many
    // pages" regression scrollViewDidScroll: above was gutted to avoid.
    int _displayPage;
    // Three-state gesture/transition tracker, replacing a plain "_isUserScrolling"
    // bool. The old bool flipped to NO the instant scrollViewDidEndDragging:/
    // scrollViewDidEndDecelerating: fired — but those UIScrollViewDelegate calls
    // are themselves invoked *from inside* UIKit's own transition-cleanup call
    // stack (_UIQueuingScrollView's didEndManualScroll:...), which hasn't
    // returned yet. A programmatic goToDestination:/goToRect:onPage: issued the
    // instant the bool went NO could still land inside that still-unwinding
    // stack frame and re-enter -[UIPageViewController setViewControllers:...],
    // which UIKit does not support and asserts on -> abort() (see the 2026-09-15
    // device crash: RNPDFPdfView navigateToPageForPagingMode: -> goToDestination:
    // -> ... -> _UIQueuingScrollView cleanupWithFinishedState: -> NSAssertionHandler).
    // RNPDFPageTransitionSettling exists specifically to force one extra run-loop
    // turn (via dispatch_async, not a fixed delay) after the drag/decelerate ends,
    // so UIKit's own internal frame has actually returned by the time we call
    // anything Idle again. Also gates handleSingleTap: below: a tap that lands
    // while we're still Settling is the tail of the same swipe gesture landing a
    // beat late, not a deliberate "tap to play" — only a tap seen while Idle
    // should be treated as intentional.
    RNPDFPageTransitionState _pageTransitionState;
    // Set while a paging-mode settle is waiting on the real teardown-complete
    // signal instead of a fixed timer - see beginSettlingAfterUserGestureEnd
    // and onPageTransitionTeardownComplete:.
    void (^_pagingSettleBlock)(void);
    // Bumped every time a new drag begins; a deferred Settling->Idle flip
    // captures this and only applies if it still matches, so a fresh gesture
    // that starts during the deferred window correctly cancels the old flip.
    NSInteger _pageTransitionGeneration;

    // Paged mode zoom carry-over. PDFKit zooms each page in its own scroll view, so a
    // finger-driven page turn always revealed the next page at PDFKit's default fit
    // zoom (the programmatic path, navigateToPageForPagingMode:, never runs for a
    // swipe). Captured from the page being left when a page-turn drag begins, applied
    // to the incoming page as soon as it scrolls into view, re-checked at settle.
    BOOL _pagingCarryValid;
    CGFloat _pagingCarryRatio;      // JS-facing scale (zoomScale / _fixScaleFactor) of the page being left
    CGFloat _pagingCarryFracX;      // horizontal viewport position (0..1) on the page being left
    int _pagingCarryFromPage;
    __weak UIScrollView *_pagingCarryFromScrollView;
    NSInteger _pagingCarryToken;    // bumped per capture; marks which incoming scroll views already got it
    // The page caught sliding in mid-turn, and from which side - reused at settle rather
    // than re-deriving direction from views UIPageViewController may have detached by then.
    __weak UIScrollView *_pagingCarryIncomingScrollView;
    BOOL _pagingCarryIncomingFromBelow;
    // _pageTransitionGeneration of the page-turn drag whose finger has lifted. A teardown
    // notification only counts as "this gesture's" once its finger is up.
    NSInteger _pageTurnFingerLiftedGeneration;
    // _pageTransitionGeneration at which the page-turn teardown notification arrived while
    // no settle was pending yet - i.e. before scrollViewDidEnd{Dragging,Decelerating}:
    // reached us for that same gesture. See beginSettlingAfterUserGestureEnd.
    NSInteger _pagingTeardownSeenGeneration;
    BOOL _scrollViewHookPassScheduled;
    // Sequence number stamped on every event sent to JS (PGDBG trace), so a missing
    // delivery shows up as a gap on the JS side.
    NSInteger _pgdbgEventSeq;
    
    // Track usePageViewController state to prevent unnecessary reconfiguration
    BOOL _currentUsePageViewController;
    BOOL _usePageViewControllerStateInitialized;
    // Set while reconfigureUsePageViewControllerIfNeededWithRetriesLeft: is tearing down/
    // rebuilding PDFKit's internal page/content view (the "single page view" Quick Settings
    // toggle). PDFKit resets _pdfView.currentPage to page 1 and posts
    // PDFViewPageChangedNotification as a side effect of usePageViewController: — the same
    // transient-reset behavior already guarded for the document-load path via
    // `_previousPage == -1` below, except this trigger (a mode toggle mid-document) doesn't
    // set that sentinel. Without this flag the spurious "page 1" notification reached
    // onPageChanged: unguarded and got written straight into _page/_previousPage, which
    // then round-tripped to JS as a real page-1 navigation on every single toggle.
    BOOL _isReconfiguringPageViewController;
    
    // Search and highlight (iOS parity with Android)
    NSString *_pdfId;
    NSArray *_highlightRects;
    NSArray *_skipZoneRects;
    HighlightOverlayView *_highlightOverlay;
    /// Local file path when document loaded (used for SearchRegistry; may differ from _path which can be URI)
    NSString *_lastLoadedPath;
}

#ifdef RCT_NEW_ARCH_ENABLED

using namespace facebook::react;

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  // Defensive check: Ensure the descriptor class exists before returning
  // This prevents nil object insertion in RCTThirdPartyComponentsProvider
  // The component name must match the codegen name: "RNPDFPdfView"
  // Using static to ensure the provider is initialized only once
  static ComponentDescriptorProvider provider = concreteComponentDescriptorProvider<RNPDFPdfViewComponentDescriptor>();
  return provider;
}

// Needed because of this: https://github.com/facebook/react-native/pull/37274
+ (void)load
{
  [super load];
  
  // Force class to be loaded before React Native tries to register it
  // This ensures RNPDFPdfViewCls() returns a valid class, preventing nil insertion
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Force class initialization by accessing the class
    Class cls = [self class];
    if (cls == nil) {
      RCTLogError(@"RNPDFPdfView: Class is nil in +load");
      return;
    }
    
    // Ensure component name is properly set for registration
    // This helps React Native's RCTThirdPartyComponentsProvider find the component
    // The component name must match the codegen name: "RNPDFPdfView"
    NSString *componentName = NSStringFromClass(cls);
    if (componentName == nil || componentName.length == 0) {
      RCTLogError(@"RNPDFPdfView: Component name is nil or empty");
    } else if (![componentName isEqualToString:@"RNPDFPdfView"]) {
      RCTLogWarn(@"RNPDFPdfView: Component name mismatch. Expected 'RNPDFPdfView', got '%@'", componentName);
    }
    
    // Verify class is accessible (RNPDFPdfViewCls is defined later, so we just verify the class itself)
    if (cls != RNPDFPdfView.class) {
      RCTLogError(@"RNPDFPdfView: Class mismatch in +load");
    }
  });
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        static const auto defaultProps = std::make_shared<const RNPDFPdfViewProps>();
        _props = defaultProps;
        [self initCommonProps];
    }
    return self;
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
    const auto &newProps = *std::static_pointer_cast<const RNPDFPdfViewProps>(props);
    NSMutableArray<NSString *> *updatedPropNames = [NSMutableArray new];
    if (_path != RCTNSStringFromStringNilIfEmpty(newProps.path)) {
        _path = RCTNSStringFromStringNilIfEmpty(newProps.path);
        [updatedPropNames addObject:@"path"];
    }
    if (_page != newProps.page) {
        PGDBG(@"<- JS page prop %d (native _page=%d _previousPage=%d state=%ld) - will %@",
              (int)newProps.page, _page, _previousPage, (long)_pageTransitionState,
              ((int)newProps.page != _previousPage) ? @"NAVIGATE (differs from last reported page)" : @"not navigate (matches last reported page)");
        _page = newProps.page;
        [updatedPropNames addObject:@"page"];
    }
    // JS echoes every scale native reports back down as the `scale` prop (that is what keeps
    // an unrelated re-render from snapping the zoom to a stale default). Two things used to
    // make those echoes re-apply zoom:
    //  - exact comparison: the prop is CGFloat (double) on iOS but _scale is float, so even
    //    an identical echo compared unequal - every prop update while zoomed (e.g. each
    //    sentence-highlight change) re-applied the zoom and ran a full layoutDocumentView;
    //  - lag: echoes of values reported mid-pinch land after the pinch has moved on (or
    //    ended), and re-applying them stepped the zoom back through old values - the
    //    highlight overlay jumping along with it.
    // So: compare with a tolerance, and treat an incoming value matching one we reported
    // and JS hasn't echoed yet as an echo, not a request. Anything else (JS resetting to 1
    // on a mode toggle or new document) is a real request.
    double incomingScale = newProps.scale;
    NSUInteger echoIndex = [self indexOfPendingScaleEcho:incomingScale];
    if (fabs((double)_scale - incomingScale) > 0.001) {
        if (echoIndex != NSNotFound) {
            [_pendingScaleEchoes removeObjectsInRange:NSMakeRange(0, echoIndex + 1)];
            PGDBG(@"zoom: Ignoring stale scale echo %f (native is at %f)", incomingScale, _scale);
        } else {
            PGDBG(@"zoom: scale prop changed by JS: native _scale=%f -> %f (changedProps so far=%@)",
                       _scale, incomingScale, updatedPropNames);
            [_pendingScaleEchoes removeAllObjects];
            _scale = incomingScale;
            _jsKnownScale = _scale;
            [updatedPropNames addObject:@"scale"];
        }
    } else if (echoIndex != NSNotFound) {
        [_pendingScaleEchoes removeObjectsInRange:NSMakeRange(0, echoIndex + 1)];
    }
    if (_minScale != newProps.minScale) {
        _minScale = newProps.minScale;
        [updatedPropNames addObject:@"minScale"];
    }
    if (_maxScale != newProps.maxScale) {
        _maxScale = newProps.maxScale;
        [updatedPropNames addObject:@"maxScale"];
    }
    if (_horizontal != newProps.horizontal) {
        RCTLogInfo(@"🔄 [iOS Scroll] Horizontal prop changed: %d -> %d", _horizontal, newProps.horizontal);
        _horizontal = newProps.horizontal;
        [updatedPropNames addObject:@"horizontal"];
    }
    if (_enablePaging != newProps.enablePaging) {
        _enablePaging = newProps.enablePaging;
        [updatedPropNames addObject:@"enablePaging"];
    }
    if (_enableRTL != newProps.enableRTL) {
        _enableRTL = newProps.enableRTL;
        [updatedPropNames addObject:@"enableRTL"];
    }
    if (_enableAnnotationRendering != newProps.enableAnnotationRendering) {
        _enableAnnotationRendering = newProps.enableAnnotationRendering;
        [updatedPropNames addObject:@"enableAnnotationRendering"];
    }
    if (_enableDoubleTapZoom != newProps.enableDoubleTapZoom) {
        _enableDoubleTapZoom = newProps.enableDoubleTapZoom;
        [updatedPropNames addObject:@"enableDoubleTapZoom"];
    }
    if (_fitPolicy != newProps.fitPolicy) {
        _fitPolicy = newProps.fitPolicy;
        [updatedPropNames addObject:@"fitPolicy"];
    }
    if (_spacing != newProps.spacing) {
        _spacing = newProps.spacing;
        [updatedPropNames addObject:@"spacing"];
    }
    if (_password != RCTNSStringFromStringNilIfEmpty(newProps.password)) {
        _password = RCTNSStringFromStringNilIfEmpty(newProps.password);
        [updatedPropNames addObject:@"password"];
    }
    if (_singlePage != newProps.singlePage) {
        RCTLogInfo(@"🔄 [iOS Scroll] SinglePage prop changed: %d -> %d", _singlePage, newProps.singlePage);
        _singlePage = newProps.singlePage;
        [updatedPropNames addObject:@"singlePage"];
    }
    if (_showsHorizontalScrollIndicator != newProps.showsHorizontalScrollIndicator) {
        _showsHorizontalScrollIndicator = newProps.showsHorizontalScrollIndicator;
        [updatedPropNames addObject:@"showsHorizontalScrollIndicator"];
    }
    if (_showsVerticalScrollIndicator != newProps.showsVerticalScrollIndicator) {
        _showsVerticalScrollIndicator = newProps.showsVerticalScrollIndicator;
        [updatedPropNames addObject:@"showsVerticalScrollIndicator"];
    }

    if (_scrollEnabled != newProps.scrollEnabled) {
        _scrollEnabled = newProps.scrollEnabled;
        [updatedPropNames addObject:@"scrollEnabled"];
    }
    NSString *newPdfId = RCTNSStringFromStringNilIfEmpty(newProps.pdfId);
    if (_pdfId != newPdfId && ![newPdfId isEqualToString:_pdfId]) {
        if (_pdfId.length) [SearchRegistry unregisterPath:_pdfId];
        _pdfId = [newPdfId copy];
        [updatedPropNames addObject:@"pdfId"];
        // Only register local file paths; never register URIs - onDocumentChanged will register when we have local path
        NSString *pathToRegister = nil;
        if (_lastLoadedPath.length > 0) {
            pathToRegister = _lastLoadedPath;
        } else if (_path.length > 0 && [_path hasPrefix:@"/"]) {
            pathToRegister = _path;
        }
        if (_pdfId.length && pathToRegister.length > 0) {
            [SearchRegistry registerPath:_pdfId path:pathToRegister];
            RCTLogInfo(@"✅ [iOS] SearchRegistry registered path for pdfId: %@ (from updateProps)", _pdfId);
        }
    }
    // Convert codegen vector of {page, rect} to NSArray for setHighlightRects.
    // Only mark it "changed" (and re-set it) when the content actually
    // differs from last time -- this used to be unconditional, so EVERY
    // updateProps call (even one solely about an unrelated prop like `page`
    // mirroring back what native itself just reported) made didSetProps
    // think highlightRects had changed, which kept its unconditional
    // layoutDocumentView call firing on every round trip. See the
    // layoutDocumentView gating in didSetProps below for the other half of
    // this fix.
    NSMutableArray *newHighlightRects = [NSMutableArray array];
    for (const auto &item : newProps.highlightRects) {
      [newHighlightRects addObject:@{ @"page": @(item.page), @"rect": [NSString stringWithUTF8String:item.rect.c_str()] }];
    }
    NSArray *copiedHighlightRects = [newHighlightRects copy];
    if (![_highlightRects isEqualToArray:copiedHighlightRects]) {
        [self setHighlightRects:copiedHighlightRects];
        [updatedPropNames addObject:@"highlightRects"];
    }

    // Convert codegen vector of {page, rect} to NSArray for setSkipZoneRects.
    // Same unconditional-diff fix as highlightRects above.
    NSMutableArray *newSkipZoneRects = [NSMutableArray array];
    for (const auto &item : newProps.skipZoneRects) {
      [newSkipZoneRects addObject:@{ @"page": @(item.page), @"rect": [NSString stringWithUTF8String:item.rect.c_str()] }];
    }
    NSArray *copiedSkipZoneRects = [newSkipZoneRects copy];
    if (![_skipZoneRects isEqualToArray:copiedSkipZoneRects]) {
        [self setSkipZoneRects:copiedSkipZoneRects];
        [updatedPropNames addObject:@"skipZoneRects"];
    }

    [super updateProps:props oldProps:oldProps];
    [self didSetProps:updatedPropNames];
}

// already added in case https://github.com/facebook/react-native/pull/35378 has been merged
- (BOOL)shouldBeRecycled
{
    return NO;
}

- (void)prepareForRecycle
{
    [super prepareForRecycle];
    if (_pdfId.length) [SearchRegistry unregisterPath:_pdfId];
    [_pdfView removeFromSuperview];
    _pdfDocument = Nil;
    _pdfView = Nil;
    _highlightOverlay = Nil;
    //Remove notifications
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PDFViewDocumentChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PDFViewPageChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PDFViewScaleChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:PDFViewVisiblePagesChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"RNPDFPageTransitionTeardownDidCompleteNotification" object:nil];

    // remove old recognizers before adding new ones
    [self removeGestureRecognizer:_doubleTapRecognizer];
    [self removeGestureRecognizer:_singleTapRecognizer];
    [self removeGestureRecognizer:_longPressRecognizer];
    [self removeGestureRecognizer:_doubleTapEmptyRecognizer];

    [self initCommonProps];
}

- (void)updateLayoutMetrics:(const facebook::react::LayoutMetrics &)layoutMetrics oldLayoutMetrics:(const facebook::react::LayoutMetrics &)oldLayoutMetrics
{
    // Fabric equivalent of `reactSetFrame` method
    [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
    _pdfView.frame = CGRectMake(0, 0, layoutMetrics.frame.size.width, layoutMetrics.frame.size.height);

    NSMutableArray *mProps = [_changedProps mutableCopy];
    if (_initialed) {
        [mProps removeObject:@"path"];
    }
    _initialed = YES;

    [self didSetProps:mProps];
    
    // Configure scroll view after layout to ensure it's found
    // This is important because PDFKit creates the scroll view lazily
    if (_documentLoaded && _pdfDocument) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RCTLogInfo(@"🔍 [iOS Scroll] updateLayoutMetrics called, configuring scroll view after layout");
            [self configureScrollView:self->_pdfView enabled:self->_scrollEnabled depth:0];
        });
    }
}

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTRNPDFPdfViewHandleCommand(self, commandName, args);
}

- (void)setNativePage:(NSInteger)page
{
    // #13: Imperative setNativePage must navigate even when page number equals _previousPage
    _previousPage = -1;
    _page = (int)page;
    [self didSetProps:[NSArray arrayWithObject:@"page"]];
}

#endif

- (instancetype)initWithBridge:(RCTBridge *)bridge
{
    self = [super init];
    if (self) {
        _bridge = bridge;
        [self initCommonProps];
    }

    return self;
}

- (void)initCommonProps
{
    _page = 1;
    _scale = 1;
    _minScale = MIN_SCALE;
    _maxScale = MAX_SCALE;
    _horizontal = NO;
    _enablePaging = NO;
    _enableRTL = NO;
    _enableAnnotationRendering = YES;
    _enableDoubleTapZoom = YES;
    _fitPolicy = 2;
    _spacing = 10;
    _singlePage = NO;
    _showsHorizontalScrollIndicator = YES;
    _showsVerticalScrollIndicator = YES;
    _scrollEnabled = YES;
    
    // Initialize page navigation state
    _previousPage = -1;
    _isNavigating = NO;
    _documentLoaded = NO;
    
    // Initialize usePageViewController state tracking
    _currentUsePageViewController = NO;
    _usePageViewControllerStateInitialized = NO;
#ifndef __OPTIMIZE__
    sPgdbgForwardView = self;
#endif
    // onPageChanged: drops every page change while this is set, so a view must never start
    // (or be recycled) with it left on.
    _isReconfiguringPageViewController = NO;
    _pagingCarryValid = NO;
    _pagingTeardownSeenGeneration = -1;
    _pageTurnFingerLiftedGeneration = -1;
    _scrollViewHookPassScheduled = NO;
    _pendingScaleEchoes = [NSMutableArray array];
    _jsKnownScale = _scale;

    // Enhanced properties
    _enableCaching = YES;
    _enablePreloading = YES;
    _preloadRadius = 3;
    _enableTextSelection = NO;
    _showPerformanceMetrics = NO;
    _cacheSize = 32768; // 32MB
    _renderQuality = 2; // High quality

    // Initialize enhanced features
    _pageCache = [NSMutableDictionary dictionary];
    _preloadedPages = [NSMutableSet set];
    _performanceMetrics = [NSMutableDictionary dictionary];
    _searchCache = [NSMutableDictionary dictionary];
    
    // Create preload queue
    _preloadQueue = [[NSOperationQueue alloc] init];
    _preloadQueue.maxConcurrentOperationCount = 3;
    _preloadQueue.qualityOfService = NSQualityOfServiceBackground;

    _pdfId = nil;
    _highlightRects = nil;
    _lastLoadedPath = nil;
    _highlightOverlay = nil;

    // init and config PDFView
    _pdfView = [[PDFView alloc] initWithFrame:CGRectMake(0, 0, 500, 500)];
    _pdfView.displayMode = kPDFDisplaySinglePageContinuous;
    _pdfView.autoScales = YES;
    _pdfView.displaysPageBreaks = YES;
    _pdfView.displayBox = kPDFDisplayBoxCropBox;
    _pdfView.backgroundColor = [UIColor clearColor];

    _fixScaleFactor = -1.0f;
    _initialed = NO;
    _changedProps = NULL;
    _isLiveZooming = NO;

    [self addSubview:_pdfView];


    // register notification
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(onDocumentChanged:) name:PDFViewDocumentChangedNotification object:_pdfView];
    [center addObserver:self selector:@selector(onPageChanged:) name:PDFViewPageChangedNotification object:_pdfView];
    [center addObserver:self selector:@selector(onScaleChanged:) name:PDFViewScaleChangedNotification object:_pdfView];
#ifndef __OPTIMIZE__
    // Trace only (PGDBG): PDFKit's own "what is on screen now" signal, independent of
    // PDFViewPageChangedNotification/currentPage which drive the page number.
    [center addObserver:self selector:@selector(onVisiblePagesChanged:) name:PDFViewVisiblePagesChangedNotification object:_pdfView];
#endif
    // No `object:` - posted by the UIPageViewController swizzle
    // (UIPageViewController+RNPDFCrashGuard.mm), which has no reference to this
    // specific RNPDFPdfView. onPageTransitionTeardownComplete: below no-ops unless
    // this view's own paging settle is actually pending, so the broadcast scope is
    // harmless.
    [center addObserver:self selector:@selector(onPageTransitionTeardownComplete:) name:@"RNPDFPageTransitionTeardownDidCompleteNotification" object:nil];

    [[_pdfView document] setDelegate: self];
    [_pdfView setDelegate: self];

    // Only disable double-tap recognizers to avoid conflicts with custom double-tap
    // Leave all other gestures (including pinch) enabled
    for (UIGestureRecognizer *recognizer in _pdfView.gestureRecognizers) {
        if ([recognizer isKindOfClass:[UITapGestureRecognizer class]]) {
            UITapGestureRecognizer *tapGesture = (UITapGestureRecognizer *)recognizer;
            if (tapGesture.numberOfTapsRequired == 2) {
                recognizer.enabled = NO;
            }
        }
    }

    [self bindTap];
}

// #13: Paper — re-applying the same `page` must still run navigation (controlled lists / setNativeProps)
- (void)setPage:(int)pageValue
{
    if (_documentLoaded && pageValue == _page) {
        _previousPage = -1;
    }
    _page = pageValue;
}

// usePageViewController:withViewOptions: tears down/rebuilds PDFKit's internal
// UIPageViewController synchronously. Calling it while the user's own
// finger-driven page-turn transition is still in flight (_pageTransitionState
// != Idle) races UIPageViewController's own _UIQueuingScrollView cleanup and
// hits the same "No view controller managing visible view" assertion as
// navigateToPageForPagingMode: above - except this entry point is reached
// from didSetProps: (e.g. the reader's "Single page view" Quick Settings
// toggle, which is a Fabric prop update and bypasses touch hit-testing
// entirely, so _pdfView.userInteractionEnabled doesn't block it). Real device
// crash, 2026-10-01: toggling the switch while a manual swipe was still
// settling aborted the app. Re-reads enablePaging/horizontal fresh at fire
// time (not a captured value) so a prop flip-flop during the wait doesn't
// apply a stale decision.
//
// The _pageTransitionState check above is only a proxy for our own read of
// the gesture - it can go Idle a run-loop turn before _UIQueuingScrollView
// finishes its own internal manual-scroll teardown, so usePageViewController:
// can still race UIKit's private completion handler and throw even with the
// guard in place (same device, still 2026-10-01, still reachable from the
// single-page-view toggle). @try/@catch around the call is the actual
// backstop: it's a regular NSException via objc_exception_throw, not a
// memory-access crash, so it's safe to swallow - leave the mode unchanged
// and retry rather than let it abort the process.
- (void)reconfigureUsePageViewControllerIfNeededWithRetriesLeft:(int)retriesLeft {
    if (_pageTransitionState != RNPDFPageTransitionIdle) {
        if (retriesLeft <= 0) {
            RCTLogWarn(@"⚠️ [iOS Scroll] Giving up on usePageViewController reconfigure - user is still "
                       @"mid page-transition after retry budget exhausted. Leaving current mode in place.");
            return;
        }
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf reconfigureUsePageViewControllerIfNeededWithRetriesLeft:retriesLeft - 1];
        });
        return;
    }

    BOOL shouldUsePageViewController = _enablePaging && !_horizontal;
    if (_usePageViewControllerStateInitialized && shouldUsePageViewController == _currentUsePageViewController) {
        // Desired state already matches - either another call already applied
        // it, or props flipped back before we got a clear run-loop turn.
        return;
    }

    // Fix: Disable usePageViewController when horizontal is true, as it conflicts with horizontal scrolling
    // UIPageViewController doesn't work well with horizontal PDFView display direction
    RCTLogInfo(@"🔄 [iOS Scroll] Configuring usePageViewController - enablePaging=%d, horizontal=%d, usePageVC=%d",
              _enablePaging, _horizontal, shouldUsePageViewController);

    // usePageViewController: is about to tear down/rebuild PDFKit's internal page/content
    // view, which resets _pdfView.currentPage to page 1 as a side effect and posts
    // PDFViewPageChangedNotification - see _isReconfiguringPageViewController's declaration.
    // Capture the real page now so it can be restored once the rebuild settles below.
    int pageBeforeReconfigure = _page;
    _isReconfiguringPageViewController = YES;

    // Configure usePageViewController. Wrapped because PDFKit's internal
    // UIPageViewController teardown can still throw here even past the
    // _pageTransitionState guard above - see the comment on this method.
    @try {
        if (shouldUsePageViewController) {
            // Only use page view controller for vertical orientation
            [_pdfView usePageViewController:YES withViewOptions:@{UIPageViewControllerOptionSpineLocationKey:@(UIPageViewControllerSpineLocationMin),UIPageViewControllerOptionInterPageSpacingKey:@(_spacing)}];
            RCTLogInfo(@"✅ [iOS Scroll] Enabled UIPageViewController (vertical paging mode)");
        } else {
            // For horizontal or when paging is disabled, use regular scrolling
            [_pdfView usePageViewController:NO withViewOptions:Nil];
            RCTLogInfo(@"✅ [iOS Scroll] Disabled UIPageViewController (using regular scrolling)");
        }
    } @catch (NSException *exception) {
        _isReconfiguringPageViewController = NO;
        RCTLogError(@"⚠️ [iOS Scroll] usePageViewController: threw %@ (%@) - PDFKit's internal "
                    @"manual-scroll teardown raced this reconfigure. Leaving mode unchanged and "
                    @"retrying.", exception.name, exception.reason);
        if (retriesLeft > 0) {
            __weak __typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf reconfigureUsePageViewControllerIfNeededWithRetriesLeft:retriesLeft - 1];
            });
        }
        return;
    }

    // Only commit the new state once usePageViewController: actually succeeded.
    _currentUsePageViewController = shouldUsePageViewController;
    _usePageViewControllerStateInitialized = YES;

    // Reconfigure scroll view after usePageViewController changes
    // PDFView's internal scroll view hierarchy changes when usePageViewController is toggled
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only drop our pointer to the old scroll view. Proxies are owned by the scroll
        // views they sit on, so PDFKit's old scrollers take theirs with them and the new
        // ones get hooked below. (This used to also nil the shared proxy ivar, which
        // released whichever proxy was installed and left that scroll view delegate-less.)
        RCTLogInfo(@"🔄 [iOS Scroll] Resetting scroll view reference for reconfiguration");
        self->_internalScrollView = nil;
        self->_pagingCarryValid = NO;

        // Reconfigure scroll view after view hierarchy updates
        dispatch_async(dispatch_get_main_queue(), ^{
            RCTLogInfo(@"🔧 [iOS Scroll] Reconfiguring scroll view after usePageViewController change (scrollEnabled=%d)", self->_scrollEnabled);
            [self configureScrollView:self->_pdfView enabled:self->_scrollEnabled depth:0];
            // usePageViewController: rebuilt PDFKit's page/content view, and its own
            // autoScales can leave scaleFactor at whatever it picked for the new layout.
            // Reassert the fit baseline now that the new view hierarchy (and
            // _internalScrollView) has settled, instead of leaving the wrong zoom level
            // sticky until the document is reopened.
            [self recomputeFitScale];

            // The onPageChanged: guard above suppressed PDFKit's transient "reset to page
            // 1" notification so _page/JS were never corrupted, but the native view itself
            // genuinely is sitting on page 1 now - steer it back to the real page.
            PDFPage *restorePage = (pageBeforeReconfigure >= 1 && pageBeforeReconfigure <= (int)self->_pdfDocument.pageCount)
                ? [self->_pdfDocument pageAtIndex:pageBeforeReconfigure - 1]
                : nil;
            if (restorePage) {
                if (self->_currentUsePageViewController) {
                    [self navigateToPageForPagingMode:restorePage targetPage:pageBeforeReconfigure retriesLeft:10];
                } else {
                    CGRect pdfPageRect = [restorePage boundsForBox:kPDFDisplayBoxCropBox];
                    if (restorePage.rotation == 90 || restorePage.rotation == 270) {
                        pdfPageRect = CGRectMake(0, 0, pdfPageRect.size.height, pdfPageRect.size.width);
                    }
                    CGPoint pointLeftTop = CGPointMake(0, pdfPageRect.size.height);
                    PDFDestination *pdfDest = [[PDFDestination alloc] initWithPage:restorePage atPoint:pointLeftTop];
                    [self->_pdfView goToDestination:pdfDest];
                    self->_pdfView.scaleFactor = self->_fixScaleFactor * self->_scale;
                }
            }
            self->_isReconfiguringPageViewController = NO;
        });
    });
}

// Jumps _pdfView to targetPage while usePageViewController paging mode is on.
// Waits out any in-flight user-driven scroll/decelerate (and its Settling
// tail — see _pageTransitionState comment) instead of calling
// goToDestination:/goToRect:onPage: concurrently with UIKit's own transition.
// Logs the exact inputs at each decision point so a future crash report can
// be correlated with what this call was about to do.
// Recomputes _fixScaleFactor (the "points-per-PDF-point" multiplier behind the JS-facing
// scale/minScale/maxScale props) from the current frame and page geometry, and reapplies
// it to PDFKit's scaleFactor/min/maxScaleFactor plus the internal scroll view's zoom
// scales. Originally only ran on fitPolicy/minScale/maxScale/path changes (see
// didSetProps below), but toggling enablePaging/horizontal also needs it: that rebuilds
// PDFKit's internal page/content view via usePageViewController: (see
// reconfigureUsePageViewControllerIfNeededWithRetriesLeft:), and PDFKit's own
// autoScales=YES can leave scaleFactor at whatever it picked for the new layout instead
// of honoring our "fit" baseline - which previously stuck around as a wrong zoom level
// until the document was reopened, since nothing else re-derived it after a mode switch.
- (void)recomputeFitScale {
    if (!_pdfDocument) {
        return;
    }
    PDFPage *pdfPage = _pdfView.currentPage ? _pdfView.currentPage : [_pdfDocument pageAtIndex:_pdfDocument.pageCount-1];
    CGRect pdfPageRect = [pdfPage boundsForBox:kPDFDisplayBoxCropBox];

    // some pdf with rotation, then adjust it
    if (pdfPage.rotation == 90 || pdfPage.rotation == 270) {
        pdfPageRect = CGRectMake(0, 0, pdfPageRect.size.height, pdfPageRect.size.width);
    }

    if (_fitPolicy == 0) {
        _fixScaleFactor = self.frame.size.width/pdfPageRect.size.width;
    } else if (_fitPolicy == 1) {
        _fixScaleFactor = self.frame.size.height/pdfPageRect.size.height;
    } else {
        float pageAspect = pdfPageRect.size.width/pdfPageRect.size.height;
        float reactViewAspect = self.frame.size.width/self.frame.size.height;
        if (reactViewAspect>pageAspect) {
            _fixScaleFactor = self.frame.size.height/pdfPageRect.size.height;
        } else {
            _fixScaleFactor = self.frame.size.width/pdfPageRect.size.width;
        }
    }

    _pdfView.scaleFactor = _scale * _fixScaleFactor;
    _pdfView.minScaleFactor = _fixScaleFactor*_minScale;
    _pdfView.maxScaleFactor = _fixScaleFactor*_maxScale;

    // Continuous: PDFKit's one scroll view. Paged: the visible page's own zoom scroller
    // (never UIPageViewController's page-turn scroller, which must not zoom at all).
    UIScrollView *zoomScrollView = [self activeZoomScrollView];
    if (zoomScrollView && _fixScaleFactor > 0) {
        [self applyZoomLimitsToScrollView:zoomScrollView];
        CGFloat target = MIN(MAX(_scale * _fixScaleFactor, zoomScrollView.minimumZoomScale), zoomScrollView.maximumZoomScale);
        zoomScrollView.zoomScale = target;
        RCTLogInfo(@"🔍 [iOS Zoom] Configured zoom scroll view - min=%f, max=%f, current=%f (paged=%d)",
                  zoomScrollView.minimumZoomScale,
                  zoomScrollView.maximumZoomScale,
                  zoomScrollView.zoomScale,
                  _currentUsePageViewController);
    }
}

- (void)navigateToPageForPagingMode:(PDFPage *)pdfPage targetPage:(int)targetPage retriesLeft:(int)retriesLeft {
    if (_pageTransitionState != RNPDFPageTransitionIdle) {
        if (retriesLeft <= 0) {
            RCTLogWarn(@"⚠️ [iOS Scroll] Giving up on programmatic navigate to page %d (pageCount=%lu) - "
                       @"user is still scrolling after retry budget exhausted. Skipping to avoid racing "
                       @"UIPageViewController's own transition.",
                       targetPage, (unsigned long)_pdfDocument.pageCount);
            _isNavigating = NO;
            return;
        }
        RCTLogInfo(@"⏳ [iOS Scroll] Deferring programmatic navigate to page %d (pageCount=%lu, retriesLeft=%d) - "
                   @"page transition state=%ld (not Idle)",
                   targetPage, (unsigned long)_pdfDocument.pageCount, retriesLeft, (long)_pageTransitionState);
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf navigateToPageForPagingMode:pdfPage targetPage:targetPage retriesLeft:retriesLeft - 1];
        });
        return;
    }

    PGDBG(@"programmatic navigate START to page %d %@", targetPage, [self pgdbgSnapshot]);
    RCTLogInfo(@"➡️ [iOS Scroll] Performing programmatic navigate to page %d (pageCount=%lu, currentPage=%d)",
               targetPage, (unsigned long)_pdfDocument.pageCount, _page);

    if (targetPage == 1) {
        // Special case for first page
        [_pdfView goToRect:CGRectMake(0, NSUIntegerMax, 1, 1) onPage:pdfPage];
    } else {
        CGRect pdfPageRect = [pdfPage boundsForBox:kPDFDisplayBoxCropBox];
        if (pdfPage.rotation == 90 || pdfPage.rotation == 270) {
            pdfPageRect = CGRectMake(0, 0, pdfPageRect.size.height, pdfPageRect.size.width);
        }

        // Preserve the user's zoomed-in viewport position across the page swap instead of
        // always landing on the new page's top-left corner: capture where on the OLD page
        // the visible viewport currently sits, as a FRACTION of that page's bounds, then
        // apply the same fraction to the NEW page. A user reading zoomed into the middle of
        // page 5 should see the middle of page 6 next — this is only a page-content swap
        // (plus the highlight overlay refreshing), not a reason to move the viewport.
        PDFPage *previousVisiblePage = _pdfView.currentPage;
        BOOL preservedViewport = NO;
        if (previousVisiblePage && previousVisiblePage != pdfPage) {
            CGRect previousPageBounds = [previousVisiblePage boundsForBox:kPDFDisplayBoxCropBox];
            if (previousVisiblePage.rotation == 90 || previousVisiblePage.rotation == 270) {
                previousPageBounds = CGRectMake(0, 0, previousPageBounds.size.height, previousPageBounds.size.width);
            }
            if (previousPageBounds.size.width > 0 && previousPageBounds.size.height > 0) {
                CGRect visibleRectOnPreviousPage = [_pdfView convertRect:_pdfView.bounds toPage:previousVisiblePage];
                CGFloat fracX = (visibleRectOnPreviousPage.origin.x - previousPageBounds.origin.x) / previousPageBounds.size.width;
                CGFloat fracY = (visibleRectOnPreviousPage.origin.y - previousPageBounds.origin.y) / previousPageBounds.size.height;
                CGFloat fracW = visibleRectOnPreviousPage.size.width / previousPageBounds.size.width;
                CGFloat fracH = visibleRectOnPreviousPage.size.height / previousPageBounds.size.height;
                CGRect targetRect = CGRectMake(
                    pdfPageRect.origin.x + fracX * pdfPageRect.size.width,
                    pdfPageRect.origin.y + fracY * pdfPageRect.size.height,
                    fracW * pdfPageRect.size.width,
                    fracH * pdfPageRect.size.height
                );
                RCTLogInfo(@"📍 [iOS Scroll] Preserving relative viewport across page swap %d -> %d: frac=(%.3f,%.3f,%.3f,%.3f)",
                           _page, targetPage, fracX, fracY, fracW, fracH);
                [_pdfView goToRect:targetRect onPage:pdfPage];
                preservedViewport = YES;
            }
        }
        if (!preservedViewport) {
            RCTLogInfo(@"📍 [iOS Scroll] goToDestination (top-left) for page swap %d -> %d (no viewport to preserve)",
                       _page, targetPage);
            CGPoint pointLeftTop = CGPointMake(0, pdfPageRect.size.height);
            PDFDestination *pdfDest = [[PDFDestination alloc] initWithPage:pdfPage atPoint:pointLeftTop];
            [_pdfView goToDestination:pdfDest];
        }
        // goToRect:onPage: adjusts scaleFactor to fit the target rect — reapply the
        // user's actual current scale afterward so the zoom level itself is untouched too.
        _pdfView.scaleFactor = _fixScaleFactor * _scale;
    }

    _previousPage = targetPage;
    _isNavigating = NO;
}

- (void)PDFViewWillClickOnLink:(PDFView *)sender withURL:(NSURL *)url
{
    NSString *_url = url.absoluteString;
    [self notifyOnChangeWithMessage:
                     [[NSString alloc] initWithString:
                      [NSString stringWithFormat:
                       @"linkPressed|%s", _url.UTF8String]]];
}

- (void)didSetProps:(NSArray<NSString *> *)changedProps
{
    if (!_initialed) {

        _changedProps = changedProps;

    } else {
        // Log all didSetProps calls to understand what's triggering reconfigurations
        RCTLogInfo(@"📥 [iOS Scroll] didSetProps called - changedProps=%@, initialized=%d, currentUsePageVC=%d", 
                  changedProps, _usePageViewControllerStateInitialized, _currentUsePageViewController);

        // Create filtered changedProps array - remove "path" if it hasn't actually changed
        // This prevents unnecessary reconfigurations when path is in changedProps but value unchanged
        NSArray<NSString *> *effectiveChangedProps = changedProps;
        BOOL pathActuallyChanged = NO;

        if ([changedProps containsObject:@"path"]) {
            // CRITICAL FIX: Only reset state if the path actually changed
            // React Native sometimes includes path in changedProps even when only page changes
            
            if (_pdfDocument != Nil && _pdfDocument.documentURL != nil) {
                // Compare new path with existing document's path
                NSString *currentPath = _pdfDocument.documentURL.path;
                NSString *newPath = _path;
                // Normalize paths for comparison (remove trailing slashes, resolve symlinks, etc.)
                if (![currentPath isEqualToString:newPath]) {
                    pathActuallyChanged = YES;
                }
            } else {
                // No existing document, so this is a new path (or initial load)
                pathActuallyChanged = YES;
            }
            
            RCTLogInfo(@"🔄 [iOS Scroll] Path prop in changedProps - hadDocument=%d, pathActuallyChanged=%d", 
                      (_pdfDocument != Nil), pathActuallyChanged);
            
            // Filter out "path" from effectiveChangedProps if it hasn't actually changed
            if (!pathActuallyChanged) {
                RCTLogInfo(@"⏭️ [iOS Scroll] Path value unchanged, filtering out 'path' from effectiveChangedProps");
                NSMutableArray<NSString *> *filtered = [changedProps mutableCopy];
                [filtered removeObject:@"path"];
                effectiveChangedProps = filtered;
            } else {
                // Path actually changed, use changedProps as-is
                effectiveChangedProps = changedProps;
            }
            
            if (!pathActuallyChanged) {
                RCTLogInfo(@"⏭️ [iOS Scroll] Path value unchanged, skipping document reload");
                // Skip the rest of path handling
            } else {
                // Reset document load state when path actually changes
                _documentLoaded = NO;
                _previousPage = -1;
                _isNavigating = NO;

                // Release old doc if it exists
            if (_pdfDocument != Nil) {
                _pdfDocument = Nil;
                    _usePageViewControllerStateInitialized = NO;
                    _currentUsePageViewController = NO;
                    RCTLogInfo(@"🔄 [iOS Scroll] Reset usePageViewController state - path changed (hadDocument=YES)");
                } else {
                    RCTLogInfo(@"⏭️ [iOS Scroll] No previous document to reset");
            }
            
            if ([_path hasPrefix:@"blob:"]) {
                RCTBlobManager *blobManager = [
#ifdef RCT_NEW_ARCH_ENABLED
        [RCTBridge currentBridge]
#else
        _bridge
#endif // RCT_NEW_ARCH_ENABLED
                    moduleForName:@"BlobModule"];
                NSURL *blobURL = [NSURL URLWithString:_path];
                NSData *blobData = [blobManager resolveURL:blobURL];
                if (blobData != nil) {
                    _pdfDocument = [[PDFDocument alloc] initWithData:blobData];
                }
            } else {
            
                // decode file path
                _path = (__bridge_transfer NSString *)CFURLCreateStringByReplacingPercentEscapes(NULL, (CFStringRef)_path, CFSTR(""));
                NSURL *fileURL = [NSURL fileURLWithPath:_path];
                _pdfDocument = [[PDFDocument alloc] initWithURL:fileURL];
            }

            if (_pdfDocument) {

                //check need password or not
                if (_pdfDocument.isLocked && ![_pdfDocument unlockWithPassword:_password]) {

                    [self notifyOnChangeWithMessage:@"error|Password required or incorrect password."];

                    _pdfDocument = Nil;
                    return;
                }

                _pdfView.document = _pdfDocument;
                _documentLoaded = YES;
                
                // Configure scroll view after document is set
                // PDFKit creates the scroll view lazily, so we need to wait a bit
                dispatch_async(dispatch_get_main_queue(), ^{
                    RCTLogInfo(@"🔍 [iOS Scroll] Document set, searching for scroll view");
                    [self configureScrollView:self->_pdfView enabled:self->_scrollEnabled depth:0];
                    
                    // Retry after a short delay to catch cases where scroll view is created asynchronously
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        RCTLogInfo(@"🔍 [iOS Scroll] Retry search for scroll view after delay");
                        [self configureScrollView:self->_pdfView enabled:self->_scrollEnabled depth:0];
                    });
                });
            } else {

                [self notifyOnChangeWithMessage:[[NSString alloc] initWithString:[NSString stringWithFormat:@"error|Load pdf failed. path=%s",_path.UTF8String]]];

                _pdfDocument = Nil;
                return;
                }
            }
        }

        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] || [changedProps containsObject:@"spacing"])) {
            if (_horizontal) {
                _pdfView.pageBreakMargins = UIEdgeInsetsMake(0,_spacing,0,0);
                if (_spacing==0) {
                    if (@available(iOS 12.0, *)) {
                        _pdfView.pageShadowsEnabled = NO;
                    }
                } else {
                    if (@available(iOS 12.0, *)) {
                        _pdfView.pageShadowsEnabled = YES;
                    }
                }
            } else {
                _pdfView.pageBreakMargins = UIEdgeInsetsMake(0,0,_spacing,0);
                if (_spacing==0) {
                    if (@available(iOS 12.0, *)) {
                        _pdfView.pageShadowsEnabled = NO;
                    }
                } else {
                    if (@available(iOS 12.0, *)) {
                        _pdfView.pageShadowsEnabled = YES;
                    }
                }
            }
        }

        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] || [changedProps containsObject:@"enableRTL"])) {
            _pdfView.displaysRTL = _enableRTL;
        }

        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] || [changedProps containsObject:@"enableAnnotationRendering"])) {
            if (!_enableAnnotationRendering) {
                for (unsigned long i=0; i<_pdfView.document.pageCount; i++) {
                    PDFPage *pdfPage = [_pdfView.document pageAtIndex:i];
                    for (unsigned long j=0; j<pdfPage.annotations.count; j++) {
                        pdfPage.annotations[j].shouldDisplay = _enableAnnotationRendering;
                    }
                }
            }
        }

        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] || [changedProps containsObject:@"fitPolicy"] || [changedProps containsObject:@"minScale"] || [changedProps containsObject:@"maxScale"])) {
            [self recomputeFitScale];
        }

        // Skip while a live pinch is in progress: `scale` here is JS echoing back
        // whatever onScaleChanged/scrollViewDidZoom last told it, round-tripped through
        // the bridge. By the time that round trip lands, the user's fingers (and the
        // scroll view's own live zoomScale) have already moved past the echoed value —
        // forcing scaleFactor/zoomScale back to that stale number here fights the
        // in-progress UIPinchGestureRecognizer every single frame, which is what reads
        // as the PDF juddering while the user holds a pinch. The live gesture is already
        // the source of truth during this window; nothing needs to be applied until it ends.
        if (_pdfDocument && !_isLiveZooming && ([effectiveChangedProps containsObject:@"path"] || [changedProps containsObject:@"scale"])) {
            if (_currentUsePageViewController) {
                // Paged mode: zoom lives in the visible page's own scroll view, and
                // _scale is kept in sync from that same scroll view (scrollViewDidZoom:),
                // so this is normally a no-op echo. Skipped mid page-turn: which page
                // is "visible" is ambiguous then, and settle re-syncs it anyway.
                if (_pageTransitionState == RNPDFPageTransitionIdle) {
                    [self applyScaleToVisiblePageScrollView];
                }
            } else {
                _pdfView.scaleFactor = _scale * _fixScaleFactor;
                if (_pdfView.scaleFactor>_pdfView.maxScaleFactor) _pdfView.scaleFactor = _pdfView.maxScaleFactor;
                if (_pdfView.scaleFactor<_pdfView.minScaleFactor) _pdfView.scaleFactor = _pdfView.minScaleFactor;

                // Also update internal scroll view zoom scale when scale changes
                if (_internalScrollView && _fixScaleFactor > 0) {
                    _internalScrollView.zoomScale = _pdfView.scaleFactor;
                    RCTLogInfo(@"🔍 [iOS Zoom] Updated internal scroll view zoom scale to %f", _internalScrollView.zoomScale);
                }
            }
        }

        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] || [changedProps containsObject:@"horizontal"])) {
            if (_horizontal) {
                _pdfView.displayDirection = kPDFDisplayDirectionHorizontal;
                _pdfView.pageBreakMargins = UIEdgeInsetsMake(0,_spacing,0,0);
                RCTLogInfo(@"➡️ [iOS Scroll] Set display direction to HORIZONTAL (spacing=%d)", _spacing);
            } else {
                _pdfView.displayDirection = kPDFDisplayDirectionVertical;
                _pdfView.pageBreakMargins = UIEdgeInsetsMake(0,0,_spacing,0);
                RCTLogInfo(@"⬇️ [iOS Scroll] Set display direction to VERTICAL (spacing=%d)", _spacing);
            }
        }

        // Reconfigure usePageViewController when the document (re)loads, or when the
        // enablePaging/horizontal props actually flip at runtime (e.g. the reader's
        // "single page view" toggle). Previously this only re-ran on `path` changes,
        // so toggling enablePaging off after loading in paging mode left the
        // UIPageViewController still driving page-turns underneath what the JS side
        // believed was plain continuous scrolling — dragging would fling through many
        // pages at once instead of tracking the drag distance.
        BOOL shouldUsePageViewController = _enablePaging && !_horizontal;
        if (_pdfDocument &&
            ([effectiveChangedProps containsObject:@"path"] ||
             ((!_usePageViewControllerStateInitialized || shouldUsePageViewController != _currentUsePageViewController) &&
              ([changedProps containsObject:@"enablePaging"] || [changedProps containsObject:@"horizontal"])))) {
            [self reconfigureUsePageViewControllerIfNeededWithRetriesLeft:10];
        }

        // Runs after the usePageViewController reconfigure above, so the continuous-mode
        // branch is the one that re-asserts displayMode once paging has just been switched
        // off - hence "enablePaging"/"horizontal" are in the trigger list too, not only
        // "path"/"singlePage".
        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] ||
                             [changedProps containsObject:@"singlePage"] ||
                             [changedProps containsObject:@"enablePaging"] ||
                             [changedProps containsObject:@"horizontal"])) {
            if (_singlePage) {
                _pdfView.displayMode = kPDFDisplaySinglePage;
                _pdfView.userInteractionEnabled = NO;
                RCTLogInfo(@"📄 [iOS Scroll] Set to SINGLE PAGE mode (userInteractionEnabled=NO)");
            } else if (shouldUsePageViewController) {
                // Deliberately does NOT write displayMode. PDFKit documents it as ignored
                // while a UIPageViewController owns the layout ("layout is always assumed
                // single page continuous", PDFView.h), but writing it anyway tears that
                // controller back down and leaves the plain continuous scroller in its
                // place. That hit every *first* load that already had enablePaging=true,
                // because this block runs on "path" immediately after
                // reconfigureUsePageViewControllerIfNeeded... has just switched paging on.
                // The reader's runtime "Single page view" toggle never hit it - flipping
                // only `enablePaging` didn't re-enter this block back when it keyed off
                // "path"/"singlePage" alone - which is why paged mode worked when toggled
                // but not when it was already on at open. Caught on device (2026-10-02) on
                // the header/footer margin screen, which always mounts with paging on: its
                // supposedly single-page preview scrolled, showed the top of the *next*
                // page below the current one, and left both drag handles misplaced
                // (that screen's JS geometry assumes PDFKit's centered single-page layout).
                _pdfView.userInteractionEnabled = YES;
                RCTLogInfo(@"📄 [iOS Scroll] Paged mode - leaving displayMode to UIPageViewController");
            } else {
                _pdfView.displayMode = kPDFDisplaySinglePageContinuous;
                _pdfView.userInteractionEnabled = YES;
                RCTLogInfo(@"📄 [iOS Scroll] Set to CONTINUOUS PAGE mode (userInteractionEnabled=YES)");
            }
        }

        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] || [changedProps containsObject:@"showsHorizontalScrollIndicator"] || [changedProps containsObject:@"showsVerticalScrollIndicator"])) {
            [self setScrollIndicators:self horizontal:_showsHorizontalScrollIndicator vertical:_showsVerticalScrollIndicator depth:0];
        }

        // Configure scroll view (scrollEnabled)
        if (_pdfDocument && ([effectiveChangedProps containsObject:@"path"] || 
                             [changedProps containsObject:@"scrollEnabled"])) {
            RCTLogInfo(@"🔧 [iOS Scroll] Configuring scroll enabled=%d (path changed=%d, scrollEnabled changed=%d)", 
                      _scrollEnabled, 
                      [effectiveChangedProps containsObject:@"path"], 
                      [changedProps containsObject:@"scrollEnabled"]);
            
            // If path changed, hand every scroll view back to PDFKit's own delegate before
            // reconfiguring - configureScrollView: below re-hooks whatever is there now.
            if ([effectiveChangedProps containsObject:@"path"]) {
                RCTLogInfo(@"🔄 [iOS Scroll] Restoring original scroll delegates (path changed)");
                [self unhookScrollViewDelegatesInView:_pdfView depth:0];
                _internalScrollView = nil;
                _pagingCarryValid = NO;
            }
            
            // Use dispatch_async to ensure view hierarchy is fully set up after document load
            dispatch_async(dispatch_get_main_queue(), ^{
                // Search within _pdfView's hierarchy for scroll views
                RCTLogInfo(@"🔍 [iOS Scroll] Starting scroll view search in PDFView hierarchy");
                [self configureScrollView:self->_pdfView enabled:self->_scrollEnabled depth:0];
            });
        }

        // Separate page navigation logic - only navigate when page prop actually changes
        // Skip navigation on initial load (when path changes) to avoid conflicts
        BOOL shouldNavigateToPage = _documentLoaded &&
                                     [changedProps containsObject:@"page"] &&
                                     !_isNavigating &&
                                     _page != _previousPage &&
                                     _page > 0 &&
                                     _page <= (int)_pdfDocument.pageCount;

        // Bounce investigation (2026-09-17): device logs from the vision-highlight spike
        // showed the paged view reporting pageChanged 5<->11 forever while JS's `page` prop
        // sat on 14 (the doc's last page) the whole time, never re-triggering a fresh
        // navigate. Log every "page" prop delivery here, including when it's skipped, so a
        // future capture shows whether a second prop update arrived while _isNavigating was
        // still true for the first (which would leave _previousPage stale and unable to
        // recover) versus the currentPage genuinely oscillating inside PDFKit itself.
        if ([changedProps containsObject:@"page"]) {
            PGDBG(@"didSetProps page=%d previousPage=%d isNavigating=%d pageTransitionState=%ld documentLoaded=%d pageCount=%lu enablePaging=%d -> shouldNavigate=%d",
                       _page, _previousPage, _isNavigating, (long)_pageTransitionState, _documentLoaded,
                       _pdfDocument ? (unsigned long)_pdfDocument.pageCount : 0, _enablePaging, shouldNavigateToPage);
        }

        if (shouldNavigateToPage) {
            _isNavigating = YES;
            PDFPage *pdfPage = [_pdfDocument pageAtIndex:_page-1];
            
            if (pdfPage) {
                int targetPage = _page;
                // Use smooth navigation instead of instant jump to prevent full rerender
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!self->_enablePaging) {
                        // For non-paging mode, use animated navigation
                        CGRect pdfPageRect = [pdfPage boundsForBox:kPDFDisplayBoxCropBox];

                        // Handle page rotation
                        if (pdfPage.rotation == 90 || pdfPage.rotation == 270) {
                            pdfPageRect = CGRectMake(0, 0, pdfPageRect.size.height, pdfPageRect.size.width);
                        }

                        CGPoint pointLeftTop = CGPointMake(0, pdfPageRect.size.height);
                        PDFDestination *pdfDest = [[PDFDestination alloc] initWithPage:pdfPage atPoint:pointLeftTop];

                        // Use goToDestination for smooth navigation
                        [self->_pdfView goToDestination:pdfDest];
                        self->_pdfView.scaleFactor = self->_fixScaleFactor * self->_scale;
                        self->_previousPage = self->_page;
                        self->_isNavigating = NO;
                    } else {
                        // Paging mode drives UIPageViewController under the hood. Calling
                        // goToDestination:/goToRect:onPage: here while the user still has a
                        // finger-driven page-turn in flight races UIKit's own transition and
                        // can abort() inside _UIQueuingScrollView (see crash investigation on
                        // 2026-09-12: identical signature in all 3 device crash reports,
                        // queuingScrollView:didEndManualScroll:...). Defer instead of forcing it.
                        [self navigateToPageForPagingMode:pdfPage targetPage:targetPage retriesLeft:10];
                    }
                });
            } else {
                _isNavigating = NO;
            }
        }
        
        // Handle initial page on document load (only when path changes)
        // This handles the case where the document was just loaded and we need to navigate to the initial page
        // Use pathActuallyChanged instead of checking changedProps to ensure we only handle initial page when path actually changed
        if (_pdfDocument && pathActuallyChanged && _documentLoaded) {
            PDFPage *pdfPage = [_pdfDocument pageAtIndex:_page-1];
            if (pdfPage && shouldUsePageViewController) {
                // Paged mode now genuinely engages on the very first load (see the
                // displayMode guard above), so this initial jump has to take the same
                // deferred, transition-aware path every other paged navigation takes,
                // rather than calling goToDestination:/goToRect:onPage: straight into a
                // UIPageViewController that is still being assembled.
                int initialTargetPage = _page;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self navigateToPageForPagingMode:pdfPage targetPage:initialTargetPage retriesLeft:10];
                });
            } else if (pdfPage && _page == 1) {
                // Special case workaround for first page alignment
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_pdfView goToRect:CGRectMake(0, NSUIntegerMax, 1, 1) onPage:pdfPage];
                    self->_previousPage = self->_page;
                });
            } else if (pdfPage) {
                CGRect pdfPageRect = [pdfPage boundsForBox:kPDFDisplayBoxCropBox];
                if (pdfPage.rotation == 90 || pdfPage.rotation == 270) {
                    pdfPageRect = CGRectMake(0, 0, pdfPageRect.size.height, pdfPageRect.size.width);
                }
                CGPoint pointLeftTop = CGPointMake(0, pdfPageRect.size.height);
                PDFDestination *pdfDest = [[PDFDestination alloc] initWithPage:pdfPage atPoint:pointLeftTop];
                [_pdfView goToDestination:pdfDest];
                _pdfView.scaleFactor = _fixScaleFactor*_scale;
                _previousPage = _page;
            }
        }

        _pdfView.backgroundColor = [UIColor clearColor];
        // Page-boundary bounce investigation (2026-10-01): this used to call
        // layoutDocumentView unconditionally on every didSetProps, no matter
        // which prop changed. Combined with highlightRects/skipZoneRects
        // previously always being reported "changed" above (now fixed), that
        // meant a page sitting near a page boundary (e.g. a short cover page)
        // could get nudged back and forth forever: JS mirrors native's own
        // pageChanged report down as the `page` prop -> that round trip alone
        // re-ran a full layoutDocumentView -> PDFKit's own currentPage
        // determination flipped again at the ambiguous boundary -> another
        // pageChanged notification -> JS mirrors again. Real page navigation
        // (shouldNavigateToPage above, and the initial-page block, both gated
        // on "path") already calls goToDestination:/goToRect:onPage:, which
        // does its own layout -- this call was only ever needed for the
        // geometry-affecting props below. highlightRects/skipZoneRects
        // explicitly don't need it: their own setters already redraw the
        // highlight overlay independently (see setHighlightRects/
        // setSkipZoneRects).
        static NSSet<NSString *> *geometryAffectingProps;
        static dispatch_once_t geometryPropsOnceToken;
        dispatch_once(&geometryPropsOnceToken, ^{
            geometryAffectingProps = [NSSet setWithArray:@[
                @"path", @"horizontal", @"singlePage", @"spacing", @"enableRTL",
                @"fitPolicy", @"minScale", @"maxScale", @"scrollEnabled",
                @"showsHorizontalScrollIndicator", @"showsVerticalScrollIndicator",
                @"enablePaging", @"scale",
            ]];
        });
        if ([geometryAffectingProps intersectsSet:[NSSet setWithArray:effectiveChangedProps]]) {
            [_pdfView layoutDocumentView];
        }
        [self setNeedsDisplay];
    }
}


- (void)reactSetFrame:(CGRect)frame
{
    [super reactSetFrame:frame];
    _pdfView.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);

    NSMutableArray *mProps = [_changedProps mutableCopy];
    if (_initialed) {
        [mProps removeObject:@"path"];
    }
    _initialed = YES;

    [self didSetProps:mProps];
    
    // Configure scroll view after layout to ensure it's found
    // This is important because PDFKit creates the scroll view lazily
    if (_documentLoaded && _pdfDocument) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RCTLogInfo(@"🔍 [iOS Scroll] reactSetFrame called, configuring scroll view after layout");
            [self configureScrollView:self->_pdfView enabled:self->_scrollEnabled depth:0];
        });
    }
}


- (void)notifyOnChangeWithMessage:(NSString *)message
{
#ifndef __OPTIMIZE__
    // PGDBG trace (debug builds only): number every event sent to JS. Page events also
    // carry the number as a trailing field (JS reads fields 1-2 by index and ignores
    // extras), so the JS side can log which native event it is handling.
    NSInteger seq = ++_pgdbgEventSeq;
    if ([message hasPrefix:@"pageChanged|"] || [message hasPrefix:@"displayPageChanged|"]) {
        message = [NSString stringWithFormat:@"%@|%ld", message, (long)seq];
    }
    // loadComplete carries the whole table of contents - keep the trace line short.
    NSString *traceMessage = message.length > 160 ? [[message substringToIndex:160] stringByAppendingString:@"…"] : message;
#endif
#ifdef RCT_NEW_ARCH_ENABLED
    if (_eventEmitter != nullptr) {
             std::dynamic_pointer_cast<const RNPDFPdfViewEventEmitter>(_eventEmitter)
                 ->onChange(RNPDFPdfViewEventEmitter::OnChange{.message = RCTStringFromNSString(message)});
        PGDBG(@"-> JS event #%ld: %@", (long)seq, traceMessage);
    } else {
        PGDBG(@"-> JS event #%ld DROPPED - no event emitter: %@", (long)seq, traceMessage);
    }
#else
    _onChange(@{ @"message": message});
    PGDBG(@"-> JS event #%ld (paper): %@", (long)seq, traceMessage);
#endif
}

#ifndef __OPTIMIZE__
// Sends a PGDBG trace line to JS as a "pgdbg|<line>" onChange message. Deliberately not
// through notifyOnChangeWithMessage: (which itself traces every event it sends) and with no
// sequence number, so forwarding can't recurse or shift the real events' numbering.
- (void)pgdbgForwardToJS:(NSString *)line {
#ifdef RCT_NEW_ARCH_ENABLED
    if (_eventEmitter == nullptr) return;
    NSString *message = [@"pgdbg|" stringByAppendingString:[line stringByReplacingOccurrencesOfString:@"|" withString:@"¦"]];
    std::dynamic_pointer_cast<const RNPDFPdfViewEventEmitter>(_eventEmitter)
        ->onChange(RNPDFPdfViewEventEmitter::OnChange{.message = RCTStringFromNSString(message)});
#endif
}

// One-line snapshot of every input the page number depends on, for PGDBG trace lines.
// pdfkitCurrent drives the page number; visible/center are PDFKit's own view of what is
// on screen, logged so a stale currentPage shows up as a disagreement between them.
- (NSString *)pgdbgSnapshot {
    int current = (_pdfDocument && _pdfView.currentPage) ? (int)[_pdfDocument indexForPage:_pdfView.currentPage] + 1 : -1;
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    int center = -1;
    if (_pdfDocument && _pdfView) {
        for (PDFPage *visiblePage in _pdfView.visiblePages) {
            [visible addObject:[NSString stringWithFormat:@"%lu", (unsigned long)[_pdfDocument indexForPage:visiblePage] + 1]];
        }
        CGPoint mid = CGPointMake(CGRectGetMidX(_pdfView.bounds), CGRectGetMidY(_pdfView.bounds));
        PDFPage *centerPage = [_pdfView pageForPoint:mid nearest:YES];
        if (centerPage) {
            center = (int)[_pdfDocument indexForPage:centerPage] + 1;
        }
    }
    return [NSString stringWithFormat:@"pdfkitCurrent=%d visible=[%@] center=%d | _page=%d _previousPage=%d state=%ld gen=%ld navigating=%d paged=%d reconfiguring=%d",
            current, [visible componentsJoinedByString:@","], center, _page, _previousPage,
            (long)_pageTransitionState, (long)_pageTransitionGeneration, _isNavigating,
            _currentUsePageViewController, _isReconfiguringPageViewController];
}

- (NSString *)pgdbgScrollViewKind:(UIScrollView *)scrollView {
    if ([self isPageTurnScrollView:scrollView]) return @"pageTurn";
    return _currentUsePageViewController ? @"pageZoom" : @"main";
}

// Trace only - see the observer registration in initCommonProps.
- (void)onVisiblePagesChanged:(NSNotification *)noti {
    PGDBG(@"PDFKit visiblePagesChanged: %@", [self pgdbgSnapshot]);
}
#endif // !__OPTIMIZE__ (PGDBG trace helpers)

- (void)dealloc{
    [_preloadQueue cancelAllOperations];
    _preloadQueue = nil;
    
    // Clear caches
    [_pageCache removeAllObjects];
    [_preloadedPages removeAllObjects];
    [_performanceMetrics removeAllObjects];
    [_searchCache removeAllObjects];

    _pdfDocument = Nil;
    _pdfView = Nil;

    //Remove notifications
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PDFViewDocumentChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PDFViewPageChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PDFViewScaleChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:PDFViewVisiblePagesChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"RNPDFPageTransitionTeardownDidCompleteNotification" object:nil];

    _doubleTapRecognizer = nil;
    _singleTapRecognizer = nil;
    _longPressRecognizer = nil;
    _doubleTapEmptyRecognizer = nil;
}

#pragma mark notification process
- (void)onDocumentChanged:(NSNotification *)noti
{

    if (_pdfDocument) {

        unsigned long numberOfPages = _pdfDocument.pageCount;
        PDFPage *page = [_pdfDocument pageAtIndex:_pdfDocument.pageCount-1];
        CGSize pageSize = [_pdfView rowSizeForPage:page];
        NSString *jsonString = [self getTableContents];
        
        // Include path in loadComplete message for consistency with Android and reliable path access in JS
        // Format: loadComplete|numberOfPages|width|height|path|tableContents
        NSString *pathValue = @"";
        if (_path != nil && _path.length > 0) {
            pathValue = _path;
        } else if (_pdfDocument.documentURL != nil) {
            // Fallback: try to get path from document URL
            pathValue = _pdfDocument.documentURL.path;
        }
        
        // Debug logging to verify path is being included (using RCTLog so it shows in all builds)
        RCTLogInfo(@"🔍 [iOS] loadComplete: numberOfPages=%lu, width=%f, height=%f, path='%@', pathLength=%lu", 
                   numberOfPages, pageSize.width, pageSize.height, pathValue, (unsigned long)pathValue.length);
        
        // Ensure path is always included in message (even if empty) for consistent parsing
        // Format: loadComplete|numberOfPages|width|height|path|tableContents
        // Use explicit format to ensure path segment is always present
        NSString *message = [NSString stringWithFormat:@"loadComplete|%lu|%f|%f|%@|%@", 
                            numberOfPages, pageSize.width, pageSize.height, 
                            (pathValue != nil ? pathValue : @""), jsonString];
        
        RCTLogInfo(@"🔍 [iOS] loadComplete message: %@", message);
        
        [self notifyOnChangeWithMessage:message];
        
        // Store local path so we can register when pdfId is set (Fabric may set pdfId after document load)
        _lastLoadedPath = [pathValue copy];
        // Register path for searchTextDirect (iOS parity with Android)
        if (_pdfId.length && pathValue.length) {
            [SearchRegistry registerPath:_pdfId path:pathValue];
            RCTLogInfo(@"✅ [iOS] SearchRegistry registered path for pdfId: %@ (from onDocumentChanged)", _pdfId);
        }
    }

}

- (void)setPdfId:(NSString *)pdfId {
    if (_pdfId.length && ![pdfId isEqualToString:_pdfId]) {
        [SearchRegistry unregisterPath:_pdfId];
    }
    _pdfId = [pdfId copy];
    // If document already loaded, register path now (Fabric may set pdfId after path/document load).
    // Only register local file paths; never register URIs (http/https) - PDFDocument needs file path.
    NSString *pathToRegister = nil;
    if (_lastLoadedPath.length > 0) {
        pathToRegister = _lastLoadedPath;
    } else if (_path.length > 0 && [_path hasPrefix:@"/"]) {
        pathToRegister = _path;
    }
    if (_pdfId.length && pathToRegister.length > 0) {
        [SearchRegistry registerPath:_pdfId path:pathToRegister];
        RCTLogInfo(@"✅ [iOS] SearchRegistry registered path for pdfId: %@ (from setPdfId)", _pdfId);
    }
}

/** Returns the PDFKit content view that actually zooms, so highlights scale/pan with the page instead of floating above it. */
- (UIView *)highlightContainerView {
    if (_pdfView.documentView) {
        return _pdfView.documentView;
    }

    UIScrollView *scrollView = [self activeZoomScrollView];
    for (UIView *subview in scrollView.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className containsString:@"PDFDocumentView"] || [className containsString:@"PDFPage"]) {
            return subview;
        }
    }

    return _pdfView;
}

/** Lazily creates the shared overlay (used by both highlightRects and skipZoneRects) on first use by either. */
- (void)ensureHighlightOverlay {
    if (_highlightOverlay || !_pdfView) return;
    UIView *container = [self highlightContainerView];
    _highlightOverlay = [[HighlightOverlayView alloc] initWithFrame:container.bounds];
    _highlightOverlay.backgroundColor = [UIColor clearColor];
    _highlightOverlay.userInteractionEnabled = NO;
    _highlightOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _highlightOverlay.pdfView = _pdfView;
    [container addSubview:_highlightOverlay];
    [container bringSubviewToFront:_highlightOverlay];
}

// REVERTED (2026-09-17): an earlier version of this function made setNeedsDisplay
// conditional on the overlay's frame/transform actually changing, on the theory that
// UIKit would composite container's zoom transform onto the overlay's already-drawn
// content for free. Confirmed wrong by hands-on device testing: container.bounds stays
// constant across zoom (that part was right), but -drawRect: below does NOT draw in a
// stable, transform-inheriting coordinate space — it calls -convertRect:fromView: (a
// live, zoom-aware PDFView-space query) per rect, so the drawn content is only correct
// for the zoom scale at the moment -drawRect: last actually ran. Making setNeedsDisplay
// conditional froze the highlight at its pre-gesture position for the whole gesture,
// only catching up once something else (unrelated) triggered a redraw at release —
// worse than the original lag. Back to unconditional per-delta redraw; the real fix for
// the lag has to make -drawRect:'s per-frame work cheaper (see its own comments), not
// skip triggering it.
- (void)refreshHighlightOverlayContainer {
    if (!_highlightOverlay || !_pdfView) return;

    UIView *container = [self highlightContainerView];
    if (_highlightOverlay.superview != container) {
        RCTLogInfo(@"🖍️ [iOS Highlight] overlay container %@ -> %@ (paged=%d)",
                   _highlightOverlay.superview ? NSStringFromClass([_highlightOverlay.superview class]) : @"(none)",
                   NSStringFromClass([container class]), _currentUsePageViewController);
        [_highlightOverlay removeFromSuperview];
        [container addSubview:_highlightOverlay];
    }
    _highlightOverlay.transform = CGAffineTransformIdentity;
    _highlightOverlay.frame = container.bounds;
    [container bringSubviewToFront:_highlightOverlay];
    [_highlightOverlay setNeedsDisplay];
}

- (void)setHighlightRects:(NSArray *)highlightRects {
    _highlightRects = [highlightRects copy];
    if (!_pdfView) return;
    if (_highlightRects.count > 0) {
        [self ensureHighlightOverlay];
        _highlightOverlay.highlightRects = _highlightRects;
        [_highlightOverlay setNeedsDisplay];
    } else if (_highlightOverlay) {
        _highlightOverlay.highlightRects = @[];
        [_highlightOverlay setNeedsDisplay];
    }
}

/** Header/footer skip-zone hatch bands, drawn on the same PDFKit-anchored overlay as highlightRects so they track zoom/pan exactly instead of the old fixed-screen-space JS overlay. */
- (void)setSkipZoneRects:(NSArray *)skipZoneRects {
    _skipZoneRects = [skipZoneRects copy];
    if (!_pdfView) return;
    if (_skipZoneRects.count > 0) {
        [self ensureHighlightOverlay];
        _highlightOverlay.skipZoneRects = _skipZoneRects;
        [_highlightOverlay setNeedsDisplay];
    } else if (_highlightOverlay) {
        _highlightOverlay.skipZoneRects = @[];
        [_highlightOverlay setNeedsDisplay];
    }
}

-(NSString *) getTableContents
{

    NSMutableArray<PDFOutline *> *arrTableOfContents = [[NSMutableArray alloc] init];

    if (_pdfDocument.outlineRoot) {

        PDFOutline *currentRoot = _pdfDocument.outlineRoot;
        NSMutableArray<PDFOutline *> *stack = [[NSMutableArray alloc] init];

        [stack addObject:currentRoot];

        while (stack.count > 0) {

            PDFOutline *currentOutline = stack.lastObject;
            [stack removeLastObject];

            if (currentOutline.label.length > 0){
                [arrTableOfContents addObject:currentOutline];
            }

            for ( NSInteger i= currentOutline.numberOfChildren; i > 0; i-- )
            {
                [stack addObject:[currentOutline childAtIndex:i-1]];
            }
        }
    }

    NSMutableArray *arrParentsContents = [[NSMutableArray alloc] init];

    for ( NSInteger i= 0; i < arrTableOfContents.count; i++ )
    {
        PDFOutline *currentOutline = [arrTableOfContents objectAtIndex:i];

        NSInteger indentationLevel = -1;

        PDFOutline *parentOutline = currentOutline.parent;

        while (parentOutline != nil) {
            indentationLevel += 1;
            parentOutline = parentOutline.parent;
        }

        if (indentationLevel == 0) {

            NSMutableDictionary *DXParentsContent = [[NSMutableDictionary alloc] init];

            [DXParentsContent setObject:[[NSMutableArray alloc] init] forKey:@"children"];
            [DXParentsContent setObject:@"" forKey:@"mNativePtr"];
            [DXParentsContent setObject:[NSString stringWithFormat:@"%lu", [_pdfDocument indexForPage:currentOutline.destination.page]] forKey:@"pageIdx"];
            [DXParentsContent setObject:currentOutline.label forKey:@"title"];

            //currentOutlin
            //mNativePtr
            [arrParentsContents addObject:DXParentsContent];
        }
        else {
            NSMutableDictionary *DXParentsContent = [arrParentsContents lastObject];

            NSMutableArray *arrChildren = [DXParentsContent valueForKey:@"children"];

            while (indentationLevel > 1) {
                NSMutableDictionary *DXchild = [arrChildren lastObject];
                arrChildren = [DXchild valueForKey:@"children"];
                indentationLevel--;
            }

            NSMutableDictionary *DXChildContent = [[NSMutableDictionary alloc] init];
            [DXChildContent setObject:[[NSMutableArray alloc] init] forKey:@"children"];
            [DXChildContent setObject:@"" forKey:@"mNativePtr"];
            [DXChildContent setObject:[NSString stringWithFormat:@"%lu", [_pdfDocument indexForPage:currentOutline.destination.page]] forKey:@"pageIdx"];
            [DXChildContent setObject:currentOutline.label forKey:@"title"];
            [arrChildren addObject:DXChildContent];

        }
    }

    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:arrParentsContents options:NSJSONWritingPrettyPrinted error:&error];

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    return jsonString;

}

- (void)onPageChanged:(NSNotification *)noti
{
    PGDBG(@"onPageChanged ENTER (source=%@) %@",
          noti ? @"PDFViewPageChangedNotification" : @"settle cross-check",
          [self pgdbgSnapshot]);

    if (_pdfDocument) {
        PDFPage *currentPage = _pdfView.currentPage;
        unsigned long page = [_pdfDocument indexForPage:currentPage];
        unsigned long numberOfPages = _pdfDocument.pageCount;

        // Update current page for preloading
        int newPage = (int)page + 1;

        // Initial-page bug (real repro, 2026-09-30): assigning `_pdfView.document =` above
        // makes PDFKit synchronously default its own currentPage to page 1 and post this
        // notification, before the "Handle initial page on document load" block in
        // didSetProps (dispatch_async'd) has run the real navigation to the JS-requested
        // `page` prop (e.g. 258). Without this guard, the block below stomped `_page` (still
        // correctly holding 258) with this transient 1, corrupting the pending initial
        // navigation — visible on device as a flash to page 1 that then bounced through an
        // intermediate page before landing on the right one. `_previousPage == -1` is the
        // sentinel set right when a document starts loading (see path-change handling above)
        // and cleared by the first real page-changed report, so this only ever suppresses
        // that one spurious pre-navigation notification, never a genuine page 1 open.
        if (_previousPage == -1 && _page != 1 && newPage == 1) {
            PGDBG(@"onPageChanged DROPPED (guard: transient default-to-page-1 before initial navigation to page %d)", _page);
            return;
        }

        // Toggling the single-page-view switch mid-document rebuilds PDFKit's view, and every
        // page change PDFKit posts during that rebuild is transient: its reset to page 1
        // (see _isReconfiguringPageViewController's declaration), and also its stale
        // paged-mode currentPage - device trace 2026-10-02: toggling to continuous while on
        // page 4 posted page 3 (paged mode commits turns late, see
        // reportOnScreenPageIfChanged:) before the restore posted 4, which would flash
        // "3/N". reconfigureUsePageViewControllerIfNeededWithRetriesLeft: restores the real
        // page (_page, which JS already has) once the rebuild settles, so drop all of them.
        if (_isReconfiguringPageViewController) {
            PGDBG(@"onPageChanged DROPPED (single-page-view toggle rebuilding; PDFKit says %d, real page %d)", newPage, _page);
            return;
        }

        if (_currentUsePageViewController) {
            // Paged mode: PDFKit commits a finger-driven page turn late - at the start of
            // the NEXT touch - and the currentPage it commits can itself be stale. Device
            // trace (2026-10-02): swiping back from the last page, currentPage stayed 14
            // while pages 13 and 12 were shown, then this notification fired with 14 as the
            // next swipe began and the indicator jumped to "14/14". Mid page-turn it is only
            // ever such a late commit; the turn reports its own page when it comes to rest
            // (reportOnScreenPageIfChanged:), so ignore it.
            if (noti != nil && _pageTransitionState != RNPDFPageTransitionIdle) {
                PGDBG(@"onPageChanged IGNORED mid page-turn (PDFKit late commit, currentPage=%d, on screen=%d) %@",
                      newPage, [self onScreenPageNumber], [self pgdbgSnapshot]);
                return;
            }
            // Otherwise prefer what is actually on screen if PDFKit's currentPage disagrees -
            // except mid single-page-view toggle, where the screen is the one that's
            // transiently wrong (page 1, see updateDisplayPageForScrollIfNeeded).
            int onScreenPage = _isReconfiguringPageViewController ? -1 : [self onScreenPageNumber];
            if (onScreenPage >= 1 && onScreenPage != newPage) {
                PGDBG(@"onPageChanged: PDFKit currentPage=%d disagrees with page on screen=%d - using the on-screen page",
                      newPage, onScreenPage);
                newPage = onScreenPage;
                page = (unsigned long)(onScreenPage - 1);
            }
        }

        // CRITICAL FIX: Update _previousPage to the new page value when page changes from PDFView notifications
        // This prevents updateProps from triggering programmatic navigation when React Native
        // receives the pageChanged notification and updates the page prop back to us.
        // By setting _previousPage = newPage, when updateProps checks _page != _previousPage,
        // they will be equal (since the page prop will match the new page), and navigation will be skipped.
        if (newPage != _page) {
            _previousPage = newPage;  // Set to newPage to prevent navigation loop
            _page = newPage;
        } else {
            // If page didn't actually change, just ensure _previousPage matches to prevent navigation
            _previousPage = _page;
        }
        // Keep the display-only scroll tracker (see updateDisplayPageForScrollIfNeeded)
        // in sync with the authoritative source whenever it fires — e.g. paging-mode
        // swipes, or a programmatic jump — so it doesn't drift and isn't left stale
        // from before this document/mode was active.
        _displayPage = _page;

        _pageCount = (int)numberOfPages;
        if (_enablePreloading) {
            [self preloadAdjacentPages:_page];
        }

        RLog(@"Enhanced PDF: Navigated to page %d", _page);
        // Bounce investigation (2026-09-17) — see the shouldNavigateToPage log in
        // didSetProps: tag every PDFViewPageChangedNotification with whether we were mid
        // programmatic navigate/transition when it fired, to tell "PDFKit's currentPage is
        // genuinely oscillating" apart from "we kept re-triggering navigate ourselves".
        RCTLogInfo(@"🔁 [iOS PageChanged] currentPage=%d isNavigating=%d pageTransitionState=%ld",
                   _page, _isNavigating, (long)_pageTransitionState);
        PGDBG(@"onPageChanged REPORT page %lu/%lu to JS", page + 1, numberOfPages);
        [self notifyOnChangeWithMessage:[[NSString alloc] initWithString:[NSString stringWithFormat:@"pageChanged|%lu|%lu", page+1, numberOfPages]]];
        if (_highlightOverlay) [_highlightOverlay setNeedsDisplay];
        if (_currentUsePageViewController) {
            // Hook the newly shown page's own zoom scroller (programmatic page changes
            // never pass through the swipe settle path, which does this too) - otherwise
            // pinching it never reaches scrollViewDidZoom: and the highlight overlay
            // stops tracking the zoom.
            [self scheduleScrollViewHookPass];
        }
    }

}

- (void)onScaleChanged:(NSNotification *)noti
{
    // Paged mode: the visible page's own scroll view is the single source of truth for
    // zoom (see scrollViewDidZoom:). PDFView.scaleFactor isn't tied to one particular
    // page's scroller there, and reading it from more than one place is what produced
    // device logs (2026-10-01) of one pinch reporting 1.127 and then 1.000 within the
    // same millisecond - each round-tripping through JS's `scale` prop and snapping the
    // zoom back and forth, with the highlight jumping along with it.
    if (_currentUsePageViewController) {
        if (_highlightOverlay) [_highlightOverlay setNeedsDisplay];
        return;
    }
    if (_initialed && _fixScaleFactor>0) {
        float newScale = _pdfView.scaleFactor/_fixScaleFactor;
        // Only notify if scale changed significantly (threshold of 0.01 to prevent excessive callbacks)
        if (fabs(_scale - newScale) > 0.01f) {
            _scale = newScale;
            [self reportScaleToJS];
        }
    }
    if (_highlightOverlay) [_highlightOverlay setNeedsDisplay];
}

#pragma mark gesture process

/**
 *  Empty double tap handler
 *
 *
 */
- (void)handleDoubleTapEmpty:(UITapGestureRecognizer *)recognizer {}

/**
 *  Tap
 *  zoom reset or zoom in
 *
 *  @param recognizer The tap gesture recognizer
 */
- (void)handleDoubleTap:(UITapGestureRecognizer *)recognizer
{

    // Prevent double tap from selecting text.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_pdfView clearSelection];
    });

    // A double tap can land at the tail of an in-flight finger-driven page
    // swipe in paging mode, just like the single tap this same guard
    // protects below (see handleSingleTap: and the _pageTransitionState
    // comment on the ivar declaration). goToRect:onPage: below races
    // UIKit's own _UIQueuingScrollView transition cleanup the same way
    // navigateToPageForPagingMode:'s goToDestination:/goToRect:onPage: did
    // in the 2026-09-12/2026-09-15 device crashes (queuingScrollView:
    // didEndManualScroll:... -> abort()); this was the one call site still
    // missing that guard as of the 2026-09-17 recurrence.
    if (_pageTransitionState != RNPDFPageTransitionIdle) {
        RCTLogInfo(@"👆 [iOS Scroll] Ignoring double tap - page transition state=%ld (not Idle)",
                   (long)_pageTransitionState);
        return;
    }

    // Broadcast for JS same as handleSingleTap: below, so tap-to-play can be
    // driven off a double tap instead of a single tap — a double tap is a
    // much more deliberate gesture than a single tap, which is easily
    // misfired by the trailing edge of a swipe (see the pageSingleTap guard
    // comment above). Reported unconditionally, even when _enableDoubleTapZoom
    // is off, since JS may use double tap purely for tap-to-play with zoom
    // disabled.
    CGPoint tapPointInSelf = [recognizer locationInView:self];
    PDFPage *tappedPdfPageForEvent = [_pdfView pageForPoint:tapPointInSelf nearest:NO];
    if (tappedPdfPageForEvent) {
        unsigned long pageForEvent = [_pdfDocument indexForPage:tappedPdfPageForEvent];
        [self notifyOnChangeWithMessage:
         [[NSString alloc] initWithString:[NSString stringWithFormat:@"pageDoubleTap|%lu|%f|%f", pageForEvent+1, tapPointInSelf.x, tapPointInSelf.y]]];
    }

    if (!_enableDoubleTapZoom) {
        return;
    }

    // Cycle through min/mid/max scale factors to be consistent with Android
    float min = self->_pdfView.minScaleFactor/self->_fixScaleFactor;
    float max = self->_pdfView.maxScaleFactor/self->_fixScaleFactor;
    float mid = (max - min) / 2 + min;
    float scale = self->_scale;
    if (self->_scale < mid) {
        scale = mid;
    } else if (self->_scale < max) {
        scale = max;
    } else {
        scale = min;
    }

    CGFloat newScale = scale * self->_fixScaleFactor;
    CGPoint tapPoint = [recognizer locationInView:self->_pdfView];

    PDFPage *tappedPdfPage = [_pdfView pageForPoint:tapPoint nearest:NO];
    PDFPage *pageRef;
    if (tappedPdfPage) {
        pageRef = tappedPdfPage;
    }   else {
        pageRef = self->_pdfView.currentPage;
    }
    tapPoint = [self->_pdfView convertPoint:tapPoint toPage:pageRef];

    CGRect tempZoomRect = CGRectZero;
    tempZoomRect.size.width = self->_pdfView.frame.size.width;
    tempZoomRect.size.height = 1;
    tempZoomRect.origin = tapPoint;

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            [self->_pdfView setScaleFactor:newScale];

            [self->_pdfView goToRect:tempZoomRect onPage:pageRef];
            CGPoint defZoomOrigin = [self->_pdfView convertPoint:tempZoomRect.origin fromPage:pageRef];
            defZoomOrigin.x = defZoomOrigin.x - self->_pdfView.frame.size.width / 2;
            defZoomOrigin.y = defZoomOrigin.y - self->_pdfView.frame.size.height / 2;
            defZoomOrigin = [self->_pdfView convertPoint:defZoomOrigin toPage:pageRef];
            CGRect defZoomRect =  CGRectOffset(
                tempZoomRect,
                defZoomOrigin.x - tempZoomRect.origin.x,
                defZoomOrigin.y - tempZoomRect.origin.y
            );
            [self->_pdfView goToRect:defZoomRect onPage:pageRef];

            [self setNeedsDisplay];
            [self onScaleChanged:Nil];
        }];
    });
}

/**
 *  Single Tap
 *  stop zoom
 *
 *  @param sender The tap gesture recognizer
 */
- (void)handleSingleTap:(UITapGestureRecognizer *)sender
{
    //_pdfView.scaleFactor = _pdfView.minScaleFactor;

    // A discrete tap can still land while the page view is Settling from a
    // just-finished swipe (UIKit's own transition hasn't fully unwound yet -
    // see _pageTransitionState). That tap is the tail end of the swipe
    // gesture arriving a beat late, not the user deliberately tapping a
    // sentence to play it - honoring it as "tap to play" is exactly the
    // second, colliding page-navigation trigger that caused the 2026-09-15
    // crash (JS's follow-playback effect calling setPage in response). Only
    // forward taps seen once the page has fully settled (Idle).
    if (_pageTransitionState != RNPDFPageTransitionIdle) {
        RCTLogInfo(@"👆 [iOS Scroll] Ignoring single tap - page transition state=%ld (not Idle)",
                   (long)_pageTransitionState);
        return;
    }

    CGPoint point = [sender locationInView:self];
    PDFPage *pdfPage = [_pdfView pageForPoint:point nearest:NO];
    if (pdfPage) {
        unsigned long page = [_pdfDocument indexForPage:pdfPage];
        [self notifyOnChangeWithMessage:
         [[NSString alloc] initWithString:[NSString stringWithFormat:@"pageSingleTap|%lu|%f|%f", page+1, point.x, point.y]]];
    }

    //[self setNeedsDisplay];
    //[self onScaleChanged:Nil];


}

/**
 *  Do nothing on long Press
 *
 *
 */
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender{

}

/**
 *  Bind tap
 *
 *
 */
- (void)bindTap
{
    UITapGestureRecognizer *doubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(handleDoubleTap:)];
    //trigger by one finger and double touch
    doubleTapRecognizer.numberOfTapsRequired = 2;
    doubleTapRecognizer.numberOfTouchesRequired = 1;
    doubleTapRecognizer.delegate = self;

    [self addGestureRecognizer:doubleTapRecognizer];
    _doubleTapRecognizer = doubleTapRecognizer;

    UITapGestureRecognizer *singleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(handleSingleTap:)];
    //trigger by one finger and one touch
    singleTapRecognizer.numberOfTapsRequired = 1;
    singleTapRecognizer.numberOfTouchesRequired = 1;
    singleTapRecognizer.delegate = self;

    [self addGestureRecognizer:singleTapRecognizer];
    _singleTapRecognizer = singleTapRecognizer;

    [singleTapRecognizer requireGestureRecognizerToFail:doubleTapRecognizer];

    UILongPressGestureRecognizer *longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                            action:@selector(handleLongPress:)];
    // Making sure the allowable movement isn not too narrow
    longPressRecognizer.allowableMovement=100;
    // Important: The duration must be long enough to allow taps but not longer than the period in which view opens the magnifying glass
    longPressRecognizer.minimumPressDuration=0.3;

    [self addGestureRecognizer:longPressRecognizer];
    _longPressRecognizer = longPressRecognizer;

    // Override the _pdfView double tap gesture recognizer so that it doesn't confilict with custom double tap
    UITapGestureRecognizer *doubleTapEmptyRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(handleDoubleTapEmpty:)];
    doubleTapEmptyRecognizer.numberOfTapsRequired = 2;
    [_pdfView addGestureRecognizer:doubleTapEmptyRecognizer];
    _doubleTapEmptyRecognizer = doubleTapEmptyRecognizer;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer

{
    return !_singlePage;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return !_singlePage;
}

- (void)setScrollIndicators:(UIView *)view horizontal:(BOOL)horizontal vertical:(BOOL)vertical depth:(int)depth {
    // max depth, prevent infinite loop
    if (depth > 10) {
        return;
    }
    
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        scrollView.showsHorizontalScrollIndicator = horizontal;
        scrollView.showsVerticalScrollIndicator = vertical;
    }
    
    for (UIView *subview in view.subviews) {
        [self setScrollIndicators:subview horizontal:horizontal vertical:vertical depth:depth + 1];
    }
}

// Walks PDFKit's view hierarchy and hooks every scroll view in it. Safe to call as often
// as layout passes happen: already-hooked scroll views are left alone, and nothing here
// touches a scroll view's current zoom except clamping it into range.
//
// Paged mode has two kinds of scroll view (device logs, 2026-10-01):
//  - UIPageViewController's page-turn scroller (_UIQueuingScrollView, delegate
//    PDFDocumentViewController) - scrolls between pages, must never zoom;
//  - one zoom scroller per page (delegate PDFPageViewController, zoom view
//    PDFTextInputView) - this is where pinch-zoom actually happens.
// Continuous mode has one (PDFScrollView, its own delegate) that does both.
- (void)configureScrollView:(UIView *)view enabled:(BOOL)enabled depth:(int)depth {
    if (depth == 0) {
        RCTLogInfo(@"🚀 [iOS Scroll] configureScrollView called - enabled=%d, view=%@, paged=%d",
                   enabled, NSStringFromClass([view class]), _currentUsePageViewController);
    }

    // max depth, prevent infinite loop
    if (depth > 10) {
        RCTLogWarn(@"⚠️ [iOS Scroll] Max depth reached in configureScrollView (depth=%d)", depth);
        return;
    }

    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        [self hookScrollViewDelegateIfNeeded:scrollView];

        scrollView.scrollEnabled = enabled;
        // Allow horizontal bounce only when scrolling horizontally - for vertical scrolling
        // it would interfere with the navigation swipe-back gesture.
        scrollView.alwaysBounceHorizontal = _horizontal;
        // Keep vertical bounce enabled for natural scrolling feel
        scrollView.bounces = YES;

        if ([self isPageTurnScrollView:scrollView]) {
            // Every scroll view used to get zoom limits here, which made this one
            // pinch-zoomable too (with a scroll indicator as its "zoom view"), competing
            // with the page's real zoom scroller for the same pinch and distorting the
            // page-turn layout itself.
            if (scrollView.minimumZoomScale != 1 || scrollView.maximumZoomScale != 1) {
                RCTLogWarn(@"⚠️ [iOS Zoom] Page-turn scroller had zoom range %f..%f - resetting to 1..1",
                           scrollView.minimumZoomScale, scrollView.maximumZoomScale);
                scrollView.minimumZoomScale = 1;
                scrollView.maximumZoomScale = 1;
            }
        } else {
            [self applyZoomLimitsToScrollView:scrollView];
            _internalScrollView = scrollView;
        }
    }

    for (UIView *subview in view.subviews) {
        [self configureScrollView:subview enabled:enabled depth:depth + 1];
    }

    // Log at root level if no scroll view was found
    if (depth == 0 && !_internalScrollView) {
        RCTLogWarn(@"⚠️ [iOS Scroll] No zoomable UIScrollView found in view hierarchy (view=%@, subviewCount=%lu)",
                  NSStringFromClass([view class]),
                  (unsigned long)[view.subviews count]);
    }
}

// Coalesces "hook whatever scroll views exist now" requests into one pass per run-loop
// turn - UIPageViewController creates a new page's scroll view on every page change.
- (void)scheduleScrollViewHookPass {
    if (_scrollViewHookPassScheduled) return;
    _scrollViewHookPassScheduled = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_scrollViewHookPassScheduled = NO;
        if (strongSelf->_pdfDocument && strongSelf->_pdfView) {
            [strongSelf configureScrollView:strongSelf->_pdfView enabled:strongSelf->_scrollEnabled depth:0];
        }
    });
}

#pragma mark - Scroll view delegate hooking

- (BOOL)scrollView:(UIScrollView *)scrollView looksLikePageTurnScrollerWithDelegate:(id)originalDelegate {
    if ([originalDelegate isKindOfClass:[UIPageViewController class]]) {
        return YES;
    }
    return [NSStringFromClass([scrollView class]) containsString:@"QueuingScrollView"];
}

// UIPageViewController's own page-turn scroller (paged mode only).
- (BOOL)isPageTurnScrollView:(UIScrollView *)scrollView {
    RNPDFScrollViewDelegateProxy *proxy = objc_getAssociatedObject(scrollView, kRNPDFScrollDelegateProxyKey);
    if (proxy) {
        return proxy.isPageTurnScrollView;
    }
    id delegate = scrollView.delegate;
    if ([delegate isKindOfClass:[RNPDFScrollViewDelegateProxy class]]) {
        delegate = [(RNPDFScrollViewDelegateProxy *)delegate primaryDelegate];
    }
    return [self scrollView:scrollView looksLikePageTurnScrollerWithDelegate:delegate];
}

// Wraps the scroll view's current (PDFKit) delegate in a proxy owned by the scroll view
// itself - see RNPDFScrollViewDelegateProxy for why ownership matters. Idempotent.
- (void)hookScrollViewDelegateIfNeeded:(UIScrollView *)scrollView {
    id currentDelegate = scrollView.delegate;
    if ([currentDelegate isKindOfClass:[RNPDFScrollViewDelegateProxy class]]) {
        RNPDFScrollViewDelegateProxy *existing = (RNPDFScrollViewDelegateProxy *)currentDelegate;
        if ([existing secondaryDelegate] == (id)self) {
            return;
        }
        // Left over from another (recycled) RNPDFPdfView - unwrap to PDFKit's own delegate.
        currentDelegate = [existing primaryDelegate];
    }
    if (currentDelegate == (id)self) {
        currentDelegate = nil;
    }

    RNPDFScrollViewDelegateProxy *proxy = [[RNPDFScrollViewDelegateProxy alloc] initWithPrimary:currentDelegate
                                                                                     secondary:(id<UIScrollViewDelegate>)self];
    proxy.isPageTurnScrollView = [self scrollView:scrollView looksLikePageTurnScrollerWithDelegate:currentDelegate];
    objc_setAssociatedObject(scrollView, kRNPDFScrollDelegateProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    scrollView.delegate = proxy;
    RCTLogInfo(@"🔗 [iOS Scroll] Hooked %@ (original delegate: %@, pageTurn=%d, frame=%@, contentSize=%@)",
               NSStringFromClass([scrollView class]),
               currentDelegate ? NSStringFromClass([currentDelegate class]) : @"(none)",
               proxy.isPageTurnScrollView,
               NSStringFromCGRect(scrollView.frame),
               NSStringFromCGSize(scrollView.contentSize));
}

// Hands every scroll view we hooked back to PDFKit's own delegate.
- (void)unhookScrollViewDelegatesInView:(UIView *)view depth:(int)depth {
    if (!view || depth > 10) return;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        id currentDelegate = scrollView.delegate;
        if ([currentDelegate isKindOfClass:[RNPDFScrollViewDelegateProxy class]] &&
            [(RNPDFScrollViewDelegateProxy *)currentDelegate secondaryDelegate] == (id)self) {
            // Restore first, then drop the proxy - it must not be released while it is
            // still the scroll view's delegate.
            scrollView.delegate = [(RNPDFScrollViewDelegateProxy *)currentDelegate primaryDelegate];
            objc_setAssociatedObject(scrollView, kRNPDFScrollDelegateProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIView *subview in view.subviews) {
        [self unhookScrollViewDelegatesInView:subview depth:depth + 1];
    }
}

#pragma mark - Zoom scroll views

// min/max from the JS-facing minScale/maxScale. The current zoom is only clamped into
// that range, never reset - this used to force zoomScale = _pdfView.scaleFactor on every
// configure pass, i.e. on every layout change.
- (void)applyZoomLimitsToScrollView:(UIScrollView *)scrollView {
    if (_fixScaleFactor <= 0 || [self isPageTurnScrollView:scrollView]) return;
    CGFloat minZoom = _fixScaleFactor * _minScale;
    CGFloat maxZoom = _fixScaleFactor * _maxScale;
    if (scrollView.minimumZoomScale != minZoom) scrollView.minimumZoomScale = minZoom;
    if (scrollView.maximumZoomScale != maxZoom) scrollView.maximumZoomScale = maxZoom;
    if (!_isLiveZooming) {
        if (scrollView.zoomScale < minZoom - 0.0001) {
            scrollView.zoomScale = minZoom;
        } else if (scrollView.zoomScale > maxZoom + 0.0001) {
            scrollView.zoomScale = maxZoom;
        }
    }
}

- (void)collectPageZoomScrollViewsInView:(UIView *)view depth:(int)depth into:(NSMutableArray<UIScrollView *> *)result {
    if (!view || depth > 10) return;
    if ([view isKindOfClass:[UIScrollView class]] && ![self isPageTurnScrollView:(UIScrollView *)view]) {
        [result addObject:(UIScrollView *)view];
    }
    for (UIView *subview in view.subviews) {
        [self collectPageZoomScrollViewsInView:subview depth:depth + 1 into:result];
    }
}

// Fraction of the PDF view's area this scroll view currently covers on screen (0..1).
- (CGFloat)visibleFractionOfScrollView:(UIScrollView *)scrollView {
    if (!_pdfView || !scrollView.window || scrollView.hidden) return 0;
    CGRect pdfBounds = _pdfView.bounds;
    CGFloat pdfArea = pdfBounds.size.width * pdfBounds.size.height;
    if (pdfArea <= 0) return 0;
    CGRect frameInPdfView = [scrollView convertRect:scrollView.bounds toView:_pdfView];
    CGRect visible = CGRectIntersection(frameInPdfView, pdfBounds);
    if (CGRectIsNull(visible)) return 0;
    return (visible.size.width * visible.size.height) / pdfArea;
}

// Paged mode: the zoom scroller of the page actually on screen. UIPageViewController keeps
// neighbor pages loaded (each with its own zoom scroller) just off screen.
- (UIScrollView *)visiblePageZoomScrollView {
    NSMutableArray<UIScrollView *> *candidates = [NSMutableArray array];
    [self collectPageZoomScrollViewsInView:_pdfView depth:0 into:candidates];
    UIScrollView *best = nil;
    CGFloat bestFraction = 0;
    for (UIScrollView *candidate in candidates) {
        CGFloat fraction = [self visibleFractionOfScrollView:candidate];
        if (fraction > bestFraction) {
            bestFraction = fraction;
            best = candidate;
        }
    }
    return best;
}

- (UIScrollView *)activeZoomScrollView {
    return _currentUsePageViewController ? [self visiblePageZoomScrollView] : _internalScrollView;
}

// Paged mode counterpart of the `scale` prop branch in didSetProps.
- (void)applyScaleToVisiblePageScrollView {
    if (_fixScaleFactor <= 0) return;
    UIScrollView *scrollView = [self visiblePageZoomScrollView];
    if (!scrollView) return;
    [self applyZoomLimitsToScrollView:scrollView];
    CGFloat target = MIN(MAX(_scale * _fixScaleFactor, scrollView.minimumZoomScale), scrollView.maximumZoomScale);
    if (fabs(scrollView.zoomScale - target) > 0.001) {
        PGDBG(@"zoom: Applying scale prop %f to visible page scroller (zoom %f -> %f)",
                   _scale, scrollView.zoomScale, target);
        scrollView.zoomScale = target;
    }
}

// Paged mode: make _scale (and JS) match the page now on screen, reporting at most once.
- (void)syncScaleFromVisiblePageScrollView {
    if (_fixScaleFactor <= 0) return;
    UIScrollView *scrollView = [self visiblePageZoomScrollView];
    if (!scrollView) return;
    float newScale = scrollView.zoomScale / _fixScaleFactor;
    if (fabs(_scale - newScale) > 0.01f) {
        PGDBG(@"zoom: Visible page scale %f differs from reported %f - reporting it", newScale, _scale);
        _scale = newScale;
        [self reportScaleToJS];
    }
}

// Every scaleChanged report goes through here, so updateProps: can tell JS's echo of it
// apart from a real scale request.
- (void)reportScaleToJS {
    [_pendingScaleEchoes addObject:@(_scale)];
    if (_pendingScaleEchoes.count > 32) {
        [_pendingScaleEchoes removeObjectAtIndex:0];
    }
    _jsKnownScale = _scale;
    [self notifyOnChangeWithMessage:[NSString stringWithFormat:@"scaleChanged|%f", _scale]];
}

// Earliest not-yet-echoed report matching `scale`: JS echoes reports in order, possibly
// skipping some React batched together, so everything before the match is stale too.
- (NSUInteger)indexOfPendingScaleEcho:(double)scale {
    for (NSUInteger i = 0; i < _pendingScaleEchoes.count; i++) {
        if (fabs(_pendingScaleEchoes[i].doubleValue - scale) < 0.0005) {
            return i;
        }
    }
    return NSNotFound;
}

#pragma mark - Paged mode page-turn follow-up

// Called when a finger-driven page turn begins on the page-turn scroller: remember the
// zoom and horizontal position of the page being left.
- (void)capturePagingZoomCarry {
    UIScrollView *pageScrollView = [self visiblePageZoomScrollView];
    if (!pageScrollView || _fixScaleFactor <= 0) {
        _pagingCarryValid = NO;
        return;
    }
    _pagingCarryValid = YES;
    _pagingCarryToken++;
    _pagingCarryFromScrollView = pageScrollView;
    _pagingCarryIncomingScrollView = nil;
    _pagingCarryFromPage = _pdfView.currentPage ? (int)[_pdfDocument indexForPage:_pdfView.currentPage] + 1 : _page;
    _pagingCarryRatio = pageScrollView.zoomScale / _fixScaleFactor;
    UIEdgeInsets inset = pageScrollView.adjustedContentInset;
    CGFloat minX = -inset.left;
    CGFloat maxX = pageScrollView.contentSize.width - pageScrollView.bounds.size.width + inset.right;
    CGFloat fracX = (maxX - minX > 1) ? (pageScrollView.contentOffset.x - minX) / (maxX - minX) : 0.5;
    _pagingCarryFracX = MIN(MAX(fracX, 0), 1);
    // The page being left is not an "incoming" page for this turn.
    objc_setAssociatedObject(pageScrollView, kRNPDFPagingCarryTokenKey, @(_pagingCarryToken), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PGDBG(@"paging:Page turn started on page %d: scale=%.3f fracX=%.3f",
               _pagingCarryFromPage, _pagingCarryRatio, _pagingCarryFracX);
}

// Gives a page scroller the carried zoom: same scale and horizontal position as the page
// being left, entering at the top of the next page / bottom of the previous one (what
// continuous scrolling would show). At ~1x it only undoes a stale zoom left on a reused
// neighbor page.
- (void)applyPagingZoomCarryToScrollView:(UIScrollView *)scrollView showTopEdge:(BOOL)showTopEdge reason:(NSString *)reason {
    [self hookScrollViewDelegateIfNeeded:scrollView];
    [self applyZoomLimitsToScrollView:scrollView];
    CGFloat zoomBefore = scrollView.zoomScale;
    CGPoint offsetBefore = scrollView.contentOffset;
    if (_pagingCarryRatio > 1.01f) {
        CGFloat target = MIN(MAX(_pagingCarryRatio * _fixScaleFactor, scrollView.minimumZoomScale), scrollView.maximumZoomScale);
        if (fabs(scrollView.zoomScale - target) > 0.001) {
            [scrollView setZoomScale:target animated:NO];
        }
        UIEdgeInsets inset = scrollView.adjustedContentInset;
        CGPoint offset = scrollView.contentOffset;
        CGFloat minX = -inset.left;
        CGFloat maxX = scrollView.contentSize.width - scrollView.bounds.size.width + inset.right;
        if (maxX > minX) offset.x = minX + _pagingCarryFracX * (maxX - minX);
        CGFloat minY = -inset.top;
        CGFloat maxY = scrollView.contentSize.height - scrollView.bounds.size.height + inset.bottom;
        if (maxY > minY) offset.y = showTopEdge ? minY : maxY;
        if (!CGPointEqualToPoint(offset, scrollView.contentOffset)) {
            [scrollView setContentOffset:offset animated:NO];
        }
    } else if (scrollView.zoomScale > scrollView.minimumZoomScale + 0.001) {
        [scrollView setZoomScale:scrollView.minimumZoomScale animated:NO];
    }
    if (fabs(scrollView.zoomScale - zoomBefore) > 0.001 || !CGPointEqualToPoint(offsetBefore, scrollView.contentOffset)) {
        PGDBG(@"paging:Zoom carry -> %@ page: zoom %.3f -> %.3f (scale %.3f), offset %@ -> %@, %@ edge",
                   reason, zoomBefore, scrollView.zoomScale, _pagingCarryRatio,
                   NSStringFromCGPoint(offsetBefore), NSStringFromCGPoint(scrollView.contentOffset),
                   showTopEdge ? @"top" : @"bottom");
    }
}

// Called on every page-turn scroller frame while a turn is in flight: give each page as it
// starts sliding into view the carried zoom, so it arrives already zoomed instead of
// popping in at fit and snapping to the zoom only once the turn has settled.
- (void)applyPagingZoomCarryToIncomingPages {
    if (!_pagingCarryValid) return;
    NSMutableArray<UIScrollView *> *candidates = [NSMutableArray array];
    [self collectPageZoomScrollViewsInView:_pdfView depth:0 into:candidates];
    UIScrollView *fromScrollView = _pagingCarryFromScrollView;
    CGRect fromFrame = fromScrollView ? [fromScrollView convertRect:fromScrollView.bounds toView:_pdfView] : CGRectZero;
    for (UIScrollView *candidate in candidates) {
        if (candidate == fromScrollView) continue;
        NSNumber *appliedToken = objc_getAssociatedObject(candidate, kRNPDFPagingCarryTokenKey);
        if (appliedToken && appliedToken.integerValue == _pagingCarryToken) continue;
        if ([self visibleFractionOfScrollView:candidate] <= 0) continue;
        CGRect frame = [candidate convertRect:candidate.bounds toView:_pdfView];
        BOOL incomingFromBelow = (fromScrollView && fromScrollView.window)
            ? CGRectGetMinY(frame) > CGRectGetMinY(fromFrame)
            : CGRectGetMinY(frame) > 0;
        objc_setAssociatedObject(candidate, kRNPDFPagingCarryTokenKey, @(_pagingCarryToken), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _pagingCarryIncomingScrollView = candidate;
        _pagingCarryIncomingFromBelow = incomingFromBelow;
        [self applyPagingZoomCarryToScrollView:candidate showTopEdge:incomingFromBelow reason:@"incoming"];
    }
}

// Runs once a finger-driven page turn has fully settled (still in the Settling state, so
// zoom changes made here are not reported to JS as user zooms).
- (void)finishPagingTransitionAfterSettle {
    // UIPageViewController creates a scroll view for every newly shown page.
    [self configureScrollView:_pdfView enabled:_scrollEnabled depth:0];

    if (_pagingCarryValid) {
        _pagingCarryValid = NO;
        UIScrollView *visible = [self visiblePageZoomScrollView];
        UIScrollView *fromScrollView = _pagingCarryFromScrollView;
        if (visible && visible != fromScrollView) {
            CGFloat expected = _pagingCarryRatio > 1.01f
                ? MIN(MAX(_pagingCarryRatio * _fixScaleFactor, visible.minimumZoomScale), visible.maximumZoomScale)
                : visible.minimumZoomScale;
            if (fabs(visible.zoomScale - expected) > 0.001) {
                // Only reached if the incoming page wasn't caught mid-turn, or PDFKit reset
                // its zoom when it became the current page. Direction preferably from what
                // was seen mid-turn, else from where the page we left now sits (above = we
                // moved forward) while it's still on screen; page numbers only as a last
                // resort - the page number is exactly what may not have been updated yet.
                BOOL movedForward;
                if (visible == _pagingCarryIncomingScrollView) {
                    movedForward = _pagingCarryIncomingFromBelow;
                } else if (fromScrollView && fromScrollView.window && visible.window) {
                    CGRect fromFrame = [fromScrollView convertRect:fromScrollView.bounds toView:_pdfView];
                    CGRect visibleFrame = [visible convertRect:visible.bounds toView:_pdfView];
                    movedForward = CGRectGetMinY(fromFrame) < CGRectGetMinY(visibleFrame);
                } else {
                    int currentPage = _pdfView.currentPage ? (int)[_pdfDocument indexForPage:_pdfView.currentPage] + 1 : _page;
                    movedForward = currentPage >= _pagingCarryFromPage;
                }
                [self applyPagingZoomCarryToScrollView:visible showTopEdge:movedForward reason:@"settled"];
            }
        }
    }

    [self reconcileCurrentPageAfterSettle];
}

// The page actually on screen right now, per PDFKit's own geometry (the page under the
// view's center, else the only visible page). -1 if it can't tell.
- (int)onScreenPageNumber {
    if (!_pdfDocument || !_pdfView) return -1;
    CGPoint mid = CGPointMake(CGRectGetMidX(_pdfView.bounds), CGRectGetMidY(_pdfView.bounds));
    PDFPage *centerPage = [_pdfView pageForPoint:mid nearest:YES];
    if (centerPage) {
        return (int)[_pdfDocument indexForPage:centerPage] + 1;
    }
    NSArray<PDFPage *> *visible = _pdfView.visiblePages;
    if (visible.count == 1) {
        return (int)[_pdfDocument indexForPage:visible.firstObject] + 1;
    }
    return -1;
}

// Paged mode: PDFKit doesn't commit a finger-driven page turn - update currentPage and
// post PDFViewPageChangedNotification - until the NEXT touch begins. Device trace
// (2026-10-02), identical on every swipe: at scrollViewDidEndDecelerating: currentPage was
// still the old page while visiblePages/pageForPoint already showed the new one, the
// page-turn teardown callback never came, and the page-changed notification only arrived
// the moment the user started the next swipe - so the page number lagged exactly one swipe
// behind, and stayed wrong for good if they stopped swiping. What's on screen is known as
// soon as the turn comes to rest, so report that instead of waiting for PDFKit.
// PDFKit's own (late) notification for the same page then lands as a harmless repeat.
- (void)reportOnScreenPageIfChanged:(NSString *)reason {
    if (!_pdfDocument || !_currentUsePageViewController) return;
    if (_isNavigating || _page != _previousPage) {
        // A JS-requested navigation is pending/in flight - it decides the page, not us.
        PGDBG(@"on-screen page check (%@) skipped - JS navigation pending %@", reason, [self pgdbgSnapshot]);
        return;
    }
    int onScreenPage = [self onScreenPageNumber];
    if (onScreenPage < 1 || onScreenPage == _page) {
        PGDBG(@"on-screen page check (%@): page %d already reported %@", reason, onScreenPage, [self pgdbgSnapshot]);
        return;
    }
    PGDBG(@"on-screen page check (%@): showing page %d but last reported %d - reporting now %@",
          reason, onScreenPage, _page, [self pgdbgSnapshot]);
    _page = onScreenPage;
    _previousPage = onScreenPage;
    _displayPage = onScreenPage;
    _pageCount = (int)_pdfDocument.pageCount;
    if (_enablePreloading) {
        [self preloadAdjacentPages:_page];
    }
    [self notifyOnChangeWithMessage:[NSString stringWithFormat:@"pageChanged|%d|%lu",
                                     onScreenPage, (unsigned long)_pdfDocument.pageCount]];
    if (_highlightOverlay) [_highlightOverlay setNeedsDisplay];
}

// Settle-time safety net for the same thing (e.g. a turn that ended via an animation
// rather than deceleration, where scrollViewDidEndDecelerating: never fired).
- (void)reconcileCurrentPageAfterSettle {
    [self reportOnScreenPageIfChanged:@"settle"];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Redraw highlight overlay so rects stay aligned when user scrolls (pan).
    if (_highlightOverlay) {
        [self refreshHighlightOverlayContainer];
    }
    if (_pagingCarryValid && _currentUsePageViewController &&
        _pageTransitionState != RNPDFPageTransitionIdle && [self isPageTurnScrollView:scrollView]) {
        [self applyPagingZoomCarryToIncomingPages];
    }
    static int scrollEventCount = 0;
    scrollEventCount++;

    // Log scroll events periodically (every 10th event to avoid spam)
    if (scrollEventCount % 10 == 0) {
        RCTLogInfo(@"📜 [iOS Scroll] scrollViewDidScroll #%d - offset=(%.2f, %.2f), contentSize=(%.2f, %.2f), bounds=(%.2f, %.2f), scrollEnabled=%d", 
                  scrollEventCount,
                  scrollView.contentOffset.x,
                  scrollView.contentOffset.y,
                  scrollView.contentSize.width,
                  scrollView.contentSize.height,
                  scrollView.bounds.size.width,
                  scrollView.bounds.size.height,
                  scrollView.scrollEnabled);
    }

    if (!_pdfDocument || _singlePage) {
        if (scrollEventCount % 10 == 0) {
            RCTLogInfo(@"⏭️ [iOS Scroll] Skipping scroll handling - pdfDocument=%d, singlePage=%d",
                      _pdfDocument != nil, _singlePage);
        }
        return;
    }

    // Page-change detection used to be duplicated here: this delegate guessed the
    // "current" page from whichever page sat at the exact center of the viewport
    // (contentOffset + bounds/2 -> convertPoint: -> pageForPoint:nearest:), racing
    // PDFKit's own PDFViewPageChangedNotification (see onPageChanged: below), which
    // already reports the same thing authoritatively. Right as a scroll settled
    // (scrollViewDidEndDecelerating), this heuristic would occasionally compute a
    // wildly wrong page for a single frame (e.g. 5->9, 13->32) before self-correcting
    // a millisecond later — device logs from a 2026-09-13 investigation caught both
    // the bogus reading and its correction back to back. Each bogus reading still got
    // sent to JS as a real onPageChanged event; by the time React reflected that page
    // back down as a prop, this view's own state had already self-corrected, so the
    // updateProps loop-guard (_page != _previousPage) no longer matched and a real
    // goToDestination: fired to the wrong page and then back — the actual cause of
    // "drag jumps through many pages" reported for continuous-scroll mode. Removed;
    // PDFViewPageChangedNotification is the sole source for the _page/navigation
    // state now.
    //
    // updateDisplayPageForScrollIfNeeded below is a *different* signal added later
    // (2026-10-01): PDFKit's own currentPage lags noticeably in continuous mode —
    // e.g. dragging fast from the last page back up to page 1 can leave
    // _pdfView.currentPage (and the pageChanged notification above) stuck on the old
    // page long after page 1 is what's actually on screen, so the JS page-indicator
    // chip shows a stale number. It is display-only: it feeds a separate
    // "displayPageChanged" message that JS never writes back into the `page` prop,
    // so it cannot re-trigger the navigation feedback loop described above even if a
    // single frame's reading is briefly wrong.
    [self updateDisplayPageForScrollIfNeeded];
}

// Finds whichever visible page covers at least half the viewport's height and, if
// that's a different page than last reported, sends a display-only
// "displayPageChanged" message. Intentionally never touches _page/_previousPage —
// see the comment in scrollViewDidScroll: above.
//
// Must gate on _enablePaging, NOT _singlePage: _singlePage is an unrelated prop
// (pdf-reader never sets it, so it's always NO) left over from this function's
// scrollViewDidScroll:-level guard above, which only ever mattered when that
// function's body was empty. Gating on it here let this run during a paged-mode
// page-turn animation too — UIPageViewController's turn is itself a scroll, so
// every frame of the transition briefly has two pages each covering ~50%,
// flipping back and forth and firing a flood of displayPageChanged events. JS
// setState-ing on every one of those triggered React's "Maximum update depth
// exceeded" the first time paged mode was exercised after this was added
// (2026-10-01). shouldUsePageViewController (see didSetProps) is the actual
// paged/continuous source of truth elsewhere in this file; mirror it here.
- (void)updateDisplayPageForScrollIfNeeded {
    BOOL usingPageViewController = _enablePaging && !_horizontal;
    if (!_pdfDocument || usingPageViewController) {
        return;
    }
    // While the single-page-view toggle is rebuilding PDFKit's view, PDFKit transiently
    // sits on page 1 before reconfigureUsePageViewControllerIfNeededWithRetriesLeft:
    // steers it back - reporting that flashed "1/N" in the page indicator for a frame
    // (device trace 2026-10-02: displayPageChanged 1 then 6 within 60ms of a toggle).
    // The first scroll after the rebuild reports the real page.
    if (_isReconfiguringPageViewController) {
        return;
    }
    NSArray<PDFPage *> *visiblePages = _pdfView.visiblePages;
    if (visiblePages.count == 0) {
        return;
    }
    CGRect viewportBounds = _pdfView.bounds;
    if (viewportBounds.size.height <= 0) {
        return;
    }

    PDFPage *bestPage = nil;
    CGFloat bestFraction = 0;
    for (PDFPage *candidatePage in visiblePages) {
        CGRect pageBoundsInView = [_pdfView convertRect:[candidatePage boundsForBox:kPDFDisplayBoxCropBox]
                                                fromPage:candidatePage];
        if (pageBoundsInView.size.height <= 0) {
            continue;
        }
        CGRect visibleIntersection = CGRectIntersection(pageBoundsInView, viewportBounds);
        if (CGRectIsNull(visibleIntersection)) {
            continue;
        }
        CGFloat fraction = visibleIntersection.size.height / pageBoundsInView.size.height;
        if (fraction > bestFraction) {
            bestFraction = fraction;
            bestPage = candidatePage;
        }
    }
    // Require a clear majority (>=50%) before switching — a page straddling the
    // viewport boundary with ~40/60 split against its neighbor should keep
    // reporting whichever page last won, not flicker between the two.
    if (!bestPage || bestFraction < 0.5) {
        return;
    }

    unsigned long pageIndex = [_pdfDocument indexForPage:bestPage];
    int newDisplayPage = (int)pageIndex + 1;
    if (newDisplayPage != _displayPage) {
        _displayPage = newDisplayPage;
        [self notifyOnChangeWithMessage:[[NSString alloc] initWithString:
            [NSString stringWithFormat:@"displayPageChanged|%d|%lu", _displayPage, (unsigned long)_pdfDocument.pageCount]]];
    }
}

// Marks the gesture Settling (not yet Idle) and, after one extra run-loop
// turn, flips it to Idle — but only if no newer gesture started meanwhile.
// The dispatch_async (not a fixed delay) is the actual fix: it guarantees
// UIKit's own synchronous transition-cleanup call stack (the one that invoked
// the scrollViewDidEndDragging:/scrollViewDidEndDecelerating: we're called
// from) has fully returned before anything treats the view as Idle again.
//
// Paged mode (UIPageViewController, see shouldUsePageViewController) needs
// more than that: real device crash (2026-10-01, swiping again right after
// reaching the last page) — "Assertion failure in UIPageViewController.m...
// No view controller managing visible view" -> NSInternalInconsistencyException
// -> abort(). _pageTransitionState alone only protects OUR OWN programmatic
// navigateToPageForPagingMode: calls from racing UIKit (see its own guard
// above); it was never able to stop the user from starting a second real
// finger-driven page-turn before UIPageViewController's own internal
// _UIQueuingScrollView has finished cleaning up the first transition —
// especially right at a document boundary (no next/previous view
// controller), which is UIPageViewController's own known trigger for this
// exact assertion. Disabling _pdfView's user interaction for the duration
// physically blocks a new page-turn pan gesture from ever starting during
// that window (our own tap/doubletap recognizers are on `self`, not
// `_pdfView` — see bindTap — so they're unaffected), closing the race by
// construction instead of trying to out-guess UIKit's timing.
//
// What "the duration" is: this used to be a fixed 350ms guess (comfortably
// past UIPageViewController's own ~0.3s transition animation). It's now
// driven by the real signal instead — onPageTransitionTeardownComplete:,
// fired off the exact UIKit method whose teardown this race is against (see
// UIPageViewController+RNPDFCrashGuard.mm, which swizzles that same private
// method to also swallow the assertion directly). A guessed duration was the
// only option before that swizzle existed; now that we're already hooked
// into the real completion callback, releasing off it is both more correct
// and, in practice, faster than the old blind wait.
//
// 2026-10-02: the "teardown notification missing on ordinary swipes" noted below
// was not UIKit being unreliable - UIPageViewController had been cut off from its
// own page-turn scroller (see RNPDFScrollViewDelegateProxy), so that callback
// genuinely never ran. With the delegate chain intact it fires on every manual
// page turn; it can also land just *before* scrollViewDidEnd{Dragging,
// Decelerating}: reaches us, which _pagingTeardownSeenGeneration covers.
- (void)beginSettlingAfterUserGestureEnd {
    BOOL usingPageViewController = _enablePaging && !_horizontal;
    BOOL teardownAlreadyDone = usingPageViewController &&
                               _pageTransitionState == RNPDFPageTransitionUserDriven &&
                               _pagingTeardownSeenGeneration == _pageTransitionGeneration;
    _pageTransitionState = RNPDFPageTransitionSettling;
    NSInteger generation = ++_pageTransitionGeneration;
    if (usingPageViewController) {
        _pdfView.userInteractionEnabled = NO;
    }
    __weak __typeof(self) weakSelf = self;
    void (^settle)(void) = ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_pageTransitionGeneration != generation) {
            // A new drag started while we were waiting - that gesture owns the
            // state now, leave it alone.
            PGDBG(@"settle SKIPPED (gen=%ld superseded by gen=%ld)", (long)generation, (long)strongSelf->_pageTransitionGeneration);
            return;
        }
        BOOL pagedNow = strongSelf->_currentUsePageViewController;
        PGDBG(@"settle FIRE (gen=%ld) %@", (long)generation, [strongSelf pgdbgSnapshot]);
        if (pagedNow) {
            // Before going Idle: zoom changes made here must not be reported to JS
            // as user zooms (see scrollViewDidZoom:).
            [strongSelf finishPagingTransitionAfterSettle];
        }
        strongSelf->_pageTransitionState = RNPDFPageTransitionIdle;
        strongSelf->_pdfView.userInteractionEnabled = YES;
        if (pagedNow) {
            [strongSelf syncScaleFromVisiblePageScrollView];
            if (strongSelf->_highlightOverlay) {
                [strongSelf refreshHighlightOverlayContainer];
            }
        }
        RCTLogInfo(@"👆 [iOS Scroll] page transition settled -> Idle (usingPageViewController=%d, page=%d)",
                   usingPageViewController, strongSelf->_page);
    };
    PGDBG(@"beginSettling (gen=%ld paged=%d teardownAlreadyDone=%d)", (long)generation, usingPageViewController, teardownAlreadyDone);
    if (usingPageViewController && teardownAlreadyDone) {
        RCTLogInfo(@"👆 [iOS Scroll] Page-turn teardown already completed for this gesture - settling next run-loop turn");
        dispatch_async(dispatch_get_main_queue(), settle);
    } else if (usingPageViewController) {
        _pagingSettleBlock = settle;
        // This was meant to be a rare safety net, not the primary path - but
        // device logs from 2026-10-02 showed queuingScrollView:didEndManualScroll:...
        // (see UIPageViewController+RNPDFCrashGuard.mm) missing on *ordinary* swipes,
        // not just the boundary-race edge case, which made this fallback the common
        // path instead of the exception. At 1.5s that meant every normal page-turn
        // held _pdfView.userInteractionEnabled = NO for a user-perceptible freeze,
        // and a second swipe landing right as it unlocked would queue up and fire
        // as an extra page-turn once released - the reported "swipe once, jump two
        // pages" / "keeps letting me swipe" symptom. Shortened to comfortably outlast
        // UIPageViewController's own ~0.3s transition animation (this is close to the
        // 350ms fixed delay this notification-based settle originally replaced) so the
        // common case no longer freezes interaction for a visible stretch, while still
        // acting as a backstop for a genuinely missed notification.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_pagingSettleBlock != settle) {
                return;
            }
            // Normal in paged mode: PDFKit/UIPageViewController only commits a turn when
            // the next touch begins (see reportOnScreenPageIfChanged:), so this is the
            // usual path - trace it, don't warn.
            PGDBG(@"Teardown-complete notification didn't arrive within 0.4s - releasing paging settle via fallback timeout");
            strongSelf->_pagingSettleBlock = nil;
            settle();
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), settle);
    }
}

// Fired by RNPDFPageTransitionTeardownDidCompleteNotification (posted from
// UIPageViewController+RNPDFCrashGuard.mm's swizzle, on every manual-scroll
// teardown of ANY UIPageViewController in the process — see that file's
// comment on why this is posted with no `object`). No-ops unless this view's
// own paging settle is actually pending, so a notification from an unrelated
// UIPageViewController elsewhere in the app is harmless.
- (void)onPageTransitionTeardownComplete:(NSNotification *)notification {
    PGDBG(@"page-turn teardown notification (settlePending=%d fingerLiftedGen=%ld) %@",
          _pagingSettleBlock != nil, (long)_pageTurnFingerLiftedGeneration, [self pgdbgSnapshot]);
    if (!_pagingSettleBlock) {
        if (_pageTransitionState == RNPDFPageTransitionUserDriven &&
            _pageTurnFingerLiftedGeneration == _pageTransitionGeneration) {
            // Arrived after this gesture's finger lifted but before
            // scrollViewDidEndDecelerating: reached us - remember it so
            // beginSettlingAfterUserGestureEnd doesn't wait out the fallback timer for
            // a notification that has already come and gone. (Not while the finger is
            // still down: that could be a late one from the previous swipe.)
            _pagingTeardownSeenGeneration = _pageTransitionGeneration;
        }
        return;
    }
    void (^settle)(void) = _pagingSettleBlock;
    _pagingSettleBlock = nil;
    // Same one-extra-run-loop-turn margin as the non-paging path above -
    // we're called synchronously from inside the swizzle's @try block, i.e.
    // still on UIKit's own teardown call stack, so defer the actual flip
    // until it's fully unwound.
    dispatch_async(dispatch_get_main_queue(), settle);
}

// Which scroll view's drags are page turns. Paged mode: only UIPageViewController's
// page-turn scroller - panning around inside a zoomed page is not a page turn, and used to
// be treated as one (locking interaction and swallowing taps after every pan) because
// every scroll view reported into the same handlers. Continuous mode: PDFKit's single
// scroll view.
- (BOOL)scrollViewDrivesPageTransitionState:(UIScrollView *)scrollView {
    if ([self isPageTurnScrollView:scrollView]) {
        return YES;
    }
    return !_currentUsePageViewController;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    PGDBG(@"scroll willBeginDragging (%@, offset=%@) %@",
          [self pgdbgScrollViewKind:scrollView], NSStringFromCGPoint(scrollView.contentOffset), [self pgdbgSnapshot]);
    if (![self scrollViewDrivesPageTransitionState:scrollView]) {
        return;
    }
    _pageTransitionState = RNPDFPageTransitionUserDriven;
    ++_pageTransitionGeneration;
    if (_currentUsePageViewController) {
        [self capturePagingZoomCarry];
    }
    RCTLogInfo(@"👆 [iOS Scroll] scrollViewWillBeginDragging - enablePaging=%d, page=%d, pageCount=%lu",
              _enablePaging, _page, (unsigned long)_pdfDocument.pageCount);
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    PGDBG(@"scroll didEndDragging decelerate=%d (%@, offset=%@) %@", decelerate,
          [self pgdbgScrollViewKind:scrollView], NSStringFromCGPoint(scrollView.contentOffset), [self pgdbgSnapshot]);
    if (![self scrollViewDrivesPageTransitionState:scrollView]) {
        return;
    }
    _pageTurnFingerLiftedGeneration = _pageTransitionGeneration;
    if (!decelerate) {
        RCTLogInfo(@"👆 [iOS Scroll] scrollViewDidEndDragging (no decelerate) - Settling");
        [self beginSettlingAfterUserGestureEnd];
        return;
    }
    // decelerate==YES is the common case for a page-turn (or the boundary
    // bounce-back when there's no next/previous page) — finger has lifted, but
    // UIKit's own transition/settle animation is about to play and
    // scrollViewDidEndDecelerating: won't fire until it's *done*. Leaving
    // userInteractionEnabled untouched until then was the actual gap behind the
    // 2026-10-01 crash dupe (see beginSettlingAfterUserGestureEnd's comment): a
    // second finger-driven swipe starting mid-animation is exactly what races
    // UIPageViewController's internal cleanup and asserts. Disable interaction
    // for the animation itself, not just the post-animation tail — this doesn't
    // interrupt the already-running animation (userInteractionEnabled only gates
    // new touch hit-testing, never in-flight animations); scrollViewDidEndDecelerating:
    // below re-asserts it (harmless) and owns scheduling the actual re-enable.
    BOOL usingPageViewController = _enablePaging && !_horizontal;
    if (usingPageViewController) {
        _pdfView.userInteractionEnabled = NO;
        RCTLogInfo(@"👆 [iOS Scroll] scrollViewDidEndDragging (will decelerate, paging) - blocking interaction through settle animation");
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    PGDBG(@"scroll didEndDecelerating (%@, offset=%@) %@",
          [self pgdbgScrollViewKind:scrollView], NSStringFromCGPoint(scrollView.contentOffset), [self pgdbgSnapshot]);
    if (![self scrollViewDrivesPageTransitionState:scrollView]) {
        return;
    }
    if (_currentUsePageViewController) {
        // The page turn has come to rest - report the page now on screen right away
        // (see reportOnScreenPageIfChanged: for why PDFKit's own report comes too late).
        [self reportOnScreenPageIfChanged:@"page turn came to rest"];
    }
    RCTLogInfo(@"👆 [iOS Scroll] scrollViewDidEndDecelerating - Settling");
    [self beginSettlingAfterUserGestureEnd];
}

#pragma mark - UIScrollViewDelegate Zoom Support

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    // The overlay is parented under the same PDFKit content view that UIScrollView zooms,
    // so zoom/pan tracking comes from UIKit instead of a separate hand-built transform.
    if (_highlightOverlay) {
        [self refreshHighlightOverlayContainer];
    }
    if (_fixScaleFactor <= 0) {
        return;
    }
    float newScale;
    if (_currentUsePageViewController) {
        // Paged mode: only a zoom of the page actually on screen is the user's zoom.
        // Neighbor pages' scrollers (kept loaded off screen), zoom carried onto an
        // incoming page mid-turn, and the page-turn scroller itself must not be
        // reported - each of those used to round-trip through JS's `scale` prop and
        // snap the visible page's zoom to the wrong value.
        if (_pageTransitionState != RNPDFPageTransitionIdle ||
            [self isPageTurnScrollView:scrollView] ||
            [self visibleFractionOfScrollView:scrollView] < 0.5f) {
            return;
        }
        newScale = scrollView.zoomScale / _fixScaleFactor;
    } else {
        if (_pdfView.scaleFactor <= 0) {
            return;
        }
        newScale = _pdfView.scaleFactor / _fixScaleFactor;
    }

    // Only notify if scale changed significantly (prevent spam)
    if (fabs(_scale - newScale) > 0.01f) {
        _scale = newScale;
        PGDBG(@"zoom: Pinch zoom - scale changed to %f", _scale);
        [self reportScaleToJS];
    }
}

// CRITICAL: Return the view that should be zoomed. Only reached for a scroll view whose
// own (PDFKit) delegate doesn't answer this - see RNPDFScrollViewDelegateProxy.
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    if ([self isPageTurnScrollView:scrollView]) {
        // UIPageViewController's page-turn scroller never zooms.
        return nil;
    }
    // Search for PDFDocumentView in the scroll view's hierarchy
    for (UIView *subview in scrollView.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className containsString:@"PDFDocumentView"] || [className containsString:@"PDFPage"]) {
            RCTLogInfo(@"🔍 [iOS Zoom] viewForZoomingInScrollView returning: %@", className);
            return subview;
        }
    }
    
    // Fallback to first subview
    UIView *fallback = scrollView.subviews.firstObject;
    if (fallback) {
        RCTLogInfo(@"🔍 [iOS Zoom] viewForZoomingInScrollView using fallback: %@", NSStringFromClass([fallback class]));
        return fallback;
    }
    
    RCTLogInfo(@"⚠️ [iOS Zoom] viewForZoomingInScrollView returning NIL - no view to zoom!");
    return nil;
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    _isLiveZooming = YES;
    if (_highlightOverlay) {
        [self refreshHighlightOverlayContainer];
    }
    PGDBG(@"zoom: Will begin zooming (%@, zoomView=%@, pageTurn=%d, visible=%.2f)",
               NSStringFromClass([scrollView class]), view ? NSStringFromClass([view class]) : @"(nil)",
               [self isPageTurnScrollView:scrollView], [self visibleFractionOfScrollView:scrollView]);
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView
                        withView:(UIView *)view
                         atScale:(CGFloat)scale {
    _isLiveZooming = NO;
    // The gesture just ended; resync the cached scale from the view's real, final zoom
    // and make sure JS ends up holding that same value. Updating _scale silently (as this
    // used to) left JS on the last mid-pinch report, so the next unrelated prop update
    // carried that slightly-off value back down as a "change" and nudged the zoom.
    BOOL resynced = NO;
    if (_currentUsePageViewController) {
        if (_fixScaleFactor > 0 && ![self isPageTurnScrollView:scrollView] &&
            [self visibleFractionOfScrollView:scrollView] >= 0.5f) {
            _scale = scrollView.zoomScale / _fixScaleFactor;
            resynced = YES;
        }
    } else if (_fixScaleFactor > 0 && _pdfView.scaleFactor > 0) {
        _scale = _pdfView.scaleFactor / _fixScaleFactor;
        resynced = YES;
    }
    if (resynced && fabs(_scale - _jsKnownScale) > 0.0001f) {
        [self reportScaleToJS];
    }
    if (_highlightOverlay) {
        [self refreshHighlightOverlayContainer];
    }
    PGDBG(@"zoom: Did end zooming at zoomScale %f (_scale=%f, JS knows %f)", scale, _scale, _jsKnownScale);
}

// Enhanced progressive loading methods
- (void)preloadAdjacentPages:(int)currentPage
{
    if (!_enablePreloading || !_pdfDocument) {
        return;
    }
    
    int startPage = MAX(1, currentPage - _preloadRadius);
    int endPage = MIN((int)_pdfDocument.pageCount, currentPage + _preloadRadius);
    
    for (int page = startPage; page <= endPage; page++) {
        if (![_preloadedPages containsObject:@(page)]) {
            [_preloadedPages addObject:@(page)];
            
            // Add preload operation to queue
            NSBlockOperation *preloadOp = [NSBlockOperation blockOperationWithBlock:^{
                // Preload page content (this is a simplified version)
                // In a real implementation, you might preload page thumbnails or other content
                RLog(@"Enhanced PDF: Preloading page %d", page);
            }];
            
            [_preloadQueue addOperation:preloadOp];
        }
    }
}

- (NSDictionary *)getPerformanceMetrics
{
    NSMutableDictionary *metrics = [_performanceMetrics mutableCopy];
    metrics[@"cacheHitCount"] = @([_pageCache count]);
    metrics[@"preloadedPages"] = @([_preloadedPages count]);
    metrics[@"cacheSize"] = @(_cacheSize);
    return metrics;
}

- (void)clearCache
{
    [_pageCache removeAllObjects];
    [_preloadedPages removeAllObjects];
    [_searchCache removeAllObjects];
    RLog(@"Enhanced PDF: Cache cleared");
}

- (void)preloadPagesFrom:(int)startPage to:(int)endPage
{
    if (!_enablePreloading || !_pdfDocument) {
        return;
    }
    
    int actualStartPage = MAX(1, startPage);
    int actualEndPage = MIN((int)_pdfDocument.pageCount, endPage);
    
    for (int page = actualStartPage; page <= actualEndPage; page++) {
        if (![_preloadedPages containsObject:@(page)]) {
            [_preloadedPages addObject:@(page)];
            RLog(@"Enhanced PDF: Preloading page %d", page);
        }
    }
}

- (NSDictionary *)searchText:(NSString *)searchTerm
{
    if (!searchTerm || searchTerm.length == 0 || !_pdfDocument) {
        return @{@"totalMatches": @0, @"results": @[]};
    }
    
    // Check cache first
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@", _currentPdfId, searchTerm];
    if (_searchCache[cacheKey]) {
        RLog(@"Enhanced PDF: Search cache hit for '%@'", searchTerm);
        return _searchCache[cacheKey];
    }
    
    NSMutableArray *results = [NSMutableArray array];
    int totalMatches = 0;
    
    for (int pageIndex = 0; pageIndex < _pdfDocument.pageCount; pageIndex++) {
        PDFPage *page = [_pdfDocument pageAtIndex:pageIndex];
        
        // Search for text in the page
        PDFSelection *selection = [page selectionForRange:NSMakeRange(0, page.string.length)];
        if (selection && selection.string.length > 0) {
            NSString *text = selection.string;
            if ([text localizedCaseInsensitiveContainsString:searchTerm]) {
                // Get the bounds of the selection
                CGRect selectionBounds = [selection boundsForPage:page];
                
                [results addObject:@{
                    @"page": @(pageIndex + 1),
                    @"text": text,
                    @"rect": NSStringFromCGRect(selectionBounds)
                }];
                totalMatches++;
            }
        }
    }
    
    NSDictionary *searchResults = @{
        @"totalMatches": @(totalMatches),
        @"results": results
    };
    
    // Cache the results
    _searchCache[cacheKey] = searchResults;
    
    RLog(@"Enhanced PDF: Search completed for '%@', found %d matches", searchTerm, totalMatches);
    return searchResults;
}

@end

#ifdef RCT_NEW_ARCH_ENABLED

#ifdef __cplusplus
extern "C" {
#endif

Class<RCTComponentViewProtocol> RNPDFPdfViewCls(void)
{
    // Defensive check: Ensure class is loaded and valid before returning
    // This prevents nil object insertion in RCTThirdPartyComponentsProvider
    Class cls = RNPDFPdfView.class;
    if (cls == nil) {
        RCTLogError(@"RNPDFPdfView: Class is nil in RNPDFPdfViewCls");
        // Return a fallback to prevent crash, though this shouldn't happen
        return [RCTViewComponentView class];
    }
    return cls;
}

// Alias function based on codegen name "rnpdf" - ensures codegen can find the function
// even if it uses the codegen name instead of componentProvider name
Class<RCTComponentViewProtocol> rnpdfCls(void)
{
    return RNPDFPdfViewCls();
}

#ifdef __cplusplus
}
#endif

#endif
