import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ============================================================
//  The engine. Bitmaps go through ImageIO, which on macOS reads
//  JPEG 2000 natively — no third-party decoder needed. PDFs go
//  through CoreGraphics, page by page.
// ============================================================

struct OutputFormat: Identifiable, Hashable {
    let id: String          // UTI
    let name: String
    let ext: String
    let lossy: Bool
    let alpha: Bool
    /// formats that can hold more than 8 bits per component
    let deep: Bool

    var isPDF: Bool { id == "com.adobe.pdf" }
}

enum Formats {
    static let all: [OutputFormat] = [
        .init(id: "public.png",                 name: "PNG",       ext: "png",  lossy: false, alpha: true,  deep: true),
        .init(id: "public.jpeg",                name: "JPEG",      ext: "jpg",  lossy: true,  alpha: false, deep: false),
        .init(id: "public.tiff",                name: "TIFF",      ext: "tif",  lossy: false, alpha: true,  deep: true),
        .init(id: "public.heic",                name: "HEIC",      ext: "heic", lossy: true,  alpha: true,  deep: false),
        .init(id: "public.avif",                name: "AVIF",      ext: "avif", lossy: true,  alpha: true,  deep: false),
        .init(id: "public.jpeg-2000",           name: "JPEG 2000", ext: "jp2",  lossy: true,  alpha: true,  deep: true),
        .init(id: "com.microsoft.bmp",          name: "BMP",       ext: "bmp",  lossy: false, alpha: false, deep: false),
        .init(id: "com.compuserve.gif",         name: "GIF",       ext: "gif",  lossy: false, alpha: true,  deep: false),
        .init(id: "com.adobe.photoshop-image",  name: "PSD",       ext: "psd",  lossy: false, alpha: true,  deep: true),
        .init(id: "com.ilm.openexr-image",      name: "OpenEXR",   ext: "exr",  lossy: false, alpha: true,  deep: true),
        .init(id: "com.adobe.pdf",              name: "PDF",       ext: "pdf",  lossy: false, alpha: true,  deep: false),
    ]

    static var names: [String] { all.map(\.name) }

    /// Everything ImageIO on this Mac knows how to read.
    static let readable: Set<String> = {
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return Set(ids)
    }()

    static func canRead(_ url: URL) -> Bool {
        if Converter.isPDF(url) { return true }          // PDFs come in through CoreGraphics
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        if readable.contains(t.identifier) { return true }
        // .jp2/.j2k/.jpf and friends sometimes resolve to a parent type
        return readable.contains { readableID in
            guard let r = UTType(readableID) else { return false }
            return t.conforms(to: r)
        }
    }
}

enum SizeMode: Int { case original = 0, scale = 1, fit = 2 }
enum Destination: Int { case beside = 0, folder = 1 }
enum OnExists: Int { case rename = 0, overwrite = 1, skip = 2 }

struct Options {
    var format: OutputFormat = Formats.all[0]
    var quality: Double = 90
    var sizeMode: SizeMode = .original
    var scale: Double = 100
    var fit: Double = 2048
    var background: NSColor = .white
    var keepMetadata: Bool = true
    var destination: Destination = .beside
    var folder: URL? = nil
    var onExists: OnExists = .rename

    // ---- PDF input ----
    var pdfAllPages: Bool = true
    var pdfPage: Int = 1
    /// points → pixels when rasterising a page
    var pdfDPI: Double = 150
    /// render each page at the resolution of the images on it; pages with
    /// none (pure vector) fall back to pdfDPI
    var pdfOriginalDPI: Bool = true
}

enum ConvertError: LocalizedError {
    case unreadable
    case noImage
    case skipped
    case noDestination
    case writeFailed
    case noSuchPage(Int, Int)

    var errorDescription: String? {
        switch self {
        case .unreadable:            return "Can’t read"
        case .noImage:               return "No image data"
        case .skipped:               return "Skipped — exists"
        case .noDestination:         return "No output folder"
        case .writeFailed:           return "Write failed"
        case .noSuchPage(let k, let n):
            return n == 1 ? "Only 1 page — no page \(k)" : "Only \(n) pages — no page \(k)"
        }
    }
}

enum Converter {

