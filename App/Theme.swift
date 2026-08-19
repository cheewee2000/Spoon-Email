import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The CW&T design system, as tokens.
///
/// Paper-white ground, near-black ink, one typeface (Space Mono) for every
/// piece of chrome, 1 px hairline rules, square corners, no shadows, hover by
/// opacity rather than color, and signal colors used sparingly. Dark mode is
/// the same system with paper and ink swapped, so the app follows the system
/// appearance without a second palette.
///
/// Message bodies and the compose editor are the mail itself, not chrome —
/// they keep their own fonts so what you read and write is what the other
/// side sees.
enum CWT {
    // MARK: Color

    /// Page ground.
    static let paper = dynamic(light: 0xFFFFFF, dark: 0x111111)
    /// Warm off-white: secondary surfaces (rail, column headers, sheets).
    static let paperWarm = dynamic(light: 0xF6F5F2, dark: 0x181818)
    /// Primary text.
    static let ink = dynamic(light: 0x111111, dark: 0xF6F5F2)
    /// Secondary text.
    static let ink2 = dynamic(light: 0x4A4A4A, dark: 0xB0B0B0)
    /// Spec / label text.
    static let ink3 = dynamic(light: 0x8A8A8A, dark: 0x7A7A7A)
    /// The one divider: 1 px, everywhere.
    static let hairline = dynamic(light: 0xE3E3E3, dark: 0x2A2A2A)

    /// Signal red — errors, unread counts, WAITLIST-grade callouts.
    static let red = Color(hex: "#d11d1d")!
    /// In-stock green — quiet positive state.
    static let green = Color(hex: "#2e7d4f")!
    /// Cerakote orange — hot / limited / starred.
    static let orange = Color(hex: "#e35a1e")!

    /// Flat black scrim behind modals. The only translucency in the system.
    static let scrim = Color.black.opacity(0.55)

    /// Ink at hover strength: rows and rail items under the pointer.
    static let hover = ink.opacity(0.06)
    /// Ink at selection strength.
    static let selection = ink.opacity(0.10)

    // MARK: Type

    static let regularFace = "SpaceMono-Regular"
    static let boldFace = "SpaceMono-Bold"

    /// Space Mono at any size. Falls back to the system monospace if the
    /// bundled face failed to register, never to a proportional sans.
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        if fontsRegistered {
            return .custom(bold ? boldFace : regularFace, size: size)
        }
        return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    }

    /// Body copy in lists and panes.
    static let body = font(13)
    static let bodyBold = font(13, bold: true)
    /// Captions, dates, counts.
    static let caption = font(11)
    /// Section labels — pair with `.tracking(labelTracking)` and uppercase.
    static let label = font(10, bold: true)
    static let labelTracking: CGFloat = 0.4
    /// Sheet and page titles.
    static let title = font(16, bold: true)
    static let display = font(24, bold: true)

    // MARK: Motion

    /// Standard mechanical ease. Never bouncy.
    static let ease = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)

    /// The navigation clock: board↔mailbox zooms, mailbox↔mailbox slides,
    /// and the reader all move on this one spring, so every trip through the
    /// app has the same weight.
    static let nav = Animation.spring(response: 0.32, dampingFraction: 0.86)

    // MARK: Registration

    private(set) static var fontsRegistered = false

    /// Registers the bundled Space Mono faces with the process. Call once,
    /// before the first view is built.
    static func registerFonts() {
        guard !fontsRegistered else { return }
        var ok = false
        // Italic faces are bundled for the compose editor's I button only;
        // the chrome never uses them.
        for name in ["SpaceMono-Regular", "SpaceMono-Bold", "SpaceMono-Italic", "SpaceMono-BoldItalic"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                ok = true
            } else if let error = error?.takeRetainedValue(),
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                ok = true
            }
        }
        fontsRegistered = ok
    }

    /// The regular face as an AppKit/UIKit font, for text views.
    static func platformFont(size: CGFloat) -> PlatformFont {
        PlatformFont(name: regularFace, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    #if os(iOS)
    /// UIKit-drawn chrome — navigation titles, bar buttons, the search
    /// field — doesn't take SwiftUI's environment font. Set it once here.
    static func applyAppearance() {
        let regular = UIFont(name: regularFace, size: 15) ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
        let title = UIFont(name: boldFace, size: 15) ?? .monospacedSystemFont(ofSize: 15, weight: .bold)
        let large = UIFont(name: boldFace, size: 28) ?? .monospacedSystemFont(ofSize: 28, weight: .bold)
        let nav = UINavigationBar.appearance()
        nav.titleTextAttributes = [.font: title]
        nav.largeTitleTextAttributes = [.font: large]
        let bar = UIBarButtonItem.appearance()
        for state in [UIControl.State.normal, .highlighted, .disabled] {
            bar.setTitleTextAttributes([.font: regular], for: state)
        }
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).font =
            UIFont(name: regularFace, size: 14) ?? regular
        UILabel.appearance(whenContainedInInstancesOf: [UISearchBar.self]).font =
            UIFont(name: regularFace, size: 14) ?? regular
    }
    #endif

    // MARK: Helpers

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

// MARK: - Building blocks

/// The 1 px rule. Replaces `Divider()` in the chrome so every rule is the
/// same hairline color rather than the system separator.
struct Hairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(CWT.hairline)
            .frame(width: axis == .vertical ? 1 : nil,
                   height: axis == .horizontal ? 1 : nil)
    }
}

