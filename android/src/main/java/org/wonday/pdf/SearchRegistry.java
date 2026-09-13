/**
 * Registry mapping pdfId to current PDF file path for programmatic search.
 * PdfView registers when a document loads with pdfId; searchTextDirect looks up path by pdfId.
 * Also stores PDF page sizes in points (per pdfId + pageIndex) for highlight coordinate scaling.
 */
package org.wonday.pdf;

import android.content.Context;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.IOException;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.ReentrantReadWriteLock;

import io.legere.pdfiumandroid.PdfDocument;
import io.legere.pdfiumandroid.PdfiumCore;

public final class SearchRegistry {
    private static final ConcurrentHashMap<String, String> pdfIdToPath = new ConcurrentHashMap<>();
    /** Key: pdfId + "_" + pageIndex0Based, value: float[2] = { widthPt, heightPt } */
    private static final ConcurrentHashMap<String, float[]> pdfIdPageSizePoints = new ConcurrentHashMap<>();
    /** pdfId + "_" + pageIndex0Based keys with a measurement already in flight, so a page being
     *  drawn repeatedly (scroll/zoom re-triggers onLayerDrawn many times a second) doesn't queue
     *  up redundant background opens for the same page before the first one finishes. */
    private static final Set<String> pageSizeMeasurementPending = ConcurrentHashMap.newKeySet();
    private static final ExecutorService pageSizeExecutor = Executors.newSingleThreadExecutor();

    /** One already-opened Pdfium document per pdfId, reused across searches instead of
     *  re-opening + re-parsing the file from disk on every single search call. */
    private static final class DocHolder {
        final ParcelFileDescriptor pfd;
        final PdfDocument doc;
        final String path;
        DocHolder(ParcelFileDescriptor pfd, PdfDocument doc, String path) {
            this.pfd = pfd;
            this.doc = doc;
            this.path = path;
        }
    }
    private static final ConcurrentHashMap<String, DocHolder> docByPdfId = new ConcurrentHashMap<>();

    /**
     * Per-pdfId lock guarding "close" against "in-flight page/text access" on the cached
     * document: Pdfium's native handle is invalidated by close() immediately, unlike an
     * Objective-C object under ARC, so a close() racing a search's open-page/read-text/close-page
     * sequence on another thread (e.g. a view unmounting mid-search) is a use-after-free, not
     * just a stale reference. Searches hold the read lock for that whole sequence (see
     * PDFJSIManager); closeDocument holds the write lock while it actually closes the handle.
     */
    private static final ConcurrentHashMap<String, ReentrantReadWriteLock> lockByPdfId = new ConcurrentHashMap<>();

    public static ReentrantReadWriteLock lockFor(String pdfId) {
        return lockByPdfId.computeIfAbsent(pdfId, k -> new ReentrantReadWriteLock());
    }

    public static void registerPath(String pdfId, String path) {
        if (pdfId != null && !pdfId.isEmpty() && path != null && !path.isEmpty()) {
            pdfIdToPath.put(pdfId, path);
        }
    }

    public static void unregisterPath(String pdfId) {
        if (pdfId != null && !pdfId.isEmpty()) {
            pdfIdToPath.remove(pdfId);
            // Clear page sizes for this pdfId
            pdfIdPageSizePoints.keySet().removeIf(k -> k != null && k.startsWith(pdfId + "_"));
            closeDocument(pdfId);
        }
    }

    /**
     * Returns the Pdfium document already opened for `pdfId` at `path`, opening and caching it
     * on first use (or if `path` changed since it was cached). Callers must NOT close the
     * returned document — its lifetime is owned by the registry until `unregisterPath` or the
     * next `getOrOpenDocument` call with a different path for the same pdfId.
     */
    public static synchronized PdfDocument getOrOpenDocument(String pdfId, String path, Context context) throws IOException {
        DocHolder existing = docByPdfId.get(pdfId);
        if (existing != null && existing.path.equals(path)) {
            return existing.doc;
        }
        closeDocument(pdfId);

        ParcelFileDescriptor pfd;
        if (path.startsWith("content://")) {
            pfd = context.getContentResolver().openFileDescriptor(Uri.parse(path), "r");
        } else {
            File file = new File(path);
            if (!file.exists() || !file.canRead()) {
                throw new IOException("PDF file not found or unreadable: " + path);
            }
            pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
        }
        if (pfd == null) {
            throw new IOException("Failed to open file descriptor for: " + path);
        }
        PdfiumCore core = new PdfiumCore();
        PdfDocument doc = core.newDocument(pfd);
        docByPdfId.put(pdfId, new DocHolder(pfd, doc, path));
        return doc;
    }

