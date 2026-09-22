import SwiftUI

// ============================================================
//  Scrolling with the app's own handle instead of the system
//  overlay scrollbar: no groove, no gutter, just a thumb lying
//  on whatever is behind it.
// ============================================================

/// Reports the height of whatever it is attached to. Preference keys do not
/// cross a `.background` boundary, so the proxy is read directly instead.
private struct HeightReader: View {
    let onChange: (CGFloat) -> Void
    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { onChange(g.size.height) }
                .onChange(of: g.size.height) { _, h in onChange(h) }
        }
    }
}

struct ScrollArea<Content: View>: View {
    var thumbWidth: CGFloat = 6
    /// distance from the right edge of the region to the thumb
    var thumbInset: CGFloat = 10
    /// Where the thumb's travel starts and ends, measured from the edges of
    /// the region. Give these the content's own top and bottom padding and the
    /// thumb lines up with the first and last row instead of floating into the
    /// rounded corners.
    var trackTop: CGFloat = 16
    var trackBottom: CGFloat = 16
    /// shortest the thumb is allowed to get on very long content
    var minThumb: CGFloat = 34
    var tint: Color = .white
    var idle: Double = 0.20
    var active: Double = 0.42
    @ViewBuilder var content: Content

    // measured on the first layout, so the thumb is correct before anyone
    // has scrolled
    @State private var contentH: CGFloat = 0
    @State private var viewportH: CGFloat = 0
    @State private var offsetY: CGFloat = 0

    @State private var pos = ScrollPosition()
    @State private var grabbed: CGFloat? = nil
    @State private var hover = false

    /// how much content there is beyond the viewport
    private var overflow: CGFloat { max(0, contentH - viewportH) }

    var body: some View {
        ScrollView(.vertical) {
            content.background(HeightReader { contentH = $0 })
        }
        // .hidden still defers to "Always show scroll bars" in System Settings,
        // which draws a legacy track; .never is the hard override
        .scrollIndicators(.never)
        .scrollPosition($pos)
        .background(HeightReader { viewportH = $0 })
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            offsetY = y
        }
        .overlay(alignment: .topTrailing) { handle }
    }

    @ViewBuilder private var handle: some View {
        if overflow > 1, viewportH > trackTop + trackBottom + minThumb {
            let trackH = viewportH - trackTop - trackBottom
            let thumbH = min(trackH, max(minThumb, trackH * viewportH / max(1, contentH)))
            let travel = max(0, trackH - thumbH)
            let t = min(1, max(0, offsetY / overflow))
            // a bare 6pt target is hard to grab, so the hit area is wider than
            // the thumb and the thumb sits in the middle of it
            let pad: CGFloat = 6

            ZStack {
                Color.clear
                RoundedRectangle(cornerRadius: thumbWidth / 2, style: .continuous)
                    .fill(tint.opacity(grabbed != nil ? active : (hover ? active * 0.8 : idle)))
                    .frame(width: thumbWidth)
            }
            .frame(width: thumbWidth + pad * 2, height: thumbH)
            .contentShape(Rectangle())
            .offset(x: -(thumbInset - pad), y: trackTop + travel * t)
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if grabbed == nil { grabbed = offsetY }
                        guard travel > 0, let base = grabbed else { return }
                        let next = base + g.translation.height / travel * overflow
                        pos.scrollTo(y: min(overflow, max(0, next)))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .animation(M.quick, value: hover)
            .animation(M.quick, value: grabbed != nil)
        }
    }
}
