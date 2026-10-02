import AppKit
import SwiftUI

// ============================================================
//  The shared control language of the 21 Generators panel,
//  rebuilt in SwiftUI. Grid inside a 411px panel:
//  24 | 122 | 141 | 3 | 78 | 43
// ============================================================

/// The little downward caret used by sections and selects.
struct Caret: View {
    var size: CGFloat = 9
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0.4 / 9 * size, y: 2.6 / 9 * size))
            p.addLine(to: CGPoint(x: 8.6 / 9 * size, y: 2.6 / 9 * size))
            p.addLine(to: CGPoint(x: 4.5 / 9 * size, y: 8.1 / 9 * size))
            p.closeSubpath()
        }
        .fill(.white)
        .frame(width: size, height: size)
    }
}

// MARK: - rows

struct PRow<Content: View>: View {
    var label: String? = nil
    var top: CGFloat = 0
    var labelWidth: CGFloat = L.labelW
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            if let label {
                Text(label)
                    .font(F.medium(F.ui))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(height: L.rowH)
        .padding(.leading, L.labelX)
        .padding(.trailing, L.rowPadRight)
        .padding(.top, top)
    }
}

/// Full-bleed row: 346pt wide at x=23.
struct PWideRow<Content: View>: View {
    var top: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: L.wideW)
            .padding(.leading, L.labelX)
            .padding(.top, top)
    }
}

struct PRule: View {
    var top: CGFloat = 30
    var body: some View {
        Rectangle()
            .fill(P.rule)
            .frame(height: 1)
            .padding(.leading, L.labelX)
            .padding(.trailing, L.rowPadRight)
            .padding(.top, top)
    }
}

struct PSection: View {
    let title: String
    @Binding var open: Bool
    var top: CGFloat = 17

    var body: some View {
        Button {
            withAnimation(M.easeOut) { open.toggle() }
        } label: {
            HStack(spacing: 7) {
                Caret().rotationEffect(.degrees(open ? 0 : -90))
                Text(title).font(F.medium(F.ui)).foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .frame(height: L.rowH)
            .padding(.leading, L.labelX)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, top)
    }
}

// MARK: - slider

struct PSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var enabled: Bool = true

    @State private var hover = false
    @State private var dragging = false

    private var t: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    var body: some View {
        let fill = L.knob + t * (L.trackW - L.knob)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 15)
                .fill(hover || dragging ? P.trackHover : P.track)
            RoundedRectangle(cornerRadius: 15)
                .fill(.white)
                .frame(width: fill)
            Circle()
                .fill(.white)
                .frame(width: L.knob, height: L.knob)
                .offset(x: fill - L.knob)
        }
        .frame(width: L.trackW, height: L.rowH)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { if enabled { hover = $0 } }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else { return }
                    dragging = true
                    set(from: g.location.x)
                }
                .onEnded { _ in dragging = false }
        )
        .animation(M.easeOut, value: hover)
    }

    private func set(from x: CGFloat) {
        let raw = min(1, max(0, (x - L.knob / 2) / (L.trackW - L.knob)))
        let next = range.lowerBound + Double(raw) * (range.upperBound - range.lowerBound)
        value = min(range.upperBound, max(range.lowerBound, (next / step).rounded() * step))
    }
}

// MARK: - numeric field

struct PValue: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var suffix: String = ""
    var enabled: Bool = true
    var width: CGFloat = L.valueW

    @State private var text: String = ""
    @State private var editing = false
    @State private var hover = false
    @FocusState private var focused: Bool

    private var shown: String {
        let r = (value * 100).rounded() / 100
        return r == r.rounded() ? "\(Int(r))\(suffix)" : "\(r)\(suffix)"
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(F.medium(F.ui))
            .foregroundStyle(.white)
            .focused($focused)
            .disabled(!enabled)
            .frame(width: width, height: L.rowH)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(hover || focused ? P.valueHover : P.track)
            )
            .opacity(enabled ? 1 : 0.4)
            .onHover { if enabled { hover = $0 } }
            .onAppear { text = shown }
            // follow the value whenever it moves for any reason other than the
            // keystrokes in this field — the slider beside it included, even
            // while the caret is still sitting here
            .onChange(of: value) { _, now in
                guard parse(text) != now else { return }
                text = focused ? shown.replacingOccurrences(of: suffix, with: "") : shown
            }
            .onChange(of: focused) { _, now in
                if now { text = shown.replacingOccurrences(of: suffix, with: "") }
                else { commit() }
            }
            // keep the bound value in step with every keystroke rather than
            // waiting for Return or for focus to move: otherwise typing a
            // number and going straight to a button races the commit and the
            // old value is what gets used
            .onChange(of: text) { _, now in
                guard focused else { return }
                if let n = parse(now) { value = n }
            }
            .onSubmit { commit(); focused = false }
            .animation(M.easeOut, value: hover)
    }

    private func parse(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: ",", with: ".")
            .filter { "0123456789.-".contains($0) }
        guard let n = Double(cleaned) else { return nil }
        return min(range.upperBound, max(range.lowerBound, (n / step).rounded() * step))
    }

    private func commit() {
        if let n = parse(text) { value = n }
        text = shown
    }
}

/// Read-only twin of PValue, for values the app computes.
struct PReadout: View {
    let text: String
    var width: CGFloat = L.valueW
    var body: some View {
        Text(text)
            .font(F.medium(F.ui))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: L.rowH)
            .background(RoundedRectangle(cornerRadius: 15).fill(P.track))
    }
}

