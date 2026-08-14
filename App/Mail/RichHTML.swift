import Foundation
import MailCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Converts the composer's attributed text to and from the HTML that goes on
/// the wire.
///
/// Cocoa's own HTML writer puts its formatting in a `<style>` block in the
/// document head, which mail clients routinely strip — so this emits plain
/// inline tags instead, paragraph by paragraph.
enum RichHTML {
    // MARK: - Attributed → HTML

    static func html(from attributed: NSAttributedString) -> String {
        let ns = attributed.string as NSString
        guard ns.length > 0 else { return "" }

        var out = ""
        var openList: String?          // "ul" / "ol" while inside a list
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            // Trailing newline belongs to the paragraph break, not the content.
            var content = paragraph
            while content.length > 0,
                  let last = Unicode.Scalar(ns.character(at: content.location + content.length - 1)),
                  CharacterSet.newlines.contains(last) {
                content.length -= 1
            }
            let inner = runs(in: attributed, range: content)
            let list = listKind(in: attributed, range: content)

            if list != openList {
                if let openList { out += "</\(openList)>" }
                if let list { out += "<\(list)>" }
                openList = list
            }
            if list != nil {
                out += "<li>\(inner.isEmpty ? "<br>" : inner)</li>"
            } else {
                out += "<div>\(inner.isEmpty ? "<br>" : inner)</div>"
            }
            location = NSMaxRange(paragraph)
        }
        if let openList { out += "</\(openList)>" }
        return out
    }

    /// The inline images the HTML refers to by cid, in document order. Only
    /// these get shipped — an image the user deleted from the body is gone.
    static func attachments(in attributed: NSAttributedString) -> [ComposeAttachment] {
        var out: [ComposeAttachment] = []
        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let inline = value as? InlineImageAttachment else { return }
            out.append(inline.payload)
        }
        return out
    }

    /// The text/plain fallback: inline images leave an object-replacement
    /// character behind, which would show up as a stray glyph.
    static func plainText(from attributed: NSAttributedString) -> String {
        attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Emits one paragraph's styled runs as inline HTML.
    private static func runs(in attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        attributed.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            // An inline image occupies one object-replacement character; it
            // points at the MIME part that carries its bytes.
            if let inline = attrs[.attachment] as? InlineImageAttachment {
                out += "<img src=\"cid:\(escape(inline.payload.id))\""
                    + " alt=\"\(escape(inline.payload.filename))\""
                    + " style=\"max-width:100%;height:auto\">"
                return
            }
            let text = escape((attributed.string as NSString).substring(with: subrange))
                .replacingOccurrences(of: "\n", with: "<br>")
            guard !text.isEmpty else { return }

            var open = "", close = ""
            if let url = attrs[.link] as? URL {
                open += "<a href=\"\(escape(url.absoluteString))\">"; close = "</a>" + close
            } else if let s = attrs[.link] as? String {
                open += "<a href=\"\(escape(s))\">"; close = "</a>" + close
            }
            if let font = attrs[.font] as? PlatformFont {
                let traits = font.fontDescriptor.symbolicTraits
                #if os(macOS)
                let bold = traits.contains(.bold), italic = traits.contains(.italic)
                #else
                let bold = traits.contains(.traitBold), italic = traits.contains(.traitItalic)
                #endif
                if bold { open += "<b>"; close = "</b>" + close }
                if italic { open += "<i>"; close = "</i>" + close }
                let size = font.pointSize
                if abs(size - ComposeStyle.baseSize) > 0.5 {
                    open += "<span style=\"font-size:\(Int(size.rounded()))px\">"
                    close = "</span>" + close
                }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0, attrs[.link] == nil {
                open += "<u>"; close = "</u>" + close
            }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 {
                open += "<s>"; close = "</s>" + close
            }
            if attrs[.link] == nil, let color = attrs[.foregroundColor] as? PlatformColor,
               let hex = hex(color) {
                open += "<span style=\"color:\(hex)\">"; close = "</span>" + close
            }
            out += open + text + close
        }
        return out
    }

    /// "ul"/"ol" when the paragraph sits inside a list, nil otherwise.
    private static func listKind(in attributed: NSAttributedString, range: NSRange) -> String? {
        #if os(macOS)
        guard range.length > 0,
              let style = attributed.attribute(.paragraphStyle, at: range.location,
                                               effectiveRange: nil) as? NSParagraphStyle,
              let list = style.textLists.last else { return nil }
        let marker = list.markerFormat.rawValue.lowercased()
        return marker.contains("decimal") || marker.contains("roman") || marker.contains("alpha")
            ? "ol" : "ul"
        #else
        return nil
        #endif
    }

    /// sRGB hex, skipping the default text color so light/dark both render.
    private static func hex(_ color: PlatformColor) -> String? {
        #if os(macOS)
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        if color == .labelColor || color == .textColor { return nil }
        #else
        let c = color
        if color == .label { return nil }
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Near-black and near-white are the theme defaults, not a choice.
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        if luminance < 0.08 || luminance > 0.92 { return nil }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - HTML → Attributed

    /// `<img src="cid:…">`, however the sending client quoted the attribute.
    private static let inlineImageTag = try? NSRegularExpression(
        pattern: "<img[^>]*src=[\"']?cid:([^\"'>\\s]+)[\"']?[^>]*>",
        options: [.caseInsensitive])

    /// Loads a saved draft back into the editor. Falls back to the plain-text
    /// body for drafts written before rich compose existed.
    ///
    /// The HTML importer can't resolve a `cid:` image — it sees a URL with no
    /// way to fetch it — so each one is swapped for an object-replacement
    /// character first. The importer then lays out the document normally
    /// (keeping the block structure around the image, which splicing fragments
    /// would lose), and the placeholders become real attachments afterwards,
    /// still carrying their content ids so a re-save points at the same parts.
    static func attributed(fromHTML html: String,
                           plainFallback: String,
                           inlineImages: [ComposeAttachment] = []) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: ComposeStyle.baseFont,
            .foregroundColor: ComposeStyle.textColor,
        ]
        guard !html.isEmpty else {
            return NSAttributedString(string: plainFallback, attributes: base)
        }
        let byContentId = Dictionary(inlineImages.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        // Any placeholder already in the source would throw the count off, and
        // it means nothing as HTML text.
        let source = html.replacingOccurrences(of: placeholder, with: "")
        let ns = source as NSString
        let matches = inlineImageTag?.matches(
            in: source, range: NSRange(location: 0, length: ns.length)) ?? []

        var stripped = ""
        var cited: [ComposeAttachment?] = []
        var cursor = 0
        for match in matches {
            let cid = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            stripped += ns.substring(with: NSRange(location: cursor,
                                                   length: match.range.location - cursor))
            stripped += placeholder
            cited.append(byContentId[cid])
            cursor = NSMaxRange(match.range)
        }
        stripped += ns.substring(from: cursor)

        guard let loaded = imported(stripped) else {
            return NSAttributedString(string: plainFallback, attributes: base)
        }
        // Back to front, so the earlier placeholders keep their offsets.
        for (slot, location) in placeholderSlots(in: loaded).enumerated().reversed() {
            let range = NSRange(location: location, length: 1)
            // An image whose bytes we couldn't recover leaves no trace; the
            // caller warns that re-saving would drop it.
            guard slot < cited.count, let payload = cited[slot],
                  let image = InlineImageLoader.image(from: payload.data) else {
                loaded.deleteCharacters(in: range)
                continue
            }
            loaded.replaceCharacters(in: range, with: NSAttributedString(
                attachment: InlineImageAttachment(payload: payload, image: image)))
        }
        return trimmed(loaded)
    }

    private static let placeholder = "\u{FFFC}"

    private static func placeholderSlots(in text: NSAttributedString) -> [Int] {
        let ns = text.string as NSString
        return (0..<ns.length).filter { ns.character(at: $0) == 0xFFFC }
    }

    /// Imports one HTML fragment and restyles it onto the composer's font.
    private static func imported(_ html: String) -> NSMutableAttributedString? {
        guard !html.isEmpty else { return NSMutableAttributedString() }
        guard let data = html.data(using: .utf8),
              let loaded = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else {
            return nil
        }
        // The importer uses Times 12 and hard-coded black; restyle onto the
        // composer's font while keeping bold/italic and explicit sizes.
        let full = NSRange(location: 0, length: loaded.length)
        loaded.enumerateAttribute(.font, in: full) { value, range, _ in
            let font = (value as? PlatformFont) ?? ComposeStyle.baseFont
            let traits = font.fontDescriptor.symbolicTraits
            var restyled = ComposeStyle.baseFont
            #if os(macOS)
            let descriptor = restyled.fontDescriptor.withSymbolicTraits(traits.intersection([.bold, .italic]))
            restyled = NSFont(descriptor: descriptor, size: ComposeStyle.baseSize) ?? restyled
            #else
            if let descriptor = restyled.fontDescriptor.withSymbolicTraits(
                traits.intersection([.traitBold, .traitItalic])) {
                restyled = UIFont(descriptor: descriptor, size: ComposeStyle.baseSize)
            }
            #endif
            loaded.addAttribute(.font, value: restyled, range: range)
        }
        loaded.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            // No colour at all, or one that won't convert to RGB, means the
            // theme's own text colour — which is never serialized, so the
            // recipient's client picks for itself.
            guard let color = value as? PlatformColor, hex(color) != nil else {
                loaded.addAttribute(.foregroundColor, value: ComposeStyle.textColor, range: range)
                return
            }
            // The sender's own colour, kept only while it stays legible on
            // whatever it's actually drawn on — their highlight background if
            // they set one, ours otherwise.
            let background = loaded.attribute(.backgroundColor, at: range.location,
                                              effectiveRange: nil) as? PlatformColor
            if let fixed = ComposeStyle.legibleColor(color, on: background) {
                loaded.addAttribute(.foregroundColor, value: fixed, range: range)
            }
        }
        // The newline Cocoa appends for a closing block element is the break
        // before whatever follows, so it's only trimmed off the whole body.
        return loaded
    }

    private static func trimmed(_ text: NSMutableAttributedString) -> NSAttributedString {
        while text.string.hasSuffix("\n") {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        return text
    }
}
