import AppKit
import Foundation
import Observation
import SwiftUI

// ============================================================
//  App state: two queues sharing one list, the settings for
//  each side, and the run loop.
// ============================================================

enum Status: Equatable {
    case queued, working, done, skipped, failed(String)

    var isTerminal: Bool {
        switch self {
        case .queued, .working: return false
        default: return true
        }
    }
}

struct Item: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let media: MediaKind
    var w: Int = 0
    var h: Int = 0
    /// source format label, e.g. "JPEG 2000" or "MOV"
    var kind: String = ""
    /// PDFs only; 0 for bitmaps
    var pages: Int = 0
    /// PDFs only: resolution of the images inside, 0 when there are none
    var pdfDPI: Int = 0
    // video only
    var seconds: Double = 0
    var fps: Double = 0
    var codec: String = ""
    var hasAudio = false
    var audioRate = 0
    /// set when the file can never convert here (e.g. a codec macOS dropped);
    /// the row shows it straight away and Start leaves the file alone
    var blocked: String? = nil
    /// macOS can't decode or open it, so the bundled ffmpeg does the work
    var viaFFmpeg = false

    /// what ffmpeg needs to size and time the job, rebuilt from the row
    var probe: VideoProbe {
        var p = VideoProbe()
        p.w = w; p.h = h; p.seconds = seconds; p.fps = fps
        p.codec = codec; p.hasAudio = hasAudio; p.container = kind
        p.audioRate = audioRate
        return p
    }

    var bytes: Int64 = 0
    var status: Status = .queued
    /// 0…1 while a video exports; images jump straight to done
    var progress: Double = 0
    var out: URL? = nil
    var outCount: Int = 0
    var outBytes: Int64 = 0

    var isPDF: Bool { pages > 0 }
    var isVideo: Bool { media == .video }
}

@MainActor
@Observable
final class Model {

    /// One instance, so the app delegate can hand it files opened from Finder.
    static let shared = Model()

    // MARK: queue
    var items: [Item] = []
    var running = false
    var mode: MediaKind = .image

    /// the half of the queue the current tab shows
    var visible: [Item] { items.filter { $0.media == mode } }

    var modeIndex: Int {
        get { mode.rawValue }
        set { mode = MediaKind(rawValue: newValue) ?? .image }
    }

    // MARK: image settings (indices drive the panel controls)
    var formatIndex = 0
    var quality: Double = 90
    var sizeIndex = 0
    var scale: Double = 100
    var fit: Double = 2048
    var background: Color = .white
    var keepMetadata = true

    // MARK: PDF input
    /// 0 = every page, 1 = one page
    var pdfModeIndex = 0
    var pdfPage: Double = 1
    var pdfDPI: Double = 150
    var pdfOriginalDPI = true

    // MARK: video settings
    var videoContainerIndex = 0
    var videoCodec: VideoCodec = .h264
    var videoSize: VideoSize = .source
    var keepAudio = true

    // MARK: shared file settings
    var destIndex = 0
    var folder: URL? = nil
    var existsIndex = 0

    // MARK: sections
    var outputOpen = true
    var pdfOpen = true
    var videoOpen = true
    var filesOpen = true

    // MARK: derived — images

    /// the PDF section only exists while there is a PDF in the queue
    var hasPDF: Bool { items.contains { $0.media == .image && $0.isPDF } }
    /// a PDF with nothing but vectors has no resolution to keep
    var hasVectorPDF: Bool { items.contains { $0.media == .image && $0.isPDF && $0.pdfDPI == 0 } }

    var maxPDFPages: Int {
        max(1, items.filter { $0.media == .image }.map(\.pages).max() ?? 1)
    }

    var format: OutputFormat { Formats.all[min(formatIndex, Formats.all.count - 1)] }

    var options: Options {
        Options(
            format: format,
            quality: quality,
            sizeMode: SizeMode(rawValue: sizeIndex) ?? .original,
            scale: scale,
            fit: fit,
            background: NSColor(background),
            keepMetadata: keepMetadata,
            destination: Destination(rawValue: destIndex) ?? .beside,
            folder: folder,
            onExists: OnExists(rawValue: existsIndex) ?? .rename,
            pdfAllPages: pdfModeIndex == 0,
            pdfPage: Int(pdfPage.rounded()),
            pdfDPI: pdfDPI,
            pdfOriginalDPI: pdfOriginalDPI
        )
    }