// MARK: - toggle

struct PToggle: View {
    @Binding var isOn: Bool
    var width: CGFloat = L.valueW
    var enabled: Bool = true
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(M.easeOut) { isOn.toggle() }
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 15)
                    .fill(isOn ? (hover ? Color(hex: 0xF0F0F0) : .white)
                               : (hover ? P.valueHover : P.track))
                RoundedRectangle(cornerRadius: 12)
                    .fill(isOn ? P.track : P.control)
                    .frame(width: 24, height: 24)
                    .offset(x: isOn ? width - 27 : 3)
            }
            .frame(width: width, height: L.rowH)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { if enabled { hover = $0 } }
        .animation(M.easeOut, value: hover)
    }
}

// MARK: - select

struct PSelect: View {
    @Binding var index: Int
    let options: [String]
    var width: CGFloat = L.selectW
    var enabled: Bool = true
    var align: Alignment = .trailing

    @State private var open = false
    @State private var hover = false
    @State private var hovered: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(M.easeOut) { open.toggle() }
            } label: {
                ZStack(alignment: .leading) {
                    Caret()
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .padding(.leading, 15)
                    Text(options.indices.contains(index) ? options[index] : "")
                        .font(F.regular(F.ui))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: align)
                        .padding(.leading, 30)
                        .padding(.trailing, 25)
                }
                .frame(width: width, height: L.rowH)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(spacing: 0) {
                    ForEach(options.indices, id: \.self) { i in
                        Button {
                            index = i
                            withAnimation(M.easeOut) { open = false }
                        } label: {
                            ZStack(alignment: .top) {
                                Rectangle().fill(P.panel).frame(height: 1)
                                    .padding(.leading, 15).padding(.trailing, 18)
                                Text(options[i])
                                    .font(F.regular(F.ui))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: align)
                                    .padding(.leading, 15)
                                    .padding(.trailing, 25)
                                    .frame(height: 31)
                            }
                            .frame(width: width, height: 31)
                            .background(hovered == i ? Color.white.opacity(0.13) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                    }
                }
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: width)
        .background(hover ? Color(hex: 0x838383) : P.control)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { if enabled { hover = $0 } }
        .animation(M.easeOut, value: hover)
        .zIndex(open ? 10 : 0)
    }
}

// MARK: - pills & buttons

struct PPills: View {
    @Binding var index: Int
    let options: [String]
    var top: CGFloat = 0

    var body: some View {
        HStack(spacing: L.pillGap) {
            ForEach(options.indices, id: \.self) { i in
                PillButton(title: options[i], on: index == i) { index = i }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, L.labelX)
        .padding(.trailing, L.rowPadRight)
        .padding(.top, top)
    }
}

private struct PillButton: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(F.medium(F.ui))
                .foregroundStyle(on ? P.control : .white)
                .frame(width: L.pillW, height: L.pillH)
                .background(
                    Capsule().fill(on ? Color.white : (hover ? P.ctrlHover : P.control))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(M.easeOut, value: hover)
    }
}

struct PButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(F.regular(F.ui))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: L.rowH)
                .background(Capsule().fill(hover && enabled ? P.ctrlHover : P.control))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .animation(M.easeOut, value: hover)
    }
}

// MARK: - segmented

struct Seg: View {
    @Binding var index: Int
    let options: [String]
    var width: CGFloat
    var height: CGFloat = L.barH

    var body: some View {
        let inset: CGFloat = 5
        let itemW = (width - inset * 2) / CGFloat(max(1, options.count))
        ZStack(alignment: .leading) {
            Capsule().fill(P.ink)
            RoundedRectangle(cornerRadius: (height - inset * 2) / 2)
                .fill(P.segActive)
                .frame(width: itemW, height: height - inset * 2)
                .offset(x: inset + itemW * CGFloat(index))
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    Button { withAnimation(M.easeOutSlow) { index = i } } label: {
                        Text(options[i])
                            .font(F.medium(F.ui))
                            .foregroundStyle(.white)
                            .opacity(index == i ? 1 : 0.55)
                            .frame(width: itemW, height: height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, inset)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - colour swatch

/// Keeps the shared NSColorPanel's target alive for as long as the swatch is.
private final class ColorPanelProxy: NSObject {
    /// the panel remembers where it was dragged; only place it the first time
    static var placed = false
    var onChange: ((NSColor) -> Void)?
    @objc func changed(_ sender: NSColorPanel) { onChange?(sender.color) }
}

/// Opens the system colour panel. The SwiftUI ColorPicker draws its own well,
/// which will not sit inside a 78x30 pill, so this is a plain button that
/// drives NSColorPanel directly.
struct PSwatch: View {
    @Binding var color: Color
    var width: CGFloat = L.valueW
    var enabled: Bool = true

    @State private var proxy = ColorPanelProxy()
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            RoundedRectangle(cornerRadius: 15)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(.white.opacity(hover ? 0.45 : 0.14), lineWidth: hover ? 2 : 1)
                )
                .frame(width: width, height: L.rowH)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { if enabled { hover = $0 } }
        .animation(M.easeOut, value: hover)
    }

    private func open() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(color)
        proxy.onChange = { color = Color(nsColor: $0) }
        panel.setTarget(proxy)
        panel.setAction(#selector(ColorPanelProxy.changed(_:)))
        if !ColorPanelProxy.placed {
            panel.center()
            ColorPanelProxy.placed = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
