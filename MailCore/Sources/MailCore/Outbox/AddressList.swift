import Foundation

/// Parsing and de-duplicating the comma-joined address headers Gmail hands us.
///
/// Everything here compares on the bare address inside the angle brackets.
/// The same person reaches us spelled several ways across a thread — bare,
/// with a display name, with different capitalisation — and treating those as
/// different people is what puts someone in To *and* Cc on a reply-all.
public enum AddressList {
    /// One header value, split into individual addresses.
    ///
    /// Not `components(separatedBy: ",")`: a quoted display name is allowed to
    /// contain a comma, and `"Doe, John" <j@x.com>` is one recipient, not a
    /// person called `"Doe` and another called `John" <j@x.com>`.
    public static func split(_ list: String) -> [String] {
        var addresses: [String] = []
        var current = ""
        var quoted = false
        var angleDepth = 0

        for character in list {
            switch character {
            case "\"":
                quoted.toggle()
                current.append(character)
            case "<" where !quoted:
                angleDepth += 1
                current.append(character)
            case ">" where !quoted:
                angleDepth = max(0, angleDepth - 1)
                current.append(character)
            case "," where !quoted && angleDepth == 0:
                addresses.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        addresses.append(current)

        return addresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The bare address a header entry points at, lowercased — the identity
    /// two spellings of the same recipient share.
    public static func email(of address: String) -> String {
        guard let open = address.lastIndex(of: "<"),
              let close = address[open...].firstIndex(of: ">") else {
            return address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return address[address.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Keeps the first spelling of each address and drops anything already in
    /// `seen`, adding what it keeps.
    ///
    /// `seen` carries across calls on purpose: build To first, then Cc from
    /// the same set, and nobody can land in both.
    public static func unique(_ addresses: [String], seen: inout Set<String>) -> [String] {
        var kept: [String] = []
        for address in addresses {
            let identity = email(of: address)
            guard !identity.isEmpty, seen.insert(identity).inserted else { continue }
            kept.append(address)
        }
        return kept
    }

    /// Who a reply goes to.
    ///
    /// `to` is whoever you're answering — the sender, or the original
    /// recipients when you're replying to your own message. Reply-all adds
    /// everyone else the message reached, each exactly once, minus you.
    /// Replying only to yourself is the one case where `me` survives, because
    /// dropping it would leave nowhere to send.
    public static func replyRecipients(
        to: [String], others: [String], me: String
    ) -> (to: [String], cc: [String]) {
        var seen: Set<String> = [me.lowercased()]
        var recipients = unique(to, seen: &seen)
        if recipients.isEmpty {
            seen.remove(me.lowercased())
            recipients = unique(to, seen: &seen)
        }
        return (recipients, unique(others, seen: &seen))
    }
}
