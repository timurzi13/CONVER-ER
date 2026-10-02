import AppKit
import SwiftUI

// ============================================================
//  The work area: the queue board plus the bars floating over it.
// ============================================================

struct Stage: View {
    @Bindable var m: Model
    @State private var targeted = false

    /// the queue's own top and bottom padding; the scroll thumb follows it
    private let listPad: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            P.colRight

            board
                .padding(.top, L.barTop)
                .padding(.horizontal, L.edge)
                .padding(.bottom, L.barBottom + L.barH + L.gap)

            // export bar, bottom-left
            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    exportBar
                    Spacer(minLength: 0)
                    utilityBar
                }
            }
            .padding(.leading, L.exportLeft)
            .padding(.trailing, L.barRight)
            .padding(.bottom, L.barBottom)
        }
        .dropDestination(for: URL.self) { urls, _ in
            m.add(urls)
            return true
        } isTargeted: { on in
            withAnimation(M.easeOut) { targeted = on }
        }
    }

    // MARK: board

    private var board: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(P.ink)
            if m.visible.isEmpty {
                empty
            } else {
                list
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(P.accent, lineWidth: targeted ? 3 : 0)
        )
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text(targeted ? "Release to add" : (m.mode == .image ? "Drop images here" : "Drop videos here"))
                .font(F.medium(26.5))
                .tracking(-0.012 * 26.5)
                .foregroundStyle(targeted ? P.accent : Color(hex: 0x707070))
            Text(m.mode == .image
                 ? "JP2 · PDF · PNG · JPEG · TIFF · HEIC · AVIF · PSD · RAW · WebP · and everything else ImageIO reads"
                 : (FFmpeg.available
                    ? "MOV · MP4 · MKV · WebM · AVI · FLV · WMV · MPEG · and old QuickTime codecs too"
                    : "MOV · MP4 · M4V · AVI · MPEG · DV · 3GP · and everything else AVFoundation plays"))
                .font(F.regular(F.ui))
                .foregroundStyle(Color(hex: 0x4E4E4E))
        }
        .animation(M.easeOut, value: targeted)
    }

    private var list: some View {
        ScrollArea(thumbInset: 12, trackTop: listPad, trackBottom: listPad) {
            LazyVStack(spacing: 0) {
                ForEach(m.visible) { item in
                    Row(item: item, target: m.targetName, m: m)
                    if item.id != m.visible.last?.id {
                        Rectangle().fill(Color(hex: 0x1E1E1E)).frame(height: 1)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.vertical, listPad)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: bars

    private var exportBar: some View {
        PillBar(width: L.exportBarW, padLeading: 0, padTrailing: 5) {
            Text("Convert to")
                .font(F.regular(F.ui))
                .foregroundStyle(P.xbLabel)
                .frame(width: 101)
            XBButton(title: m.targetName, enabled: !m.running) {
                m.cycleTarget()
            }
            // while running the same button shows progress and, under the
            // pointer, offers to stop
            XBButton(
                title: m.stopping ? "Stopping" : (m.running ? "\(Int(m.progress * 100))%" : "Start"),
                live: m.running,
                liveHover: m.stopping ? nil : "Stop",
                enabled: m.running ? !m.stopping : m.hasWork
            ) {
                if m.running { m.stop() } else { m.run() }
            }
        }
    }

    private var utilityBar: some View {
        PillBar {
            RoundBtn(system: "folder", enabled: m.visible.contains { $0.out != nil }) {
                if let done = m.visible.last(where: { $0.out != nil }) { m.reveal(done) }
            }
            // the bin can't act during a run, so its slot becomes Stop
            if m.running {
                RoundBtn(system: "stop.fill", enabled: !m.stopping) { m.stop() }
                    .help("Stop")
            } else {
                RoundBtn(system: "trash", enabled: !m.visible.isEmpty) {
                    withAnimation(M.easeOut) { m.clear() }
                }
            }
        }
    }
}

// MARK: - one queued file

private struct Row: View {
    let item: Item
    let target: String
    @Bindable var m: Model
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            StatusDot(status: item.blocked != nil ? .failed(item.blocked!) : item.status)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(F.medium(F.ui))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let why = item.blocked {
                    Text(why).font(F.regular(12)).foregroundStyle(P.bad).lineLimit(1)
                } else if case .failed(let why) = item.status {
                    Text(why).font(F.regular(12)).foregroundStyle(P.bad).lineLimit(1)
                } else if item.status == .skipped {
                    Text("Already there — skipped").font(F.regular(12)).foregroundStyle(Color(hex: 0x8A8A8A))
                } else if item.isPDF || outLine != nil {
                    Text(imageLine)
                        .font(F.regular(12))
                        .monospacedDigit()
                        .foregroundStyle(heavy ? P.warn : Color(hex: 0x8A8A8A))
                        .lineLimit(1)
                } else if item.isVideo, !item.codec.isEmpty {
                    Text(videoLine)
                        .font(F.regular(12))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: 0x8A8A8A))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Badge(text: item.kind.isEmpty ? "…" : item.kind, dim: true)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: 0x5A5A5A))
                Badge(text: targetBadge, dim: item.status != .done)
            }
            .frame(width: 168, alignment: .leading)

            Text(dimsText)
                .font(F.regular(14))
                .monospacedDigit()
                .foregroundStyle(heavy ? P.warn : (outPixels != nil ? Color(hex: 0xD6D6D6) : Color(hex: 0x9A9A9A)))
                .lineLimit(1)
                .frame(width: 132, alignment: .trailing)
                .help(outPixels != nil
                      ? "Comes out at this size. Source: \(Fmt.px(item.w, item.h))\(item.isPDF ? " pt" : " px")"
                      : "")

            Text(sizeText)
                .font(F.regular(14))
                .monospacedDigit()
                .foregroundStyle(item.status == .done ? Color(hex: 0xD6D6D6) : Color(hex: 0x9A9A9A))
                .frame(width: 128, alignment: .trailing)

            Button {
                withAnimation(M.easeOut) { m.remove(item.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: 0x8A8A8A))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(hex: 0x242424)))
            }
            .buttonStyle(.plain)
            .opacity(hover && !m.running ? 1 : 0)
            .disabled(m.running)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(hover ? Color.white.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { m.reveal(item) }
        .animation(M.quick, value: hover)
    }

    /// codec · length · frame rate, the three things you check on a clip
    private var videoLine: String {
        var parts = [item.codec, Timecode.short(item.seconds)]
        if item.fps > 0 { parts.append(String(format: item.fps.rounded() == item.fps ? "%.0f fps" : "%.2f fps", item.fps)) }
        if !item.hasAudio { parts.append("no audio") }
        if item.viaFFmpeg { parts.append("via FFmpeg") }
        return parts.joined(separator: " · ")
    }

    private var targetBadge: String {
        // a video's container says little on its own; the codec is the decision
        if item.isVideo { return "\(target) · \(m.effectiveCodec.badge)" }
        // PDFs fan out into one file per page, so say how many are coming
        if item.status == .done, item.outCount > 1 { return "\(target) ×\(item.outCount)" }
        if item.isPDF, m.pdfModeIndex == 0, item.pages > 1 { return "\(target) ×\(item.pages)" }
        return target
    }

    // MARK: what the image side will produce

    /// the predicted output size, when it differs from what goes in
    private var outPixels: (w: Int, h: Int)? {
        guard let p = m.predicted(item) else { return nil }
        if !item.isPDF, p.w == item.w, p.h == item.h { return nil }
        return (p.w, p.h)
    }

    /// what comes out, in pixels, where that's known; otherwise what goes in
    private var dimsText: String {
        if let o = outPixels { return "\(o.w) × \(o.h) px" }
        return item.isPDF ? "\(Fmt.px(item.w, item.h)) pt" : Fmt.px(item.w, item.h)
    }

    private var outLine: String? {
        guard let o = outPixels else { return nil }
        let mp = Double(o.w * o.h) / 1_000_000
        return mp >= 10 ? String(format: "%.0f MP", mp) : String(format: "%.1f MP", mp)
    }

    private var imageLine: String {
        var parts: [String] = []
        if item.isPDF {
            parts.append(item.pages == 1 ? "1 page" : "\(item.pages) pages")
            parts.append(item.pdfDPI > 0 ? "scan \(item.pdfDPI) dpi" : "vector")
            if let p = m.predicted(item), item.pdfDPI > 0, Double(p.dpi) > Double(item.pdfDPI) * 1.15 {
                parts.append("upscaled to \(p.dpi)")
            }
        }
        if let out = outLine { parts.append(out) }
        return parts.joined(separator: " · ")
    }

    /// past ~60 MP a page gets slow to draw and heavy to keep in memory
    private var heavy: Bool {
        guard let p = m.predicted(item) else { return false }
        return p.w * p.h > 60_000_000
    }

    private var sizeText: String {
        if item.isPDF, item.status == .working {
            return "\(Int((item.progress * 100).rounded()))%"
        }
        if item.isVideo, item.status == .working {
            return "\(Int((item.progress * 100).rounded()))%"
        }
        if item.status == .done, item.outBytes > 0 {
            return "\(Fmt.bytes(item.bytes)) → \(Fmt.bytes(item.outBytes))"
        }
        return Fmt.bytes(item.bytes)
    }
}

private struct Badge: View {
    let text: String
    var dim: Bool = false
    var body: some View {
        Text(text)
            .font(F.medium(12))
            .foregroundStyle(dim ? Color(hex: 0x9A9A9A) : P.ink)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(dim ? Color(hex: 0x242424) : Color.white))
            .fixedSize()
    }
}

private struct StatusDot: View {
    let status: Status
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(fill).frame(width: 26, height: 26)
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(status == .done ? P.ink : .white)
            }
        }
        .opacity(status == .working && pulse ? 0.45 : 1)
        .onAppear {
            if status == .working {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
        .animation(M.easeOut, value: status)
    }

    private var fill: Color {
        switch status {
        case .queued:  return Color(hex: 0x2E2E2E)
        case .working: return P.accent
        case .done:    return .white
        case .skipped: return Color(hex: 0x2E2E2E)
        case .failed:  return P.bad
        }
    }

    private var glyph: String? {
        switch status {
        case .queued:  return nil
        case .working: return "arrow.triangle.2.circlepath"
        case .done:    return "checkmark"
        case .skipped: return "minus"
        case .failed:  return "exclamationmark"
        }
    }
}