    // MARK: probing

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    struct Probe {
        var w = 0
        var h = 0
        var kind = ""
        /// 0 for anything that is not a PDF
        var pages = 0
        /// PDFs: resolution of the sharpest image, 0 for a pure vector document
        var dpi = 0
    }

    /// Pixel size, kind and page count without decoding anything.
    static func probe(_ url: URL) -> Probe? {
        if isPDF(url) {
            guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0,
                  let page = doc.page(at: 1) else { return nil }
            let pt = pageSize(page)
            return Probe(w: Int(pt.width.rounded()), h: Int(pt.height.rounded()),
                         kind: "PDF", pages: doc.numberOfPages,
                         dpi: Int(PDFResolution.of(doc) ?? 0))
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let swap = (5...8).contains(Int(o))
        let kind = (CGImageSourceGetType(src) as String?).map(shortName) ?? url.pathExtension.uppercased()
        return Probe(w: swap ? h : w, h: swap ? w : h, kind: kind, pages: 0)
    }

    private static func shortName(_ uti: String) -> String {
        if let known = Formats.all.first(where: { $0.id == uti }) { return known.name }
        if let t = UTType(uti), let ext = t.preferredFilenameExtension { return ext.uppercased() }
        return uti.split(separator: ".").last.map { $0.uppercased() } ?? "?"
    }

    // MARK: conversion

    /// A PDF can produce several files, so every conversion returns a list.
    @discardableResult
    static func convert(_ url: URL, options o: Options) throws -> [URL] {
        if isPDF(url) { return try convertPDF(url, options: o) }
        return [try convertImage(url, options: o)]
    }

    // MARK: bitmap in

    private static func convertImage(_ url: URL, options o: Options) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ConvertError.unreadable }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1

        guard let image = CGImageSourceCreateImageAtIndex(
            src, 0, [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCache: false] as CFDictionary
        ) else { throw ConvertError.noImage }

        let dstURL = try outputURL(for: url, options: o)

        let swap = (5...8).contains(Int(orientation))
        let viewW = swap ? image.height : image.width
        let viewH = swap ? image.width : image.height
        let target = targetSize(w: viewW, h: viewH, options: o)

        let sourceHasAlpha = hasAlpha(image)
        let mustFlatten = sourceHasAlpha && !o.format.alpha
        let resizing = target.w != viewW || target.h != viewH
        let needsRedraw = resizing || orientation != 1 || mustFlatten

        var out = image
        if needsRedraw {
            guard let redrawn = render(
                image,
                to: target,
                orientation: orientation,
                keepAlpha: o.format.alpha && sourceHasAlpha,
                background: mustFlatten ? o.background : nil,
                allowDeep: o.format.deep
            ) else { throw ConvertError.writeFailed }
            out = redrawn
        }

