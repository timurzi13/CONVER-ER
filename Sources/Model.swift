import AppKit
import Foundation
import Observation
import SwiftUI

// ============================================================
//  App state: the queue, the settings, and the run loop.
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
    var w: Int = 0
    var h: Int = 0
    var kind: String = ""
    /// PDFs only; 0 for bitmaps
    var pages: Int = 0
    var bytes: Int64 = 0
    var status: Status = .queued
    var out: URL? = nil
    var outCount: Int = 0
    var outBytes: Int64 = 0

    var isPDF: Bool { pages > 0 }
}

@MainActor
@Observable
final class Model {

    /// One instance, so the app delegate can hand it files opened from Finder.
    static let shared = Model()

    // MARK: queue
    var items: [Item] = []
    var running = false
    var completed = 0

    // MARK: settings (indices drive the panel controls)
    var formatIndex = 0
    var quality: Double = 90
    var sizeIndex = 0
    var scale: Double = 100
    var fit: Double = 2048
    var background: Color = .white
    var keepMetadata = true
    var destIndex = 0
    var folder: URL? = nil
    var existsIndex = 0

    // MARK: PDF input
    /// 0 = every page, 1 = one page
    var pdfModeIndex = 0
    var pdfPage: Double = 1
    var pdfDPI: Double = 150

    // MARK: sections
    var outputOpen = true
    var pdfOpen = true
    var filesOpen = true

    /// the PDF section only exists while there is a PDF in the queue
    var hasPDF: Bool { items.contains { $0.isPDF } }
    var maxPDFPages: Int { max(1, items.map(\.pages).max() ?? 1) }

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
            pdfDPI: pdfDPI
        )
    }

    var pendingCount: Int { items.filter { !$0.status.isTerminal || $0.status == .skipped }.count }
    var progress: Double {
        let total = items.count
        return total == 0 ? 0 : Double(completed) / Double(total)
    }

    var folderName: String {
        folder.map { $0.lastPathComponent } ?? "Choose Folder…"
    }

    // MARK: input

    func add(_ urls: [URL]) {
        let found = Converter.collect(urls)
        let known = Set(items.map { $0.url.standardizedFileURL })
        let fresh = found.filter { !known.contains($0.standardizedFileURL) }
        guard !fresh.isEmpty else { return }

        let start = items.count
        items.append(contentsOf: fresh.map { Item(url: $0) })
        probe(range: start..<items.count)
    }

    private func probe(range: Range<Int>) {
        let slice = range.map { (items[$0].id, items[$0].url) }
        Task.detached(priority: .utility) {
            var found: [(UUID, Converter.Probe, Int64)] = []
            for (id, url) in slice {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let p = Converter.probe(url)
                    ?? Converter.Probe(kind: url.pathExtension.uppercased())
                found.append((id, p, size))
            }
            let result = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, p, bytes) in result {
                    guard let i = self.items.firstIndex(where: { $0.id == id }) else { continue }
                    self.items[i].w = p.w
                    self.items[i].h = p.h
                    self.items[i].kind = p.kind
                    self.items[i].pages = p.pages
                    self.items[i].bytes = bytes
                }
                // a one-page cap makes the page slider useless
                self.pdfPage = min(self.pdfPage, Double(self.maxPDFPages))
            }
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        completed = min(completed, items.count)
    }

    func clear() {
        guard !running else { return }
        items.removeAll()
        completed = 0
    }

    // MARK: panels

    func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.message = "Pick images to convert"
        p.prompt = "Add"
        if p.runModal() == .OK { add(p.urls) }
    }

    func pickFolder() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Pick a folder of images"
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
        guard !running, !items.isEmpty else { return }
        if options.destination == .folder && options.folder == nil {
            pickDestination()
            guard folder != nil else { return }
        }

        running = true
        completed = 0
        for i in items.indices {
            items[i].status = .queued
            items[i].out = nil
            items[i].outCount = 0
            items[i].outBytes = 0
        }

        let opts = options
        let jobs = items.map { ($0.id, $0.url) }

        Task { @MainActor in
            await withTaskGroup(of: (UUID, Result<[URL], Error>).self) { group in
                var next = 0
                let limit = min(jobs.count, max(2, ProcessInfo.processInfo.activeProcessorCount))

                @MainActor func launch() {
                    guard next < jobs.count else { return }
                    let (id, url) = jobs[next]
                    next += 1
                    self.setStatus(id, .working)
                    group.addTask(priority: .userInitiated) {
                        do { return (id, .success(try Converter.convert(url, options: opts))) }
                        catch { return (id, .failure(error)) }
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

    private func setStatus(_ id: UUID, _ s: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = s
    }

    private func finish(_ id: UUID, _ result: Result<[URL], Error>) {
        completed += 1
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let outs):
            items[i].status = .done
            items[i].out = outs.first
            items[i].outCount = outs.count
            items[i].outBytes = outs.reduce(0) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        case .failure(let err):
            if case ConvertError.skipped = err {
                items[i].status = .skipped
            } else {
                let msg = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
                items[i].status = .failed(msg)
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