/// A short uppercase word on a signal color: `WAITLIST`, `NEW`, an unread
/// count. Square, text-only, never an icon.
struct Tag: View {
    let text: String
    var color: Color = CWT.red
    var inverted = true

    var body: some View {
        Text(text)
            .font(CWT.font(9, bold: true))
            .tracking(CWT.labelTracking)
            .foregroundStyle(inverted ? CWT.paper : color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(inverted ? color : .clear)
            .overlay(Rectangle().strokeBorder(color, lineWidth: inverted ? 0 : 1))
    }
}

/// Section label: small, bold, uppercase, tracked.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(CWT.label)
            .tracking(CWT.labelTracking)
            .foregroundStyle(CWT.ink3)
    }
}

/// Text-only action: hover fades to 0.55, press to 0.8, no color change.
struct TextActionStyle: ButtonStyle {
    var color: Color = CWT.ink
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CWT.font(12))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.8 : (hovering ? 0.55 : 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(CWT.ease, value: hovering)
    }
}

/// Square ink-on-paper (primary) or paper-on-ink (secondary) button.
struct SquareButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CWT.font(12, bold: primary))
            .foregroundStyle(primary ? CWT.paper : CWT.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(primary ? CWT.ink : CWT.paper)
            .overlay(Rectangle().strokeBorder(primary ? CWT.ink : CWT.hairline, lineWidth: 1))
            .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.8 : (hovering ? 0.55 : 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(CWT.ease, value: hovering)
    }
}

extension ButtonStyle where Self == TextActionStyle {
    static var textAction: TextActionStyle { TextActionStyle() }
    static func textAction(_ color: Color) -> TextActionStyle { TextActionStyle(color: color) }
}

extension ButtonStyle where Self == SquareButtonStyle {
    static var square: SquareButtonStyle { SquareButtonStyle() }
    static var squarePrimary: SquareButtonStyle { SquareButtonStyle(primary: true) }
}

extension View {
    /// Paper ground plus the body face — put on every window and sheet root.
    func cwtChrome() -> some View {
        self
            .font(CWT.body)
            .foregroundStyle(CWT.ink)
            .background(CWT.paper)
            .tint(CWT.ink)
    }
}

/// Empty state: a title and one line of explanation, set in type. No symbol.
struct EmptyState: View {
    let title: String
    var systemImage: String?
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(CWT.ink3)
                    .padding(.bottom, 6)
            }
            Text(title.uppercased())
                .font(CWT.label)
                .tracking(CWT.labelTracking)
                .foregroundStyle(CWT.ink2)
            if let detail {
                Text(detail)
                    .font(CWT.caption)
                    .foregroundStyle(CWT.ink3)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Navigation transitions

extension AnyTransition {
    /// The reader arrives over its placeholder from the right, and leaves the
    /// way it came.
    static let reader = AnyTransition.move(edge: .trailing).combined(with: .opacity)
}