    // MARK: derived — video
    // The three choices depend on each other (ProRes only fits in MOV, HEVC has
    // fewer size presets), so the panel always reads the "effective" value:
    // a stale pick is never shown and never used.

    var videoContainer: VideoContainer {
        VideoFormats.containers[min(videoContainerIndex, VideoFormats.containers.count - 1)]
    }
    var videoCodecs: [VideoCodec] { VideoFormats.codecs(for: videoContainer) }
    var effectiveCodec: VideoCodec { videoCodecs.contains(videoCodec) ? videoCodec : .h264 }
    var videoSizes: [VideoSize] { effectiveCodec.sizes }
    var effectiveSize: VideoSize { videoSizes.contains(videoSize) ? videoSize : .source }

    var videoOptions: VideoOptions {
        VideoOptions(
            container: videoContainer,
            codec: effectiveCodec,
            size: effectiveSize,
            keepAudio: keepAudio,
            destination: Destination(rawValue: destIndex) ?? .beside,
            folder: folder,
            onExists: OnExists(rawValue: existsIndex) ?? .rename
        )
    }

    // MARK: derived — both

    /// what the format button on the export bar says
    var targetName: String { mode == .image ? format.name : videoContainer.name }

    func cycleTarget() {
        switch mode {
        case .image: formatIndex = (formatIndex + 1) % Formats.all.count
        case .video: videoContainerIndex = (videoContainerIndex + 1) % VideoFormats.containers.count
        }
    }

    /// Smooth for video (each export reports its own fraction), stepwise for
    /// images, which finish too quickly to be worth reporting.
    var progress: Double {
        // files that were never going to run don't hold the bar back
        let v = visible.filter { $0.blocked == nil }
        guard !v.isEmpty else { return 0 }
        let sum = v.reduce(0.0) { acc, it in
            if it.status.isTerminal { return acc + 1 }
            return acc + (it.status == .working ? it.progress : 0)
        }
        return sum / Double(v.count)
    }

    /// The pixel size this item will come out at, for the queue.
    func predicted(_ item: Item) -> (w: Int, h: Int, dpi: Int)? {
        guard item.media == .image else { return nil }
        return Converter.predictedPixels(
            w: item.w, h: item.h, isPDF: item.isPDF, nativeDPI: item.pdfDPI, options: options)
    }

    /// something in this tab that can actually convert
    var hasWork: Bool { visible.contains { $0.blocked == nil } }

    var folderName: String {
        folder.map { $0.lastPathComponent } ?? "Choose Folder…"
    }

    // MARK: input

    func add(_ urls: [URL]) {
        let found = Converter.collect(urls)
        let known = Set(items.map { $0.url.standardizedFileURL })
        let fresh = found.filter { !known.contains($0.standardizedFileURL) }
        let incoming = fresh.compactMap { u in Converter.kind(of: u).map { Item(url: u, media: $0) } }
        guard !incoming.isEmpty else { return }

        items.append(contentsOf: incoming)

        // dropping only videos while looking at images (or the other way round)
        // means that is the side the person wants
        let kinds = Set(incoming.map(\.media))
        if !running, kinds.count == 1, let only = kinds.first, only != mode {
            withAnimation(M.easeOutSlow) { mode = only }
        }
        probe(incoming.map { ($0.id, $0.url, $0.media) })
    }

    private func probe(_ jobs: [(UUID, URL, MediaKind)]) {
        Task.detached(priority: .utility) {
            for (id, url, media) in jobs {
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                switch media {
                case .image:
                    let p = Converter.probe(url) ?? Converter.Probe(kind: url.pathExtension.uppercased())
                    await MainActor.run {
                        Model.shared.apply(id) {
                            $0.w = p.w; $0.h = p.h; $0.kind = p.kind; $0.pages = p.pages; $0.bytes = bytes
                            $0.pdfDPI = p.dpi
                        }
                    }
                case .video:
                    // macOS first; ffmpeg only for what macOS can't open or decode
                    let native = await VideoConverter.probe(url)
                    var chosen = native
                    var viaFFmpeg = false
                    var blocked: String? = nil
                    if native?.decodable != true {
                        if let f = await FFmpeg.probe(url) {
                            chosen = f
                            viaFFmpeg = true
                        } else if let native {
                            blocked = VideoError.legacy(native.codec)
                        } else {
                            blocked = "Can’t read"
                        }
                    }
                    let p = chosen
                    let (routed, reason) = (viaFFmpeg, blocked)
                    await MainActor.run {
                        Model.shared.apply(id) {
                            $0.kind = url.pathExtension.uppercased()
                            $0.bytes = bytes
                            $0.viaFFmpeg = routed
                            $0.blocked = reason
                            guard let p else { return }
                            $0.w = p.w; $0.h = p.h
                            $0.seconds = p.seconds; $0.fps = p.fps
                            $0.codec = p.codec; $0.hasAudio = p.hasAudio
                            $0.audioRate = p.audioRate
                        }
                    }
                }
            }
            await MainActor.run {
                // a one-page cap makes the page slider useless
                let m = Model.shared
                m.pdfPage = min(m.pdfPage, Double(m.maxPDFPages))
            }
        }
    }

