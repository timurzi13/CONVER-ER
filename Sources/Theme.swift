import AppKit
import SwiftUI

// ============================================================
//  Design tokens, ported straight from the 21 Generators shell
//  (src/styles/base.css + src/lib/layout.ts).
// ============================================================

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Palette, lifted from the source SVGs.
enum P {
    static let accent      = Color(hex: 0xFF4F4F)
    static let colLeft     = Color(hex: 0xE5E5E5)
    static let colRight    = Color(hex: 0x404040)
    static let panel       = Color(hex: 0x535353)
    static let track       = Color(hex: 0x3D3D3D)
    static let trackHover  = Color(hex: 0x4A4A4A)
    static let valueHover  = Color(hex: 0x464646)
    static let rule        = Color(hex: 0x3C3C3C)
    static let control     = Color(hex: 0x787878)
    static let ctrlHover   = Color(hex: 0x8A8A8A)
    static let ctrlActive  = Color(hex: 0x969696)
    static let segIdle     = Color(hex: 0x707070)
    static let segActive   = Color(hex: 0x424242)
    static let ink         = Color(hex: 0x000000)
    static let paper       = Color(hex: 0xFFFFFF)
    static let footerText  = Color(hex: 0x999999)
    static let footerRule  = Color(hex: 0x333333)
    static let xbLabel     = Color(hex: 0x727171)
    static let xbBtn       = Color(hex: 0x535353)
    static let xbBtnHover  = Color(hex: 0x696969)
    static let outerGroove = Color(hex: 0xCFCFCF)
    static let outerHandle = Color(hex: 0xF4F4F4)
    static let trackGroove = Color(hex: 0x484848)
    static let trackHandle = Color(hex: 0x535353)
    static let ok          = Color(hex: 0x86F879)
    static let bad         = Color(hex: 0xFFA6A6)
}

/// Motion. The web shell leans on one ease-out curve; SwiftUI gets the same feel.
enum M {
    static let dur1 = 0.14
    static let dur2 = 0.22
    static let dur3 = 0.42
    static var easeOut: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: dur2) }
    static var easeOutSlow: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: dur3) }
    static var quick: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: dur1) }
}

/// Type. DM Sans ships in Resources/Fonts and is registered through
/// ATSApplicationFontsPath in Info.plist.
enum F {
    static func regular(_ s: CGFloat) -> Font { .custom("DMSans-Regular",  fixedSize: s) }
    static func medium(_ s: CGFloat)  -> Font { .custom("DMSans-Medium",   fixedSize: s) }
    static func semi(_ s: CGFloat)    -> Font { .custom("DMSans-SemiBold", fixedSize: s) }
    static func bold(_ s: CGFloat)    -> Font { .custom("DMSans-Bold",     fixedSize: s) }

    static let title: CGFloat = 26.5
    static let numeral: CGFloat = 40
    static let ui: CGFloat = 16
    static let credit: CGFloat = 10
}

/// Geometry. Vertical stack: 60pt header, the work area, then a slim footer
/// band; everything inside the work area sits on a 15px rhythm.
enum L {
    static let headerH: CGFloat = 60
    static let footerH: CGFloat = 36
    static let edge: CGFloat = 20
    static let gap: CGFloat = 15
    static let barH: CGFloat = 52

    // left column — the panel keeps the same gutter on both sides
    static let leftPadX: CGFloat = 20
    static let leftW: CGFloat = 411 + leftPadX * 2

    // panel interior, local to the 411px panel
    static let panelW: CGFloat = 411
    static let panelRadius: CGFloat = 76
    static let panelPadTop: CGFloat = 56
    static let panelPadBottom: CGFloat = 56
    /// the panel keeps the same gutter on both sides:
    /// 24 | 122 | 160 | 3 | 78 | 24  ==  411
    static let labelX: CGFloat = 24
    static let rowPadRight: CGFloat = labelX
    static let rowH: CGFloat = 30
    static let rowGap: CGFloat = 9
    static let labelW: CGFloat = 122
    static let trackW: CGFloat = 160
    static let colGap: CGFloat = 3
    static let valueW: CGFloat = 78
    static let splitLabelW: CGFloat = 127
    static let selectW: CGFloat = panelW - labelX * 2 - splitLabelW   // 236
    static let wideW: CGFloat = panelW - labelX * 2                   // 363
    static let pillW: CGFloat = 63
    static let pillH: CGFloat = 38
    static let pillGap: CGFloat = 22
    static let knob: CGFloat = 30

    // work area
    static let barTop: CGFloat = 15
    static let barBottom: CGFloat = 15
    static let barRight: CGFloat = 20
    static let exportLeft: CGFloat = 15
    static let exportBarW: CGFloat = 320

    /// gap between the "FILES:" caption and the count
    static let captionGap: CGFloat = 18

    static let windowMinW: CGFloat = 1100
    static let windowMinH: CGFloat = 760 + footerH
}


/// Vertical placement in the header, worked out from DM Sans' own metrics
/// rather than eyeballed, so it stays right if the sizes change.
///
/// The title row is baseline-aligned, and the tallest item in it — the count —
/// decides where that shared baseline falls. From there:
///   * the title is nudged so its cap box is centred in the header,
///   * the count is dropped further so ITS cap box is centred instead, which
///     is what "equal space above and below the number" means.
enum HeaderMetrics {
    private static let titleFont = NSFont(name: "DMSans-Bold", size: F.title)
    private static let numeralFont = NSFont(name: "DMSans-Bold", size: F.numeral)

    /// where the baseline lands before any nudging
    private static let sharedBaseline: CGFloat = {
        guard let n = numeralFont else { return L.headerH / 2 }
        let line = n.ascender - n.descender + n.leading
        return (L.headerH - line) / 2 + n.ascender
    }()

    /// centres the title's cap box; the caption rides along on the same baseline
    static let titleNudge: CGFloat = {
        guard let t = titleFont else { return 0 }
        return (L.headerH + t.capHeight) / 2 - sharedBaseline
    }()

    /// drops the count off that baseline until its own cap box is centred
    static let countNudge: CGFloat = {
        guard let n = numeralFont else { return 0 }
        return (L.headerH + n.capHeight) / 2 - sharedBaseline - titleNudge
    }()
}
