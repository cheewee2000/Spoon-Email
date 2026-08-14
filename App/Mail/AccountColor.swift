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
        var color: Color { Color(hex: hex) ?? .blue }
    }

    static let swatches: [Swatch] = [
        .init(name: "Blue",   hex: "#0A84FF"),
        .init(name: "Purple", hex: "#BF5AF2"),
        .init(name: "Orange", hex: "#FF9F0A"),
        .init(name: "Teal",   hex: "#40C8E0"),
        .init(name: "Pink",   hex: "#FF6482"),
        .init(name: "Indigo", hex: "#5E5CE6"),
        .init(name: "Green",  hex: "#32D74B"),
        .init(name: "Red",    hex: "#FF453A"),
        .init(name: "Yellow", hex: "#FFD60A"),
        .init(name: "Brown",  hex: "#AC8E68"),
        .init(name: "Mint",   hex: "#66D4CF"),
        .init(name: "Gray",   hex: "#98989D"),
    ]

    /// The color an account with no stored choice wears, by its position in
    /// the account list.
    static func defaultColor(index: Int) -> Color {
        swatches[index % 6].color
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