    /// Edit one item in place, by id; quietly does nothing if it has gone.
    func apply(_ id: UUID, _ edit: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[i])
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Clears the side that is showing; the other queue is left alone.
    func clear() {
        guard !running else { return }
        items.removeAll { $0.media == mode }
    }

    // MARK: panels

    func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.message = mode == .image ? "Pick images or PDFs to convert" : "Pick videos to convert"
        p.prompt = "Add"
        if p.runModal() == .OK { add(p.urls) }
    }

    func pickFolder() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Pick a folder — images and videos inside are sorted into their tabs"
        p.prompt = "Add"
        if p.runModal() == .OK { add(p.urls) }
    }

    func pickDestination() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = "Where should the converted files go?"
        p.prompt = "Use Folder"
        if p.runModal() == .OK, let u = p.urls.first {
            folder = u
            destIndex = Destination.folder.rawValue
        }
    }

    func reveal(_ item: Item) {
        let target = item.out ?? item.url
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: run

    func run() {
        guard !running else { return }
        let batch = visible.filter { $0.blocked == nil }
        guard !batch.isEmpty else { return }
        if (Destination(rawValue: destIndex) ?? .beside) == .folder && folder == nil {
            pickDestination()
            guard folder != nil else { return }
        }

        running = true
        for it in batch {
            apply(it.id) {
                $0.status = .queued; $0.progress = 0
                $0.out = nil; $0.outCount = 0; $0.outBytes = 0
            }
        }

        let imageOpts = options
        let videoOpts = videoOptions
        let jobs = batch.map { ($0.id, $0.url, $0.media, $0.viaFFmpeg, $0.probe) }
        // the hardware video encoders are shared: two exports keep them busy
        // without the two starving each other; stills scale with the cores
        let limit = mode == .video
            ? min(jobs.count, 2)
            : min(jobs.count, max(2, ProcessInfo.processInfo.activeProcessorCount))

        Task { @MainActor in
            await withTaskGroup(of: (UUID, Result<[URL], Error>).self) { group in
                var next = 0

                @MainActor func launch() {
                    guard next < jobs.count else { return }
                    let (id, url, media, viaFFmpeg, probe) = jobs[next]
                    next += 1
                    self.apply(id) { $0.status = .working }
                    group.addTask(priority: .userInitiated) {
                        let report: @Sendable (Double) -> Void = { p in
                            Task { @MainActor in Model.shared.apply(id) { $0.progress = p } }
                        }
                        do {
                            switch media {
                            case .image:
                                return (id, .success(try Converter.convert(
                                    url, options: imageOpts, progress: report)))
                            case .video where viaFFmpeg:
                                let out = try await FFmpeg.convert(
                                    url, probe: probe, options: videoOpts, progress: report)
                                return (id, .success([out]))
                            case .video:
                                let out = try await VideoConverter.convert(
                                    url, options: videoOpts, progress: report)
                                return (id, .success([out]))
                            }
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                }

                for _ in 0..<limit { launch() }

                while let (id, result) = await group.next() {
                    self.finish(id, result)
                    launch()
                }
            }
            self.running = false
        }
    }

    private func finish(_ id: UUID, _ result: Result<[URL], Error>) {
        apply(id) { item in
            switch result {
            case .success(let outs):
                item.status = .done
                item.progress = 1
                item.out = outs.first
                item.outCount = outs.count
                item.outBytes = outs.reduce(0) {
                    $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            case .failure(let err):
                if case ConvertError.skipped = err {
                    item.status = .skipped
                } else {
                    let msg = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
                    item.status = .failed(msg)
                }
            }
        }
    }
}

// MARK: - formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        guard n > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: n)
    }

    static func px(_ w: Int, _ h: Int) -> String {
        w > 0 && h > 0 ? "\(w) × \(h)" : "—"
    }
}
