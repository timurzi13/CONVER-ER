import AppKit
import SwiftUI

// ============================================================
//  The shell: a 60pt black header, then the work area all the
//  way to the bottom of the window.
// ============================================================

struct Header: View {
    let title: String
    let count: Int

    var body: some View {
        ZStack {
            P.ink

            // the title and the caption share a baseline; the count keeps the
            // HStack's spacing but is dropped onto the header's own centre line
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .font(F.bold(F.title))
                    .tracking(-0.012 * F.title)
                Spacer(minLength: L.captionGap)
                Text("FILES:")
                    .font(F.bold(F.title))
                    .tracking(-0.012 * F.title)
                Spacer().frame(width: L.captionGap)
                Text("\(count)")
                    .font(F.bold(F.numeral))
                    .tracking(-0.02 * F.numeral)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(M.easeOut, value: count)
                    .offset(y: HeaderMetrics.countNudge)
            }
            .foregroundStyle(.white)
            .padding(.leading, L.leftW + L.edge)
            .padding(.trailing, L.edge)
            .offset(y: HeaderMetrics.titleNudge)
        }
        .frame(height: L.headerH)
    }
}

/// A black band closing the window, with the credit line set small at the
/// trailing end.
struct Footer: View {
    private static let credit = "All Right Belongs to People™, 2026 Created by "
    private static let studio = "[BUR0U3]+"
    private static let studioURL = URL(string: "https://www.instagram.com/burou3_/")!

    var body: some View {
        ZStack {
            P.ink
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(Self.credit)
                    .foregroundStyle(P.footerText)
                StudioLink(title: Self.studio, url: Self.studioURL)
            }
            .font(F.regular(F.credit))
            .padding(.trailing, L.edge)
        }
        .frame(height: L.footerH)
    }
}

private struct StudioLink: View {
    let title: String
    let url: URL
    @State private var hover = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .foregroundStyle(hover ? Color.white : P.footerText)
                .underline(hover)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(url.absoluteString)
        .animation(M.easeOut, value: hover)
    }
}

/// The rounded settings panel. Fills the height it is given; the caller decides
/// what sits at the top and what is pinned to the bottom.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: L.panelW)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(P.panel)
            .clipShape(RoundedRectangle(cornerRadius: L.panelRadius, style: .continuous))
    }
}

/// Black pill that floats over the work area.
struct PillBar<Content: View>: View {
    var width: CGFloat? = nil
    var height: CGFloat = L.barH
    /// the export bar's first cell is a text label that carries its own
    /// width, so that bar asks for no padding on the left
    var padLeading: CGFloat = 5
    var padTrailing: CGFloat = 5
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .padding(.leading, padLeading)
        .padding(.trailing, padTrailing)
        .frame(width: width, height: height)
        .background(Capsule().fill(P.ink))
    }
}

/// The 42x42 round button used inside pill bars.
struct RoundBtn: View {
    let system: String
    var on: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(on ? Color.white : (hover ? P.ctrlHover : P.segIdle))
                Image(systemName: system)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(on ? P.segIdle : .white)
            }
            .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
        .animation(M.easeOut, value: hover)
    }
}

/// 102x42 pill button, the export-bar unit.
struct XBButton: View {
    let title: String
    var live: Bool = false
    /// what a live button says under the pointer, e.g. "Stop" over "42%"
    var liveHover: String? = nil
    var enabled: Bool = true
    var width: CGFloat = 102
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(live && hover ? (liveHover ?? title) : title)
                .font(F.medium(F.ui))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: width, height: 42)
                .background(
                    Capsule().fill(live ? P.accent : (hover && enabled ? P.xbBtnHover : P.xbBtn))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || live ? 1 : 0.75)
        .onHover { hover = $0 }
        .animation(M.easeOut, value: hover)
        .animation(M.easeOut, value: live)
    }
}
