/**
 * Registry mapping pdfId to current PDF file path for programmatic search.
 */
#import "SearchRegistry.h"

@implementation SearchRegistry

static NSMutableDictionary<NSString *, NSString *> *_pathByPdfId;
static NSMutableDictionary<NSString *, NSValue *> *_pageSizeByKey; // key = "pdfId_pageIndex", value = NSValue with CGSize
static NSMutableDictionary<NSString *, PDFDocument *> *_documentByPdfId;
static NSMutableDictionary<NSString *, NSString *> *_documentPathByPdfId; // path the cached document was opened with
static dispatch_queue_t _queue;

+ (void)initialize {
    if (self == [SearchRegistry class]) {
        _pathByPdfId = [NSMutableDictionary new];
        _pageSizeByKey = [NSMutableDictionary new];
        _documentByPdfId = [NSMutableDictionary new];
        _documentPathByPdfId = [NSMutableDictionary new];
        _queue = dispatch_queue_create("com.rnpdf.searchregistry", DISPATCH_QUEUE_SERIAL);
    }
}

+ (void)registerPath:(NSString *)pdfId path:(NSString *)path {
    if (!pdfId.length || !path.length) return;
    dispatch_sync(_queue, ^{
        _pathByPdfId[pdfId] = path;
    });
}

+ (void)unregisterPath:(NSString *)pdfId {
    if (!pdfId.length) return;
    dispatch_sync(_queue, ^{
        [_pathByPdfId removeObjectForKey:pdfId];
        [_documentByPdfId removeObjectForKey:pdfId];
        [_documentPathByPdfId removeObjectForKey:pdfId];
        NSString *prefix = [pdfId stringByAppendingString:@"_"];
        NSArray *keysToRemove = [_pageSizeByKey.allKeys filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSString *key, id _) { return [key hasPrefix:prefix]; }]];
        [_pageSizeByKey removeObjectsForKeys:keysToRemove];
    });
}

+ (nullable PDFDocument *)documentForPdfId:(NSString *)pdfId path:(NSString *)path {
    if (!pdfId.length || !path.length) return nil;
    __block PDFDocument *doc = nil;
    dispatch_sync(_queue, ^{
        PDFDocument *cached = _documentByPdfId[pdfId];
        NSString *cachedPath = _documentPathByPdfId[pdfId];
        if (cached && [cachedPath isEqualToString:path]) {
            doc = cached;
            return;
        }
        PDFDocument *fresh = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
        if (fresh) {
            _documentByPdfId[pdfId] = fresh;
            _documentPathByPdfId[pdfId] = path;
        }
        doc = fresh;
    });
    return doc;
}

+ (NSString *)pathForPdfId:(NSString *)pdfId {
    if (!pdfId.length) return nil;
    __block NSString *path = nil;
    dispatch_sync(_queue, ^{
        path = _pathByPdfId[pdfId];
    });
    return path;
}

+ (void)registerPageSizePointsForPdfId:(NSString *)pdfId pageIndex0Based:(NSInteger)pageIndex widthPt:(CGFloat)widthPt heightPt:(CGFloat)heightPt {
    if (!pdfId.length || widthPt <= 0 || heightPt <= 0) return;
    NSString *key = [NSString stringWithFormat:@"%@_%ld", pdfId, (long)pageIndex];
    dispatch_sync(_queue, ^{
        _pageSizeByKey[key] = [NSValue valueWithCGSize:CGSizeMake(widthPt, heightPt)];
    });
}

+ (void)getPageSizePointsForPdfId:(NSString *)pdfId pageIndex0Based:(NSInteger)pageIndex widthOut:(CGFloat *)widthOut heightOut:(CGFloat *)heightOut {
    if (!pdfId.length || !widthOut || !heightOut) return;
    *widthOut = 0;
    *heightOut = 0;
    NSString *key = [NSString stringWithFormat:@"%@_%ld", pdfId, (long)pageIndex];
    __block NSValue *val = nil;
    dispatch_sync(_queue, ^{
        val = _pageSizeByKey[key];
    });
    if (val) {
        CGSize s = [val CGSizeValue];
        *widthOut = s.width;
        *heightOut = s.height;
    }
}

@end
