/**
 * Copyright (c) 2017-present, Wonday (@wonday.org)
 * All rights reserved.
 *
 * This source code is licensed under the MIT-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#ifndef RNPDFPdfView_h
#define RNPDFPdfView_h

#if __has_include(<React/RCTAssert.h>)
#import <React/RCTEventDispatcher.h>
#import <React/UIView+React.h>
#else
#import "RCTEventDispatcher.h"
#import "UIView+React.h"
#endif

#ifdef RCT_NEW_ARCH_ENABLED
#import <React/RCTViewComponentView.h>
#import <React/RCTComponentViewProtocol.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declaration for codegen - ensures RNPDFPdfViewCls() is visible to RCTThirdPartyComponentsProvider
// Using extern "C" for proper C linkage, matching React Native's pattern
Class<RCTComponentViewProtocol> RNPDFPdfViewCls(void);

// Alias function based on codegen name "rnpdf" - ensures codegen can find the function
// even if it uses the codegen name instead of componentProvider name
Class<RCTComponentViewProtocol> rnpdfCls(void);

#ifdef __cplusplus
}
#endif

#endif

@class RCTEventDispatcher;

NS_CLASS_AVAILABLE_IOS(11_0) @interface RNPDFPdfView :
#ifdef RCT_NEW_ARCH_ENABLED
RCTViewComponentView
#else
UIView
#endif
<UIGestureRecognizerDelegate, UIScrollViewDelegate>
- (instancetype)initWithBridge:(RCTBridge *)bridge;

@property(nonatomic, strong) NSString *path;
@property(nonatomic) int page;
@property(nonatomic) float scale;
@property(nonatomic) float minScale;
@property(nonatomic) float maxScale;
@property(nonatomic) BOOL horizontal;
@property(nonatomic) BOOL showsVerticalScrollIndicator;
@property(nonatomic) BOOL showsHorizontalScrollIndicator;
@property(nonatomic) BOOL scrollEnabled;
@property(nonatomic) BOOL enablePaging;
@property(nonatomic) BOOL enableMomentum;
@property(nonatomic) BOOL enableRTL;
@property(nonatomic) BOOL enableAnnotationRendering;
@property(nonatomic) BOOL enableDoubleTapZoom;
/** Inverts the rendered page content (PDFKit has no night mode of its own) — see RNPDFNightPage in the .mm. */
@property(nonatomic) BOOL nightMode;
@property(nonatomic) int fitPolicy;
@property(nonatomic) int spacing;
@property(nonatomic, strong) NSString *password;
@property(nonatomic) BOOL singlePage;
@property(nonatomic, strong) NSString *pdfId;
@property(nonatomic, copy) NSArray *highlightRects;

@property(nonatomic, copy) RCTBubblingEventBlock onChange;

// Enhanced progressive loading method declarations
- (NSDictionary *)getPerformanceMetrics;
- (void)clearCache;
- (void)preloadPagesFrom:(int)startPage to:(int)endPage;
- (NSDictionary *)searchText:(NSString *)searchTerm;

@end

#endif /* RNPDFPdfView_h */
