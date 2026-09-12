/**
 * Registry mapping pdfId to current PDF file path for programmatic search.
 * RNPDFPdfView registers when a document loads with pdfId; searchTextDirect looks up path by pdfId.
 * Also stores PDF page sizes in points (per pdfId + pageIndex) for highlight coordinate scaling.
 */
#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SearchRegistry : NSObject

+ (void)registerPath:(NSString *)pdfId path:(NSString *)path;
+ (void)unregisterPath:(NSString *)pdfId;
+ (nullable NSString *)pathForPdfId:(NSString *)pdfId;

+ (void)registerPageSizePointsForPdfId:(NSString *)pdfId pageIndex0Based:(NSInteger)pageIndex widthPt:(CGFloat)widthPt heightPt:(CGFloat)heightPt;
+ (void)getPageSizePointsForPdfId:(NSString *)pdfId pageIndex0Based:(NSInteger)pageIndex widthOut:(CGFloat *)widthOut heightOut:(CGFloat *)heightOut;

/**
 * Returns the PDFDocument already opened for `pdfId` at `path`, opening and caching it on
 * first use. Repeat calls (e.g. one per sentence during highlight-rect precompute) reuse the
 * same parsed document instead of re-reading/re-parsing the file from disk every time — this is
 * the dominant cost `searchTextDirect` used to pay on every single call. The cache is dropped by
 * `unregisterPath:` or automatically replaced if `path` changes for the same `pdfId`.
 */
+ (nullable PDFDocument *)documentForPdfId:(NSString *)pdfId path:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
