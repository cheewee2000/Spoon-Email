import SwiftUI

/// The colors an account can wear. The first six double as the defaults,
/// handed out in order as accounts are added, so a new account already looks
/// distinct from the others before anyone picks anything. Fixed hex rather
/// than the system colors so a stored choice and an unset default are the
/// same value — and so the swatch in the menu matches the stripe on the row.
enum AccountPalette {
    struct Swatch: Identifiable, Hashable {
        let name: String
        let hex: String
        var id: String { hex }
        var color: Color { Color(hex: hex) ?? CWT.ink }
    }

    /// CW&T's signal colors first, then the material greys sampled from the
    /// studio's product photography — steel, titanium, brass, copper,
    /// graphite, cerakote.
    static let swatches: [Swatch] = [
        .init(name: "Signal Red",  hex: "#D11D1D"),
        .init(name: "Cerakote",    hex: "#E35A1E"),
        .init(name: "Green",       hex: "#2E7D4F"),
        .init(name: "Copper",      hex: "#B87333"),
        .init(name: "Brass",       hex: "#B08D57"),
        .init(name: "Titanium",    hex: "#6E7378"),
        .init(name: "Steel",       hex: "#8C9296"),
        .init(name: "Graphite",    hex: "#3C3C3C"),
        .init(name: "Slate",       hex: "#4F5B66"),
        .init(name: "Ochre",       hex: "#C79A2A"),
        .init(name: "Oxblood",     hex: "#7A2E2E"),
        .init(name: "Ink",         hex: "#111111"),
    ]

    /// The color an account with no stored choice wears, by its position in
    /// the account list.
    static func defaultColor(index: Int) -> Color {
        swatches[index % 6].color
    }

    static func defaultHex(index: Int) -> String {
        swatches[index % 6].hex
    }
}

extension Color {
    /// "#RRGGBB" (the "#" optional). Anything else is not a color.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
