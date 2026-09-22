import AppKit
import CoreText
import SwiftUI

@main
struct ConverErApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var m = Model.shared

    var body: some Scene {
        Window("CONVER+ER", id: "main") {
            RootView(m: m)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1360, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { m.pickFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Add Folder…") { m.pickFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Convert") { m.run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(m.running || m.items.isEmpty)
                Button("Clear List") { m.clear() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(m.running || m.items.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ note: Notification) {
        registerBundledFonts()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // macOS restores the shared colour panel if it was open at quit; it
        // should only show when the swatch asks for it
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    /// Files dropped on the Dock icon, or opened with "Open With".
    func application(_ app: NSApplication, open urls: [URL]) {
        Task { @MainActor in Model.shared.add(urls) }
    }

    /// ATSApplicationFontsPath usually does this on its own; registering again
    /// costs nothing and makes the bundle work however it was assembled.
    private func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where ["otf", "ttf"].contains(f.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
        if ProcessInfo.processInfo.environment["CONVERER_DEBUG"] != nil {
            let ok = NSFont(name: "DMSans-Medium", size: 16) != nil
            FileHandle.standardError.write("DM Sans available: \(ok)\n".data(using: .utf8)!)
        }
    }
}

/// Lets the accent header run all the way to the top of the window.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.backgroundColor = NSColor.white
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// ============================================================

struct RootView: View {
    @Bindable var m: Model

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "CONVER+ER", count: m.items.count)

            HStack(spacing: 0) {
                LeftColumn(m: m)
                Stage(m: m)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Footer()
        }
        .frame(minWidth: L.windowMinW, minHeight: L.windowMinH)
        .background(P.paper)
        .background(WindowChrome())
        .ignoresSafeArea(.all, edges: .top)
        .preferredColorScheme(.light)
    }
}

// ============================================================
//  Left column: the settings panel.
// ============================================================

struct LeftColumn: View {
    @Bindable var m: Model

    var body: some View {
        Panel {
            SettingsPanel(m: m)
        }
        .padding(.horizontal, L.leftPadX)
        .padding(.vertical, L.gap)
        .frame(width: L.leftW)
        .frame(maxHeight: .infinity)
        .background(P.colLeft)
    }
}

private struct SettingsPanel: View {
    @Bindable var m: Model

    var body: some View {
        // the sections take the space they need and only scroll once the window
        // is too short for them; the buttons keep their own height whatever
        // happens, so they can never be overlapped
        VStack(alignment: .leading, spacing: 0) {
            ScrollArea(thumbInset: 12, trackTop: L.panelPadTop, trackBottom: L.gap) {
                VStack(alignment: .leading, spacing: 0) {
                    sections
                }
                .frame(width: L.panelW, alignment: .leading)
                .padding(.top, L.panelPadTop)
                .padding(.bottom, L.gap)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                PWideRow {
                    PButton(title: "Add Files…") { m.pickFiles() }
                }
                PWideRow(top: L.rowGap) {
                    PButton(title: "Add Folder…") { m.pickFolder() }
                }
            }
            .padding(.bottom, L.panelPadBottom)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: L.panelW, alignment: .leading)
    }

    @ViewBuilder private var sections: some View {
        // ---- Output ------------------------------------------------------
        PSection(title: "Output", open: $m.outputOpen, top: 0)

        if m.outputOpen {
            SelectRow(label: "Format", index: $m.formatIndex, options: Formats.names, top: L.rowGap)

            if m.format.lossy {
                PRow(label: "Quality", top: L.rowGap) {
                    PSlider(value: $m.quality, range: 1...100)
                    Spacer().frame(width: L.colGap)
                    PValue(value: $m.quality, range: 1...100)
                }
            }

            PPills(index: $m.sizeIndex, options: ["Full", "Scale", "Fit"], top: 14)

            if m.sizeIndex == SizeMode.scale.rawValue {
                PRow(label: "Scale", top: 14) {
                    PSlider(value: $m.scale, range: 5...400, step: 5)
                    Spacer().frame(width: L.colGap)
                    PValue(value: $m.scale, range: 5...400, step: 5, suffix: "%")
                }
            } else if m.sizeIndex == SizeMode.fit.rawValue {
                PRow(label: "Longest Side", top: 14) {
                    PSlider(value: $m.fit, range: 128...8192, step: 16)
                    Spacer().frame(width: L.colGap)
                    PValue(value: $m.fit, range: 128...8192, step: 16)
                }
            }

            // the target can't store transparency, or a PDF page needs paper
            if !m.format.alpha || m.hasPDF {
                PRow(label: "Flatten Onto", top: L.rowGap) {
                    Spacer().frame(width: L.trackW + L.colGap)
                    PSwatch(color: $m.background)
                }
                .help(m.format.alpha
                      ? "A PDF page carries no paper of its own — it is rendered onto this colour."
                      : "\(m.format.name) can’t store transparency — transparent pixels are filled with this colour.")
            }

            PRow(label: "Keep Metadata", top: L.rowGap) {
                Spacer().frame(width: L.trackW + L.colGap)
                PToggle(isOn: $m.keepMetadata)
            }
        }

        // ---- PDF ---------------------------------------------------------
        // only exists while there is a PDF in the queue
        if m.hasPDF {
            PRule(top: 22)
            PSection(title: "PDF", open: $m.pdfOpen, top: 12)

            if m.pdfOpen {
                SelectRow(
                    label: "Pages",
                    index: $m.pdfModeIndex,
                    options: ["All Pages", "Single Page"],
                    top: L.rowGap
                )

                if m.pdfModeIndex == 1 {
                    PRow(label: "Page", top: L.rowGap) {
                        PSlider(value: $m.pdfPage, range: 1...Double(m.maxPDFPages))
                        Spacer().frame(width: L.colGap)
                        PValue(value: $m.pdfPage, range: 1...Double(m.maxPDFPages))
                    }
                    .help("Pages are numbered from 1. The longest document in the queue has \(m.maxPDFPages).")
                }

                // vector stays vector when the target is PDF, so there is
                // nothing to rasterise
                if !m.format.isPDF {
                    PRow(label: "Raster DPI", top: L.rowGap) {
                        PSlider(value: $m.pdfDPI, range: 72...600, step: 6)
                        Spacer().frame(width: L.colGap)
                        PValue(value: $m.pdfDPI, range: 72...600, step: 6)
                    }
                    .help("How finely a page is rendered. 72 dpi is the page's own size; 150–300 suits text.")
                }
            }
        }

        PRule(top: 22)

        // ---- Files -------------------------------------------------------
        PSection(title: "Files", open: $m.filesOpen, top: 12)

        if m.filesOpen {
            SelectRow(
                label: "Save To",
                index: $m.destIndex,
                options: ["Beside Original", "Custom Folder"],
                top: L.rowGap
            )

            if m.destIndex == Destination.folder.rawValue {
                PWideRow(top: L.rowGap) {
                    PButton(title: m.folderName) { m.pickDestination() }
                }
            }

            SelectRow(
                label: "If Exists",
                index: $m.existsIndex,
                options: ["Rename", "Overwrite", "Skip"],
                top: L.rowGap
            )
        }

    }
}

/// Label + inline select. Height follows the select so the menu can expand.
private struct SelectRow: View {
    let label: String
    @Binding var index: Int
    let options: [String]
    var top: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(F.medium(F.ui))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: L.splitLabelW, height: L.rowH, alignment: .leading)
            PSelect(index: $index, options: options, width: L.selectW)
            Spacer(minLength: 0)
        }
        .padding(.leading, L.labelX)
        .padding(.trailing, L.rowPadRight)
        .padding(.top, top)
    }
}