        var write: [CFString: Any] = [:]
        if o.keepMetadata {
            write = props
            write.removeValue(forKey: kCGImagePropertyPixelWidth)
            write.removeValue(forKey: kCGImagePropertyPixelHeight)
            write.removeValue(forKey: kCGImagePropertyOrientation)   // baked into the pixels
            if !o.format.alpha { write.removeValue(forKey: kCGImagePropertyHasAlpha) }
        }
        try writeImage(out, to: dstURL, properties: write, options: o)
        return dstURL
    }

    private static func writeImage(
        _ image: CGImage, to dstURL: URL, properties: [CFString: Any], options o: Options
    ) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            dstURL as CFURL, o.format.id as CFString, 1, nil
        ) else { throw ConvertError.writeFailed }

        var props = properties
        if o.format.lossy {
            props[kCGImageDestinationLossyCompressionQuality] = o.quality / 100
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed }
    }

    // MARK: PDF in

    /// Page size in points, with the page's own /Rotate applied.
    private static func pageSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let turn = ((Int(page.rotationAngle) % 360) + 360) % 360
        let sideways = turn == 90 || turn == 270
        return sideways ? CGSize(width: box.height, height: box.width)
                        : CGSize(width: box.width, height: box.height)
    }

    private static func convertPDF(_ url: URL, options o: Options) throws -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else {
            throw ConvertError.unreadable
        }
        let total = doc.numberOfPages

        let wanted: [Int]
        if o.pdfAllPages {
            wanted = Array(1...total)
        } else {
            guard o.pdfPage >= 1, o.pdfPage <= total else {
                throw ConvertError.noSuchPage(o.pdfPage, total)
            }
            wanted = [o.pdfPage]
        }

        var written: [URL] = []
        for k in wanted {
            guard let page = doc.page(at: k) else { continue }
            // a one-page document keeps its plain name
            let suffix = total > 1 ? "-p\(k)" : ""
            let dst = try outputURL(for: url, options: o, suffix: suffix)

            if o.format.isPDF {
                try writeVectorPage(page, to: dst, options: o)   // stays vector
            } else {
                guard let img = rasterize(page, options: o) else { throw ConvertError.writeFailed }
                try writeImage(img, to: dst, properties: [:], options: o)
            }
            written.append(dst)
        }
        guard !written.isEmpty else { throw ConvertError.noImage }
        return written
    }

    private static func rasterize(_ page: CGPDFPage, options o: Options) -> CGImage? {
        let pt = pageSize(page)
        guard pt.width > 0, pt.height > 0 else { return nil }

        let dpi = o.pdfOriginalDPI ? (PDFResolution.of(page) ?? o.pdfDPI) : o.pdfDPI
        let k = max(1, dpi) / 72
        let base = (w: max(1, Int((pt.width * k).rounded())),
                    h: max(1, Int((pt.height * k).rounded())))
        let target = targetSize(w: base.w, h: base.h, options: o)

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: target.w, height: target.h,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: target.w, height: target.h)
        // a PDF page paints no paper of its own, so give it one
        ctx.setFillColor((o.background.usingColorSpace(.sRGB) ?? .white).cgColor)
        ctx.fill(rect)
        // getDrawingTransform only ever shrinks a page to fit — it will not
        // scale one up — so the enlargement is applied here and the transform
        // is asked for a page-sized rect, where it only has to handle the
        // box origin and the page's own /Rotate
        ctx.scaleBy(x: CGFloat(target.w) / pt.width, y: CGFloat(target.h) / pt.height)
        ctx.concatenate(
            page.getDrawingTransform(
                .cropBox,
                rect: CGRect(origin: .zero, size: pt),
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// PDF → PDF is a page extract, so the vectors are kept rather than rasterised.
    private static func writeVectorPage(_ page: CGPDFPage, to dst: URL, options o: Options) throws {
        let pt = pageSize(page)
        let t = targetSize(w: max(1, Int(pt.width.rounded())), h: max(1, Int(pt.height.rounded())), options: o)
        var box = CGRect(x: 0, y: 0, width: CGFloat(t.w), height: CGFloat(t.h))
        guard let ctx = CGContext(dst as CFURL, mediaBox: &box, nil) else {
            throw ConvertError.writeFailed
        }
        ctx.beginPDFPage(nil)
        // same clamp as above: scale here, let the transform place the box
        ctx.scaleBy(x: box.width / pt.width, y: box.height / pt.height)
        ctx.concatenate(
            page.getDrawingTransform(
                .cropBox,
                rect: CGRect(origin: .zero, size: pt),
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        ctx.drawPDFPage(page)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: geometry

    private static func targetSize(w: Int, h: Int, options o: Options) -> (w: Int, h: Int) {
        switch o.sizeMode {
        case .original:
            return (w, h)
        case .scale:
            let k = o.scale / 100
            return (max(1, Int((Double(w) * k).rounded())), max(1, Int((Double(h) * k).rounded())))
        case .fit:
            let longest = Double(max(w, h))
            guard longest > o.fit else { return (w, h) }
            let k = o.fit / longest
            return (max(1, Int((Double(w) * k).rounded())), max(1, Int((Double(h) * k).rounded())))
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: return true
        default: return false
        }
    }

    /// EXIF orientation → (mirror horizontally first, then rotate N° clockwise)
    private static func decompose(_ o: UInt32) -> (mirror: Bool, rot: Int) {
        switch o {
        case 2: return (true, 0)
        case 3: return (false, 180)
        case 4: return (true, 180)
        case 5: return (true, 270)
        case 6: return (false, 90)
        case 7: return (true, 90)
        case 8: return (false, 270)
        default: return (false, 0)
        }
    }

    private static func render(
        _ image: CGImage,
        to size: (w: Int, h: Int),
        orientation: UInt32,
        keepAlpha: Bool,
        background: NSColor?,
        allowDeep: Bool
    ) -> CGImage? {
        let W = size.w, H = size.h
        let gray = image.colorSpace?.model == .monochrome && background == nil
        let deep = allowDeep && image.bitsPerComponent > 8
        let bpc = deep ? 16 : 8

        let space: CGColorSpace = {
            if gray { return image.colorSpace ?? CGColorSpaceCreateDeviceGray() }
            if let cs = image.colorSpace, cs.model == .rgb { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()

        var info: UInt32 = keepAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        if gray { info = CGImageAlphaInfo.none.rawValue }
        if deep { info |= CGBitmapInfo.byteOrder16Little.rawValue }

        func makeContext(_ space: CGColorSpace, _ bpc: Int, _ info: UInt32) -> CGContext? {
            CGContext(
                data: nil, width: W, height: H,
                bitsPerComponent: bpc,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: info
            )
        }

        var ctx = makeContext(space, bpc, info)
        if ctx == nil {   // fall back to plain 8-bit sRGB
            ctx = makeContext(
                CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                8,
                keepAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                          : CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }
        guard let ctx else { return nil }

        ctx.interpolationQuality = .high

        if let bg = background {
            let cg = (bg.usingColorSpace(.sRGB) ?? .white).cgColor
            ctx.setFillColor(cg)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }

        let (mirror, rot) = decompose(orientation)
        // the image is drawn un-oriented, so its own box may be the swap of the output
        let dw = (rot == 90 || rot == 270) ? CGFloat(H) : CGFloat(W)
        let dh = (rot == 90 || rot == 270) ? CGFloat(W) : CGFloat(H)

        switch rot {
        case 90:
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: CGFloat(W), y: CGFloat(H)); ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: CGFloat(W), y: 0); ctx.rotate(by: .pi / 2)
        default:
            break
        }
        if mirror {
            ctx.translateBy(x: dw, y: 0); ctx.scaleBy(x: -1, y: 1)
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        return ctx.makeImage()
    }

    // MARK: naming

    static func outputURL(for src: URL, options o: Options, suffix: String = "") throws -> URL {
        try outputURL(
            for: src, ext: o.format.ext,
            destination: o.destination, folder: o.folder, onExists: o.onExists,
            suffix: suffix
        )
    }

    /// Shared by images and video: where the result goes and what happens when
    /// something is already there.
    static func outputURL(
        for src: URL,
        ext: String,
        destination: Destination,
        folder chosen: URL?,
        onExists: OnExists,
        suffix: String = ""
    ) throws -> URL {
        let folder: URL
        switch destination {
        case .beside:
            folder = src.deletingLastPathComponent()
        case .folder:
            guard let f = chosen else { throw ConvertError.noDestination }
            folder = f
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stem = src.deletingPathExtension().lastPathComponent + suffix
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")

        let fm = FileManager.default
        let clashes = fm.fileExists(atPath: candidate.path)
            || candidate.standardizedFileURL == src.standardizedFileURL

        if clashes {
            switch onExists {
            case .overwrite:
                if candidate.standardizedFileURL == src.standardizedFileURL { throw ConvertError.skipped }
                try? fm.removeItem(at: candidate)
            case .skip:
                throw ConvertError.skipped
            case .rename:
                var n = 1
                repeat {
                    candidate = folder.appendingPathComponent("\(stem)-\(n).\(ext)")
                    n += 1
                } while fm.fileExists(atPath: candidate.path) && n < 1000
            }
        }
        return candidate
    }

    // MARK: input gathering

    /// What a file is, or nil when neither side can read it.
    static func kind(of url: URL) -> MediaKind? {
        if VideoFormats.canRead(url) { return .video }
        if Formats.canRead(url) { return .image }
        return nil
    }

    /// Expands folders, keeps only what can be read, skips hidden files.
    static func collect(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let item = e?.nextObject() as? URL {
                    if kind(of: item) != nil { out.append(item) }
                }
            } else if kind(of: url) != nil {
                out.append(url)
            }
        }
        return out
    }
}
