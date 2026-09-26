import AVFoundation
import Foundation
import UniformTypeIdentifiers

// ============================================================
//  Video. Everything goes through AVAssetExportSession, so the
//  hardware encoders do the work and Apple's own code keeps
//  audio in sync, carries rotation and handles timecode.
// ============================================================

enum MediaKind: Int { case image = 0, video = 1 }

// MARK: - choices

struct VideoContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let ext: String
    let fileType: AVFileType
    /// ProRes only lives in QuickTime
    let takesProRes: Bool
}

enum VideoCodec: Int, CaseIterable, Identifiable {
    case copy, h264, hevc, prores422, prores4444
    var id: Int { rawValue }

    var name: String {
        switch self {
        case .copy:       return "Copy Streams"
        case .h264:       return "H.264"
        case .hevc:       return "HEVC"
        case .prores422:  return "ProRes 422"
        case .prores4444: return "ProRes 4444"
        }
    }

    /// short form for the queue badge
    var badge: String {
        switch self {
        case .copy:       return "copy"
        case .h264:       return "H.264"
        case .hevc:       return "HEVC"
        case .prores422:  return "ProRes"
        case .prores4444: return "4444"
        }
    }

    var isProRes: Bool { self == .prores422 || self == .prores4444 }

    /// sizes the system actually has presets for; ProRes and copy keep the source size
    var sizes: [VideoSize] {
        switch self {
        case .h264: return VideoSize.allCases
        case .hevc: return [.source, .uhd, .fhd]
        default:    return []
        }
    }
}

/// The presets are ceilings, never targets: a 720p clip stays 720p under the
/// 1080p preset. The labels say "max" for that reason.
enum VideoSize: Int, CaseIterable, Identifiable {
    case source, uhd, fhd, hd, qhd, sd
    var id: Int { rawValue }

    var name: String {
        switch self {
        case .source: return "Source"
        case .uhd:    return "3840 × 2160"
        case .fhd:    return "1920 × 1080"
        case .hd:     return "1280 × 720"
        case .qhd:    return "960 × 540"
        case .sd:     return "640 × 480"
        }
    }
}

enum VideoFormats {
    static let containers: [VideoContainer] = [
        .init(id: "mov", name: "MOV", ext: "mov", fileType: .mov, takesProRes: true),
        .init(id: "mp4", name: "MP4", ext: "mp4", fileType: .mp4, takesProRes: false),
        .init(id: "m4v", name: "M4V", ext: "m4v", fileType: .m4v, takesProRes: false),
    ]

    static func codecs(for c: VideoContainer) -> [VideoCodec] {
        c.takesProRes ? VideoCodec.allCases : [.copy, .h264, .hevc]
    }

    /// Everything AVFoundation on this Mac will open, as UTTypes.
    private static let readable: [UTType] = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

    /// A movie AVFoundation can open, or — with the bundled ffmpeg — one of the
    /// containers macOS never learned (MKV, WebM, FLV, WMV…). Audio-only files
    /// are left out on purpose.
    static func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if FFmpeg.available, FFmpeg.extraExtensions.contains(ext) { return true }
        guard let t = UTType(filenameExtension: ext),
              t.conforms(to: .movie) || t.conforms(to: .video)
        else { return false }
        return readable.contains { t.conforms(to: $0) }
    }
}

struct VideoOptions {
    var container: VideoContainer = VideoFormats.containers[0]
    var codec: VideoCodec = .h264
    var size: VideoSize = .source
    var keepAudio: Bool = true
    var destination: Destination = .beside
    var folder: URL? = nil
    var onExists: OnExists = .rename

    var preset: String {
        switch codec {
        case .copy:       return AVAssetExportPresetPassthrough
        case .prores422:  return AVAssetExportPresetAppleProRes422LPCM
        case .prores4444: return AVAssetExportPresetAppleProRes4444LPCM
        case .hevc:
            switch size {
            case .uhd: return AVAssetExportPresetHEVC3840x2160
            case .fhd: return AVAssetExportPresetHEVC1920x1080
            default:   return AVAssetExportPresetHEVCHighestQuality
            }
        case .h264:
            switch size {
            case .source: return AVAssetExportPresetHighestQuality
            case .uhd:    return AVAssetExportPreset3840x2160
            case .fhd:    return AVAssetExportPreset1920x1080
            case .hd:     return AVAssetExportPreset1280x720
            case .qhd:    return AVAssetExportPreset960x540
            case .sd:     return AVAssetExportPreset640x480
            }
        }
    }
}

enum VideoError: LocalizedError {
    case unreadable
    case noVideo
    case undecodable(String)
    case incompatible(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:          return "Can’t read"
        case .noVideo:             return "No video track"
        case .undecodable(let c):  return VideoError.legacy(c)
        case .incompatible(let s): return s
        case .failed(let s):       return s
        }
    }

    /// Shown in the queue as soon as such a file is added, not only after Start.
    static func legacy(_ codec: String) -> String {
        "\(codec.isEmpty ? "This codec" : codec) — macOS no longer decodes it"
    }
}

// MARK: - probing