    private static synchronized void closeDocument(String pdfId) {
        ReentrantReadWriteLock.WriteLock writeLock = lockFor(pdfId).writeLock();
        writeLock.lock();
        try {
            DocHolder holder = docByPdfId.remove(pdfId);
            if (holder != null) {
                try {
                    holder.doc.close();
                } catch (Exception ignored) {}
                try {
                    holder.pfd.close();
                } catch (Exception ignored) {}
            }
        } finally {
            writeLock.unlock();
            // Note: the lock instance itself is kept (not removed) — a reader that already holds
            // a reference to it (about to call readLock().lock()) must keep serializing against
            // this same lock object, not a freshly-created one, for the guarantee to hold.
        }
    }

    public static String getPath(String pdfId) {
        return pdfId == null ? null : pdfIdToPath.get(pdfId);
    }

    /** Register page size in PDF points (for highlight scaling). */
    public static void registerPageSizePoints(String pdfId, int pageIndex0Based, float widthPt, float heightPt) {
        if (pdfId != null && !pdfId.isEmpty() && widthPt > 0 && heightPt > 0) {
            pdfIdPageSizePoints.put(pdfId + "_" + pageIndex0Based, new float[] { widthPt, heightPt });
        }
    }

    /** Get page size in PDF points; returns float[2] = { widthPt, heightPt } or null. */
    public static float[] getPageSizePoints(String pdfId, int pageIndex0Based) {
        return pdfId == null ? null : pdfIdPageSizePoints.get(pdfId + "_" + pageIndex0Based);
    }

    /**
     * Fire-and-forget: if `pdfId`+`pageIndex0Based` isn't cached yet, measures it (via the same
     * cached Pdfium document {@link #getOrOpenDocument} uses) on a background thread and caches
     * the result, then runs `onReady` (e.g. postInvalidate) so a redraw can pick it up. Never
     * blocks the caller — highlight-rect scaling reads this via {@link #getPageSizePoints} from
     * PdfView.onLayerDrawn, which runs on the UI thread during the view's own draw pass; opening
     * a file descriptor and parsing PDF page structures synchronously there is slow enough on
     * its own to jank/ANR, and independently risks deadlocking against the renderer's own
     * concurrent native Pdfium calls (a first version of this did exactly that and froze the
     * view — scroll/zoom/touch all stopped responding). Highlight-rect scaling needs the
     * *actual* PDF point size — the same space PDFTextModule.getPageSize hands back to JS for
     * computing highlight rects — not PDFView/PdfFile's own getPageSize(int), which returns a
     * view-fit-scaled size in a different, view-size-dependent unit space. Before this existed,
     * the cache was only ever populated as a side effect of searchTextDirect running first; once
     * the OCR-based highlight pipeline stopped calling that search, the cache stayed permanently
     * empty and callers silently fell back to the wrong (view-fit) page size, misplacing every
     * highlight rect on Android.
     */
    public static void ensurePageSizePointsAsync(String pdfId, String path, Context context, int pageIndex0Based, Runnable onReady) {
        if (pdfId == null || path == null || path.isEmpty()) return;
        if (getPageSizePoints(pdfId, pageIndex0Based) != null) return;
        String key = pdfId + "_" + pageIndex0Based;
        if (!pageSizeMeasurementPending.add(key)) return;

        pageSizeExecutor.execute(() -> {
            try {
                // getOrOpenDocument (and the closeDocument it may run internally to replace a
                // stale cached doc) must happen BEFORE taking the read lock below, not inside
                // it: closeDocument needs this same lock's *write* side, and a thread that
                // already holds the read side can never acquire the write side (no upgrade path
                // in ReentrantReadWriteLock) — doing it the other way round self-deadlocks this
                // thread forever while it still holds the SearchRegistry.class monitor from
                // inside getOrOpenDocument, which then wedges the main thread too the next time
                // it needs that monitor (e.g. unregisterPath/closeDocument when Fabric drops the
                // PdfView) — a full app freeze, reproduced via a real ANR trace. searchInPdf
                // (PDFJSIManager) already follows this same ordering for the same reason.
                PdfDocument doc = getOrOpenDocument(pdfId, path, context);
                ReentrantReadWriteLock.ReadLock readLock = lockFor(pdfId).readLock();
                readLock.lock();
                try {
                    int pageCount = doc.getPageCount();
                    if (pageIndex0Based < 0 || pageIndex0Based >= pageCount) return;
                    io.legere.pdfiumandroid.PdfPage page = doc.openPage(pageIndex0Based);
                    if (page == null) return;
                    try {
                        float widthPt = page.getPageWidthPoint();
                        float heightPt = page.getPageHeightPoint();
                        if (widthPt > 0 && heightPt > 0) {
                            registerPageSizePoints(pdfId, pageIndex0Based, widthPt, heightPt);
                            if (onReady != null) onReady.run();
                        }
                    } finally {
                        page.close();
                    }
                } finally {
                    readLock.unlock();
                }
            } catch (Exception ignored) {
            } finally {
                pageSizeMeasurementPending.remove(key);
            }
        });
    }
}
