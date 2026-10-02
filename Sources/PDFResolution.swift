import CoreGraphics
import Foundation

// ============================================================
//  A PDF has no resolution of its own — pages are vector. What
//  does have one is the bitmaps drawn on them: a scanned page is
//  one big image stretched over the page. This walks the page's
//  drawing operators, tracks the transform each image is drawn
//  with, and reports pixels per inch of the image that covers
//  the most of the page.
// ============================================================

enum PDFResolution {

    /// Effective dpi of the image covering most of the page, or nil for a page
    /// with no images (pure vector — there is no "original" to keep).
    static func of(_ page: CGPDFPage) -> Double? {
        guard let images = imageSizes(page), !images.isEmpty,
              let stream = CGPDFContentStreamCreateWithPage(page) as CGPDFContentStreamRef?,
              let table = CGPDFOperatorTableCreate()
        else { return nil }

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            scanState(info).stack.append(scanState(info).ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = scanState(info)
            if let last = s.stack.popLast() { s.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &v[i]) else { return }
            }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            let s = scanState(info)
            s.ctm = m.concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var raw: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &raw), let raw else { return }
            let s = scanState(info)
            guard let px = s.images[String(cString: raw)] else { return }
            // an image fills the unit square; the CTM says how big that square
            // ends up on the page, in points
            let w = hypot(s.ctm.a, s.ctm.b) / 72
            let h = hypot(s.ctm.c, s.ctm.d) / 72
            guard w > 0.05, h > 0.05 else { return }      // ignore specks and masks
            // the image covering the most of the page decides — a crisp little
            // logo on a 150 dpi scan doesn't make the scan 600 dpi
            let area = Double(w * h)
            if area > s.bestArea {
                s.bestArea = area
                s.best = min(Double(px.width) / w, Double(px.height) / h)
            }
        }

        let s = ScanState(images: images)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(s).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
        CGPDFContentStreamRelease(stream)

        guard s.best > 0 else { return nil }
        return min(1200, s.best.rounded())
    }

    /// The sharpest page among the first few — enough to label a document
    /// without reading every page of a 500-page scan.
    static func of(_ doc: CGPDFDocument, sampling limit: Int = 8) -> Double? {
        let n = min(doc.numberOfPages, limit)
        guard n > 0 else { return nil }
        return (1...n).compactMap { doc.page(at: $0).flatMap(of) }.max()
    }

    // MARK: - internals

    private final class ScanState {
        let images: [String: CGSize]
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var best = 0.0
        init(images: [String: CGSize]) { self.images = images }
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    /// Image XObjects on the page, by resource name. Resources may be inherited
    /// from an ancestor Pages node, so the parent chain is walked.
    private static func imageSizes(_ page: CGPDFPage) -> [String: CGSize]? {
        var node = page.dictionary
        var resources: CGPDFDictionaryRef?
        while let n = node, resources == nil {
            if !CGPDFDictionaryGetDictionary(n, "Resources", &resources) {
                var parent: CGPDFDictionaryRef?
                node = CGPDFDictionaryGetDictionary(n, "Parent", &parent) ? parent : nil
            }
        }
        var xobjects: CGPDFDictionaryRef?
        guard let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
              let xobjects else { return nil }

        var found: [String: CGSize] = [:]
        CGPDFDictionaryApplyBlock(xobjects, { key, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image" else { return true }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(dict, "Width", &w),
                  CGPDFDictionaryGetInteger(dict, "Height", &h), w > 0, h > 0 else { return true }
            found[String(cString: key)] = CGSize(width: Int(w), height: Int(h))
            return true
        }, nil)
        return found
    }
}

// The operator callbacks are C function pointers and can't capture anything,
// so the state they share travels through the scanner's info pointer and is
// reached from file scope.

private final class ScanState {
    let images: [String: CGSize]
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var best = 0.0
    var bestArea = 0.0
    init(images: [String: CGSize]) { self.images = images }
}

private func scanState(_ info: UnsafeMutableRawPointer?) -> ScanState {
    Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
}
