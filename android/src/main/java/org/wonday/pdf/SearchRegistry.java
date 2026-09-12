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
import java.util.concurrent.ConcurrentHashMap;

import io.legere.pdfiumandroid.PdfDocument;
import io.legere.pdfiumandroid.PdfiumCore;

public final class SearchRegistry {
    private static final ConcurrentHashMap<String, String> pdfIdToPath = new ConcurrentHashMap<>();
    /** Key: pdfId + "_" + pageIndex0Based, value: float[2] = { widthPt, heightPt } */
    private static final ConcurrentHashMap<String, float[]> pdfIdPageSizePoints = new ConcurrentHashMap<>();

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
        DocHolder holder = docByPdfId.remove(pdfId);
        if (holder != null) {
            try {
                holder.doc.close();
            } catch (Exception ignored) {}
            try {
                holder.pfd.close();
            } catch (Exception ignored) {}
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
}
