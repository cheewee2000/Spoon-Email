import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformTextView = NSTextView
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformTextView = UITextView

extension UIColor { static var linkColor: UIColor { .link } }
#endif

/// The composer's default text style, shared by the editor and the HTML
/// serializer so round-tripping a draft doesn't drift.
enum ComposeStyle {
    #if os(macOS)
    static let baseSize: CGFloat = 13
    #else
    static let baseSize: CGFloat = 16
    #endif

    /// Space Mono, like the rest of the app. Display only: the serializer
    /// writes bold/italic/size, never a family, so the recipient's client
    /// still picks its own default.
    static var baseFont: PlatformFont { CWT.platformFont(size: baseSize) }

    /// Near-black, matching the white sheet below. `hex(_:)` drops near-black
    /// when serializing, so this never reaches the HTML and the recipient's
    /// client still picks its own default.
    static var textColor: PlatformColor { .black }

    /// The surface the composer draws on. Fixed white in both themes, the way
    /// the message will actually render for the recipient — and the way the
    /// reading pane already shows HTML bodies.
    static var backgroundColor: PlatformColor { .white }

    /// What an imported run should be recoloured to, or nil to leave it alone.
    ///
    /// A sender picked their colours for the background *they* assumed. Ours
    /// can be the opposite one, which is how a reply ends up black on black.
    /// Anything that still reads on the surface it lands on is left alone —
    /// brand reds and link blues survive — and the rest gives way.
    static func legibleColor(_ color: PlatformColor,
                             on background: PlatformColor?) -> PlatformColor? {
        if contrastRatio(color, background ?? backgroundColor) >= 3 { return nil }
        // Only our own surface follows the theme. Against a background the
        // sender baked in, the theme's text colour is just as likely to
        // vanish, so pick the end of the scale that actually contrasts.
        guard let background else { return textColor }
        return (luminance(background) ?? 1) > 0.5 ? .black : .white
    }

    /// WCAG contrast, 1 (identical) to 21 (black on white). Unreadable
    /// colours are treated as readable so an odd colour space can't blank a
    /// run out.
    private static func contrastRatio(_ a: PlatformColor, _ b: PlatformColor) -> Double {
        guard let la = luminance(a), let lb = luminance(b) else { return 21 }
        let (lighter, darker) = la > lb ? (la, lb) : (lb, la)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG relative luminance, resolved in the appearance actually on screen
    /// — `.labelColor` and friends mean nothing until they're resolved.
    private static func luminance(_ color: PlatformColor) -> Double? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        var resolved: NSColor?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let resolved else { return nil }
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        guard color.resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return nil
        }
        #endif
        func channel(_ raw: CGFloat) -> Double {
            let v = Double(raw)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

/// Formatting commands the compose toolbar drives, applied to the text view's
/// selection (or to the typing attributes when nothing is selected).
@MainActor
final class RichTextController: ObservableObject {
    weak var textView: PlatformTextView?

    func toggleBold() { toggleTrait(.bold) }
    func toggleItalic() { toggleTrait(.italic) }
    func toggleUnderline() { toggleNumberAttribute(.underlineStyle) }
    func toggleStrikethrough() { toggleNumberAttribute(.strikethroughStyle) }

    /// Links the selection, or inserts the URL itself when nothing is selected.
    func applyLink(_ urlString: String) {
        guard let tv = textView else { return }
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return }
        let range = selectedRange
        let storage = textView?.textStorage
        storage?.beginEditing()
        if range.length == 0 {
            let attrs: [NSAttributedString.Key: Any] = [
                .link: url,
                .font: ComposeStyle.baseFont,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PlatformColor.linkColor,
            ]
            storage?.insert(NSAttributedString(string: text, attributes: attrs), at: range.location)
        } else {
            storage?.addAttributes([
                .link: url,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PlatformColor.linkColor,
            ], range: range)
        }
        storage?.endEditing()
        didEdit()
    }

    /// Drops an image into the body at the caret (or at the end when the
    /// editor was never focused), on its own line.
    func insert(image: InlineImageAttachment) {
        guard let tv = textView else { return }
        // NSTextView vends an optional text storage; UITextView's is not.
        #if os(macOS)
        guard let storage = tv.textStorage else { return }
        #else
        let storage = tv.textStorage
        #endif
        let range = selectedRange
        let location = range.location == 0 && range.length == 0 && !isFocused
            ? storage.length
            : NSMaxRange(range)
        let block = NSMutableAttributedString(attachment: image)
        block.append(NSAttributedString(string: "\n",
                                        attributes: [.font: ComposeStyle.baseFont,
                                                     .foregroundColor: ComposeStyle.textColor]))
        storage.beginEditing()
        if location > 0, (storage.string as NSString).character(at: location - 1) != 10 {
            block.insert(NSAttributedString(string: "\n",
                                            attributes: [.font: ComposeStyle.baseFont]), at: 0)
        }
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: block)
        storage.endEditing()
        setSelection(NSRange(location: location + block.length, length: 0))
        didEdit()
    }

