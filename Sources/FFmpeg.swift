import Foundation

// ============================================================
//  The bundled ffmpeg (Contents/Helpers/ffmpeg). It only steps
//  in where macOS can't: codecs Apple dropped (Sorenson, Cinepak,
//  Indeo…) and containers it never opened (MKV, WebM, FLV, WMV…).
//  Everything else stays on AVFoundation.
// ============================================================

enum FFmpeg {

    /// The helper inside the app; CONVERER_FFMPEG points elsewhere for tests.
    static let url: URL? = {
        if let override = ProcessInfo.processInfo.environment["CONVERER_FFMPEG"] {
            return URL(fileURLWithPath: override)
        }
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: u.path) else { return nil }
        return runnable(u)
    }()

    /// A browser quarantines every file in a downloaded zip. Approving the app
    /// on first launch ("Open Anyway") clears the app, not the helper inside
    /// it, and macOS then refuses to exec the helper. The app has already been
    /// allowed to run, so it clears the flag from its own helper. If the bundle
    /// is read-only — macOS runs an app that hasn't been moved out of Downloads
    /// from a translocated, read-only copy — a copy in Application Support is
    /// used instead.
    private static func runnable(_ helper: URL) -> URL {
        let flag = "com.apple.quarantine"
        guard getxattr(helper.path, flag, nil, 0, 0, 0) >= 0 else { return helper }
        if removexattr(helper.path, flag, 0) == 0 { return helper }

        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return helper
        }
        let dir = support.appendingPathComponent("CONVER+ER", isDirectory: true)
        let copy = dir.appendingPathComponent("ffmpeg")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // reuse the copy while it matches this build of the app
        let size = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1 }
        if size(copy) != size(helper) {
            if fm.fileExists(atPath: copy.path) {
                chflags(copy.path, 0)
                try? fm.removeItem(at: copy)
            }
            try? fm.copyItem(at: helper, to: copy)
        }
        // a copy inherits the original's xattrs and file flags; ours, so both go
        chflags(copy.path, 0)
        guard removexattr(copy.path, flag, 0) == 0 || getxattr(copy.path, flag, nil, 0, 0, 0) < 0 else {
            return helper
        }
        return fm.isExecutableFile(atPath: copy.path) ? copy : helper
    }

    static var available: Bool { url != nil }

    /// Containers macOS won't open at all but ffmpeg will.
    static let extraExtensions: Set<String> = [
        "mkv", "webm", "flv", "f4v", "wmv", "asf", "ogv", "ogm",
        "divx", "xvid", "rm", "rmvb", "vob", "mxf", "nut",
    ]

    // MARK: probe

    /// `ffmpeg -i` with no output prints the streams to stderr and exits 1;
    /// that listing is all a probe needs.
    static func probe(_ file: URL) async -> VideoProbe? {
        guard let exe = url else { return nil }
        let (_, _, err) = await run(exe, ["-hide_banner", "-nostdin", "-i", file.path])
        return parse(err, container: file.pathExtension.uppercased())
    }

    static func parse(_ text: String, container: String) -> VideoProbe? {
        guard let video = text.split(separator: "\n").first(where: { $0.contains(": Video: ") }) else {
            return nil
        }
        let line = String(video)
        var p = VideoProbe()
        p.container = container

        if let name = first(#": Video: ([A-Za-z0-9_]+)"#, in: line) { p.codec = friendly(name) }
        if let m = groups(#", (\d{2,5})x(\d{2,5})[ ,\[]"#, in: line), m.count == 2 {
            p.w = Int(m[0]) ?? 0
            p.h = Int(m[1]) ?? 0
        }
        if let fps = first(#", ([\d.]+) fps"#, in: line) { p.fps = Double(fps) ?? 0 }
        if let d = groups(#"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, in: text), d.count == 3 {
            p.seconds = (Double(d[0]) ?? 0) * 3600 + (Double(d[1]) ?? 0) * 60 + (Double(d[2]) ?? 0)
        }
        // ffmpeg rotates on decode, so report the picture the way it will come out
        if let r = first(#"rotation of (-?[\d.]+) degrees"#, in: text),
           let deg = Double(r), Int(abs(deg).rounded()) % 180 == 90 {
            swap(&p.w, &p.h)
        }
        if let audio = text.split(separator: "\n").first(where: { $0.contains(": Audio: ") }) {
            p.hasAudio = true
            p.audioRate = Int(first(#", (\d{4,6}) Hz"#, in: String(audio)) ?? "") ?? 0
        }
        p.decodable = true
        return p
    }

    static func friendly(_ name: String) -> String {
        switch name {
        case "h264":                       return "H.264"
        case "hevc":                       return "HEVC"
        case "av1", "libdav1d":            return "AV1"
        case "vp8":                        return "VP8"
        case "vp9":                        return "VP9"
        case "svq1":                       return "Sorenson Video"
        case "svq3":                       return "Sorenson Video 3"
        case "flv1":                       return "Sorenson Spark"
        case "cinepak":                    return "Cinepak"
        case "indeo2", "indeo3", "indeo4", "indeo5": return "Indeo"
        case "mpeg4":                      return "MPEG-4"
        case "msmpeg4v1", "msmpeg4v2", "msmpeg4v3": return "DivX 3"
        case "wmv1", "wmv2", "wmv3":       return "WMV"
        case "vc1":                        return "VC-1"
        case "theora":                     return "Theora"
        case "mpeg1video":                 return "MPEG-1"
        case "mpeg2video":                 return "MPEG-2"
        case "prores":                     return "ProRes"
        case "dnxhd":                      return "DNxHD"
        case "qtrle":                      return "Animation"
        case "rpza":                       return "Apple Video"
        case "smc":                        return "Apple Graphics"
        case "mjpeg":                      return "Motion JPEG"
        case "dvvideo":                    return "DV"
        case "rv10", "rv20", "rv30", "rv40": return "RealVideo"
        default:                           return name.uppercased()
        }
    }

    // MARK: convert

    static func convert(
        _ file: URL,
        probe p: VideoProbe,
        options o: VideoOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let exe = url else { throw VideoError.failed("FFmpeg missing from the app") }

        let dst = try Converter.outputURL(
            for: file, ext: o.container.ext,
            destination: o.destination, folder: o.folder, onExists: o.onExists
        )

        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                    "-progress", "pipe:1", "-nostats",
                    "-i", file.path,
                    // first picture, first sound if there is one; subtitle and
                    // data tracks from MKV would otherwise stop an MP4 cold
                    "-map", "0:v:0"]
        if o.keepAudio { args += ["-map", "0:a:0?"] }
        args += ["-map_metadata", "0"]
        args += videoArgs(o, p)
        args += audioArgs(o, p)
        args += containerArgs(o)
        args.append(dst.path)

        let duration = max(p.seconds, 0.001)
        let (status, _, err) = await run(exe, args) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                progress(min(1, max(0, us / 1_000_000 / duration)))
            } else if line == "progress=end" {
                progress(1)
            }
        }

        guard status == 0 else {
            try? FileManager.default.removeItem(at: dst)
            throw VideoError.failed(explain(err, o, p))
        }
        progress(1)
        return dst
    }

    private static func videoArgs(_ o: VideoOptions, _ p: VideoProbe) -> [String] {
        switch o.codec {
        case .copy:
            return ["-c:v", "copy"]
        case .prores422:
            return ["-c:v", "prores_ks", "-profile:v", "2", "-vendor", "apl0", "-pix_fmt", "yuv422p10le"]
        case .prores4444:
            return ["-c:v", "prores_ks", "-profile:v", "4", "-vendor", "apl0", "-pix_fmt", "yuv444p10le"]
        case .h264, .hevc:
            let (w, h) = fitted(p, o.size)
            let hevc = o.codec == .hevc
            // roughly what Apple's own presets land on: ~0.12 bits a pixel
            // for H.264, a third less for HEVC. The floor only keeps tiny
            // old clips from starving — set it high and a 160×120 file
            // from 2001 comes out twice the size it went in
            let fps = p.fps > 0 ? p.fps : 30
            let bpp = hevc ? 0.08 : 0.12
            let bitrate = Int(min(50_000_000, max(100_000, Double(w * h) * fps * bpp)))
            var a = ["-c:v", hevc ? "hevc_videotoolbox" : "h264_videotoolbox",
                     "-allow_sw", "1", "-b:v", "\(bitrate)", "-pix_fmt", "yuv420p",
                     "-vf", "scale=\(w):\(h),setsar=1"]
            if hevc { a += ["-tag:v", "hvc1"] } else { a += ["-profile:v", "high"] }
            return a
        }
    }

    /// Same rule as the AVFoundation presets: the size is a ceiling, turned to
    /// match the clip, never a target — and 4:2:0 wants even numbers.
    private static func fitted(_ p: VideoProbe, _ size: VideoSize) -> (Int, Int) {
        var w = max(2, p.w), h = max(2, p.h)
        let box: (Int, Int)? = {
            switch size {
            case .source: return nil
            case .uhd: return (3840, 2160)
            case .fhd: return (1920, 1080)
            case .hd:  return (1280, 720)
            case .qhd: return (960, 540)
            case .sd:  return (640, 480)
            }
        }()
        if let (bw, bh) = box {
            let (maxW, maxH) = h > w ? (bh, bw) : (bw, bh)
            let k = min(1, min(Double(maxW) / Double(w), Double(maxH) / Double(h)))
            w = Int((Double(w) * k).rounded())
            h = Int((Double(h) * k).rounded())
        }
        return (max(2, w - w % 2), max(2, h - h % 2))
    }

    private static func audioArgs(_ o: VideoOptions, _ p: VideoProbe) -> [String] {
        guard o.keepAudio else { return ["-an"] }
        switch o.codec {
        case .copy:                     return ["-c:a", "copy"]
        case .prores422, .prores4444:   return ["-c:a", "pcm_s16le"]
        case .h264, .hevc:
            // 22 kHz sound from the QuickTime days has nothing for 160k to keep
            let low = p.audioRate > 0 && p.audioRate <= 24_000
            return ["-c:a", "aac", "-b:a", low ? "96k" : "160k"]
        }
    }

    private static func containerArgs(_ o: VideoOptions) -> [String] {
        o.container.fileType == .mov
            ? ["-f", "mov"]
            : ["-f", "mp4", "-movflags", "+faststart"]
    }

    /// ffmpeg's own last word, trimmed to something that fits under a file name.
    private static func explain(_ err: String, _ o: VideoOptions, _ p: VideoProbe) -> String {
        if o.codec == .copy, err.contains("not currently supported in container")
            || err.contains("Could not find tag for codec") {
            return "\(p.codec.isEmpty ? "These streams" : p.codec) can’t be copied into \(o.container.name) — pick a codec"
        }
        let last = err.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return last.isEmpty ? "FFmpeg couldn’t convert this file" : String(last.prefix(90))
    }

    // MARK: process

    /// Runs the helper, hands every stdout line to `onLine`, keeps the tail of
    /// stderr for error messages.
    private static func run(
        _ exe: URL,
        _ args: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (Int32, String, String) {
        let proc = Process()
        // Stop cancels the task; the process has to be told separately
        return await withTaskCancellationHandler {
            await launch(proc, exe, args, onLine: onLine)
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    private static func launch(
        _ proc: Process,
        _ exe: URL,
        _ args: [String],
        onLine: (@Sendable (String) -> Void)?
    ) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            proc.executableURL = exe
            proc.arguments = args
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err

            let collector = Collector()
            out.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                for line in collector.feedOut(data) { onLine?(line) }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                collector.feedErr(data)
            }
            proc.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                // whatever was still sitting in the pipes
                for line in collector.feedOut(out.fileHandleForReading.readDataToEndOfFile()) { onLine?(line) }
                collector.feedErr(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (p.terminationStatus, "", collector.errText))
            }
            do { try proc.run() } catch {
                cont.resume(returning: (-1, "", error.localizedDescription))
            }
        }
    }

    // MARK: text helpers

    private static func first(_ pattern: String, in s: String) -> String? {
        groups(pattern, in: s)?.first
    }

    private static func groups(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }
}

/// Line-splits stdout and keeps stderr for probes and error messages. Works on
/// bytes and decodes leniently: old QuickTime files carry metadata in legacy
/// encodings (Shift-JIS, MacRoman), and a strict UTF-8 decode would drop the
/// whole chunk — stream listing included. Touched from the pipes' own queues,
/// so it locks.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    /// the start holds the stream listing a probe needs, the end holds the
    /// error a failed run reports; anything past both caps in between is dropped
    private var head = Data()
    private var tail = Data()
    private let headCap = 128 * 1024
    private let tailCap = 32 * 1024

    func feedOut(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
            pending = Data(pending[pending.index(after: nl)...])
        }
        return lines
    }

    func feedErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if head.count < headCap {
            let room = headCap - head.count
            head.append(data.prefix(room))
            if data.count > room { tail.append(data.dropFirst(room)) }
        } else {
            tail.append(data)
        }
        if tail.count > tailCap { tail = Data(tail.suffix(tailCap)) }
    }

    var errText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: head + tail, as: UTF8.self)
    }
}
