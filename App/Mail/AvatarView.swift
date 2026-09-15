import SwiftUI

/// The sender's picture, or their initials on a color derived from the
/// address — so the fallback is still a fixed, recognizable mark per sender
/// rather than one gray circle repeated down the list.
struct AvatarView: View {
    let name: String
    let email: String
    let size: CGFloat

    /// Decoded once when the bytes land. Decoding in `body` re-ran the
    /// image decoder for every row on every list delivery.
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Self.tint(for: email.isEmpty ? name : email)
                    Text(Self.initials(name: name, email: email))
                        .font(CWT.font(size * 0.38, bold: true))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Rectangle())
        // Icons come back on transparent or white grounds in every mix; the
        // hairline keeps them from bleeding into the row. Square, like every
        // other photograph in the system.
        .overlay(Rectangle().strokeBorder(CWT.hairline, lineWidth: 1))
        .task(id: email) {
            image = nil
            guard !email.isEmpty,
                  let data = await AvatarStore.shared.avatar(for: email) else { return }
            image = Self.image(from: data)
        }
    }

    // MARK: - Fallback

    static func initials(name: String, email: String) -> String {
        let source = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? email : name
        let words = source
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "@" || $0 == "." })
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Stable per address: the same sender is the same color every session,
    /// on every machine, without storing anything. Shared with the rendered
    /// conversation, which draws the same fallback in CSS.
    static func hue(for key: String) -> Int {
        var hash: UInt64 = 5381
        for byte in key.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Int(hash % 360)
    }

    /// Muted: a material grey with a hint of hue, so a list of fallbacks
    /// reads as steel, brass and graphite rather than a paint chart.
    static func tint(for key: String) -> Color {
        Color(hue: Double(hue(for: key)) / 360, saturation: 0.22, brightness: 0.52)
    }

    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        guard let native = NSImage(data: data) else { return nil }
        return Image(nsImage: native)
        #else
        guard let native = UIImage(data: data) else { return nil }
        return Image(uiImage: native)
        #endif
    }
}