    private var isFocused: Bool {
        #if os(macOS)
        guard let tv = textView else { return false }
        return tv.window?.firstResponder === tv
        #else
        return textView?.isFirstResponder ?? false
        #endif
    }

    private func setSelection(_ range: NSRange) {
        #if os(macOS)
        textView?.setSelectedRange(range)
        #else
        textView?.selectedRange = range
        #endif
    }

    /// Strips every formatting attribute from the selection.
    func clearFormatting() {
        guard let storage = textView?.textStorage else { return }
        let range = selectedRange
        guard range.length > 0 else { return }
        storage.beginEditing()
        for key: NSAttributedString.Key in [.underlineStyle, .strikethroughStyle, .link, .foregroundColor, .backgroundColor] {
            storage.removeAttribute(key, range: range)
        }
        storage.addAttribute(.font, value: ComposeStyle.baseFont, range: range)
        storage.endEditing()
        didEdit()
    }

    // MARK: - Plumbing

    private var selectedRange: NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        #if os(macOS)
        return tv.selectedRange()
        #else
        return tv.selectedRange
        #endif
    }

    private enum Trait { case bold, italic }

    private func toggleTrait(_ trait: Trait) {
        guard let tv = textView, let storage = textView?.textStorage else { return }
        let range = selectedRange
        if range.length == 0 {
            let current = (tv.typingAttributes[.font] as? PlatformFont) ?? ComposeStyle.baseFont
            tv.typingAttributes[.font] = flip(current, trait: trait, on: !has(trait, in: current))
            return
        }
        // Mixed selections turn the trait on; a uniformly styled one toggles.
        var allOn = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = (value as? PlatformFont) ?? ComposeStyle.baseFont
            if !has(trait, in: font) { allOn = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? PlatformFont) ?? ComposeStyle.baseFont
            storage.addAttribute(.font, value: flip(font, trait: trait, on: !allOn), range: subrange)
        }
        storage.endEditing()
        didEdit()
    }

    private func toggleNumberAttribute(_ key: NSAttributedString.Key) {
        guard let tv = textView, let storage = textView?.textStorage else { return }
        let range = selectedRange
        let on = NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            let current = (tv.typingAttributes[key] as? Int) ?? 0
            tv.typingAttributes[key] = current == 0 ? on : 0
            return
        }
        var allOn = true
        storage.enumerateAttribute(key, in: range) { value, _, _ in
            if ((value as? Int) ?? 0) == 0 { allOn = false }
        }
        storage.beginEditing()
        storage.addAttribute(key, value: allOn ? 0 : on, range: range)
        storage.endEditing()
        didEdit()
    }

    private func has(_ trait: Trait, in font: PlatformFont) -> Bool {
        let traits = font.fontDescriptor.symbolicTraits
        #if os(macOS)
        return trait == .bold ? traits.contains(.bold) : traits.contains(.italic)
        #else
        return trait == .bold ? traits.contains(.traitBold) : traits.contains(.traitItalic)
        #endif
    }

    private func flip(_ font: PlatformFont, trait: Trait, on: Bool) -> PlatformFont {
        #if os(macOS)
        let mask: NSFontDescriptor.SymbolicTraits = trait == .bold ? .bold : .italic
        var traits = font.fontDescriptor.symbolicTraits
        if on { traits.insert(mask) } else { traits.remove(mask) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        let mask: UIFontDescriptor.SymbolicTraits = trait == .bold ? .traitBold : .traitItalic
        var traits = font.fontDescriptor.symbolicTraits
        if on { traits.insert(mask) } else { traits.remove(mask) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    /// Attribute changes made straight on the text storage don't fire the
    /// delegate, so the binding is nudged by hand.
    var onEdit: (() -> Void)?
    private func didEdit() { onEdit?() }
}

/// A rich-text body editor (NSTextView / UITextView) bound to an attributed
/// string, so bold, italic, links and pasted formatting survive into the sent
/// message.
struct RichTextEditor: View {
    @Binding var text: NSAttributedString
    let controller: RichTextController

    var body: some View {
        Representable(text: $text, controller: controller)
    }

    fileprivate struct Representable {
        @Binding var text: NSAttributedString
        let controller: RichTextController

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        final class Coordinator: NSObject {
            var parent: Representable
            init(_ parent: Representable) { self.parent = parent }

            /// NSTextView's textStorage is optional, UITextView's isn't —
            /// this reads the same on both.
            private func storage(_ view: PlatformTextView) -> NSTextStorage? {
                view.textStorage
            }

            func sync(_ view: PlatformTextView) {
                guard let storage = storage(view) else { return }
                parent.text = NSAttributedString(attributedString: storage)
            }

            /// True once the view holds exactly what the binding holds.
            func matches(_ view: PlatformTextView, _ text: NSAttributedString) -> Bool {
                storage(view)?.isEqual(to: text) ?? false
            }
        }
    }
}

#if os(macOS)
extension RichTextEditor.Representable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = true
        view.allowsUndo = true
        view.isAutomaticLinkDetectionEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.usesFindBar = true
        view.font = ComposeStyle.baseFont
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.drawsBackground = true
        view.backgroundColor = ComposeStyle.backgroundColor
        view.insertionPointColor = ComposeStyle.textColor
        scroll.drawsBackground = true
        scroll.backgroundColor = ComposeStyle.backgroundColor
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(text)
        view.typingAttributes = [
            .font: ComposeStyle.baseFont,
            .foregroundColor: ComposeStyle.textColor,
        ]
        controller.textView = view
        controller.onEdit = { [weak view] in
            guard let view else { return }
            context.coordinator.sync(view)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        controller.textView = view
        // Only push external replacements (draft loaded, formatting cleared);
        // echoing the user's own keystrokes back would reset the caret.
        if !context.coordinator.matches(view, text), let storage = view.textStorage {
            let selection = view.selectedRange()
            storage.setAttributedString(text)
            view.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        }
    }
}

extension RichTextEditor.Representable.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        sync(view)
    }
}
#else
extension RichTextEditor.Representable: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.allowsEditingTextAttributes = true
        view.font = ComposeStyle.baseFont
        view.backgroundColor = ComposeStyle.backgroundColor
        view.textColor = ComposeStyle.textColor
        view.tintColor = ComposeStyle.textColor
        view.delegate = context.coordinator
        view.attributedText = text
        view.typingAttributes = [
            .font: ComposeStyle.baseFont,
            .foregroundColor: ComposeStyle.textColor,
        ]
        controller.textView = view
        controller.onEdit = { [weak view] in
            guard let view else { return }
            context.coordinator.sync(view)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view
        if !context.coordinator.matches(view, text) {
            let selection = view.selectedRange
            view.attributedText = text
            view.selectedRange = NSRange(location: min(selection.location, view.textStorage.length), length: 0)
        }
    }
}

extension RichTextEditor.Representable.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { sync(textView) }
}
#endif