struct VideoProbe: Sendable {
    var w = 0
    var h = 0
    var seconds: Double = 0
    var fps: Double = 0
    var codec = ""
    var container = ""
    var hasAudio = false
    /// false for codecs macOS dropped (Sorenson, Cinepak, Indeo…): the file
    /// opens, the sound plays, the picture can't be decoded
    var decodable = true
    /// Hz, when the probe could tell; sizes the AAC bitrate on the ffmpeg path
    var audioRate = 0
}

enum VideoConverter {

    static func probe(_ url: URL) async -> VideoProbe? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }

        var p = VideoProbe()
        p.container = url.pathExtension.uppercased()

        if let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            // a phone shoots landscape and marks it as rotated; report what you see
            let shown = size.applying(transform)
            p.w = Int(abs(shown.width).rounded())
            p.h = Int(abs(shown.height).rounded())
        }
        if let d = try? await asset.load(.duration), d.isNumeric { p.seconds = d.seconds }
        if let r = try? await track.load(.nominalFrameRate) { p.fps = Double(r) }
        if let f = try? await track.load(.formatDescriptions).first {
            p.codec = codecName(CMFormatDescriptionGetMediaSubType(f))
        }
        p.decodable = (try? await track.load(.isDecodable)) ?? true
        p.hasAudio = !((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty ?? true)
        return p
    }

    static func codecName(_ code: FourCharCode) -> String {
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
        switch fourCC {
        case "avc1", "avc3":           return "H.264"
        case "hvc1", "hev1":           return "HEVC"
        case "apco":                   return "ProRes Proxy"
        case "apcs":                   return "ProRes LT"
        case "apcn":                   return "ProRes 422"
        case "apch":                   return "ProRes HQ"
        case "ap4h":                   return "ProRes 4444"
        case "ap4x":                   return "ProRes XQ"
        case "jpeg", "mjpa", "mjpb":   return "Motion JPEG"
        case "mp4v":                   return "MPEG-4"
        case "av01":                   return "AV1"
        case "vp09":                   return "VP9"
        case "SVQ1":                   return "Sorenson Video"
        case "SVQ3":                   return "Sorenson Video 3"
        case "cvid":                   return "Cinepak"
        case "rpza":                   return "Apple Video"
        case "smc ":                   return "Apple Graphics"
        case "rle ":                   return "Animation"
        case "IV32", "IV41", "IV50":   return "Indeo"
        default:                       return fourCC.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    // MARK: conversion

    static func convert(
        _ url: URL,
        options o: VideoOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { throw VideoError.unreadable }
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              !videoTracks.isEmpty
        else { throw VideoError.noVideo }

        // a codec macOS dropped can't be re-encoded, and copying it just makes
        // another file nothing can play — say so instead of trying
        for track in videoTracks where (try? await track.load(.isDecodable)) == false {
            let code = (try? await track.load(.formatDescriptions).first)
                .map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
            throw VideoError.undecodable(code)
        }

        // dropping audio means building a composition of the picture alone
        let source: AVAsset = o.keepAudio ? asset : try await pictureOnly(asset, videoTracks)

        let fileType = o.container.fileType
        let sourceCodec = (try? await videoTracks[0].load(.formatDescriptions).first)
            .map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
        guard await AVAssetExportSession.compatibility(
            ofExportPreset: o.preset, with: source, outputFileType: fileType
        ) else {
            throw VideoError.incompatible(incompatibility(o, source: sourceCodec))
        }
        guard let session = AVAssetExportSession(asset: source, presetName: o.preset) else {
            throw VideoError.incompatible(incompatibility(o, source: sourceCodec))
        }
        session.shouldOptimizeForNetworkUse = o.container.fileType != .mov

        let dst = try Converter.outputURL(
            for: url, ext: o.container.ext,
            destination: o.destination, folder: o.folder, onExists: o.onExists
        )

        let watch = Task {
            for await state in session.states(updateInterval: 0.15) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watch.cancel() }

        do {
            try await session.export(to: dst, as: fileType)
        } catch {
            try? FileManager.default.removeItem(at: dst)
            throw VideoError.failed(error.localizedDescription)
        }
        progress(1)
        return dst
    }

    /// Picture only, rotation and all.
    private static func pictureOnly(_ asset: AVURLAsset, _ tracks: [AVAssetTrack]) async throws -> AVAsset {
        let comp = AVMutableComposition()
        let duration = try await asset.load(.duration)
        for track in tracks {
            guard let t = comp.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try t.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            // without this a portrait phone clip comes out lying on its side
            t.preferredTransform = try await track.load(.preferredTransform)
        }
        return comp
    }

    /// Says what to change rather than just that it failed. Only reached once
    /// the picture is known to be decodable, so the clash really is between
    /// the stream and the container.
    private static func incompatibility(_ o: VideoOptions, source: String) -> String {
        if o.codec.isProRes && !o.container.takesProRes { return "ProRes needs MOV" }
        if o.codec == .copy {
            let what = source.isEmpty ? "these streams" : source
            return "\(what) can’t be copied into \(o.container.name) — pick a codec"
        }
        return "macOS won’t export this file as \(o.codec.name) in \(o.container.name)"
    }
}

enum Timecode {
    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
