import Foundation

/// Parses RFC 2369/8058 List-Unsubscribe headers and performs the action.
public enum Unsubscriber {
    public struct Links: Sendable, Equatable {
        public var https: URL?
        public var mailto: URL?
        public var oneClick: Bool
    }

    /// Header form: `<https://ex.com/unsub?u=1>, <mailto:unsub@ex.com>`
    public static func parse(header: String, postHeader: String) -> Links? {
        guard !header.isEmpty else { return nil }
        var links = Links(https: nil, mailto: nil,
                          oneClick: postHeader.localizedCaseInsensitiveContains("One-Click"))
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let token = String(rest[rest.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: token) {
                switch url.scheme?.lowercased() {
                case "https", "http" where links.https == nil:
                    if links.https == nil { links.https = url }
                case "mailto":
                    if links.mailto == nil { links.mailto = url }
                default: break
                }
            }
            rest = rest[rest.index(after: close)...]
        }
        return (links.https == nil && links.mailto == nil) ? nil : links
    }

    public enum Outcome: Sendable {
        case oneClickDone          // RFC 8058 POST succeeded
        case openedBrowser(URL)    // caller should open this URL
        case sendEmail(to: String, subject: String)  // caller should send this
    }

    /// Decides and (for one-click) performs the unsubscribe.
    public static func perform(_ links: Links) async throws -> Outcome {
        if let url = links.https {
            if links.oneClick {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(code) { return .oneClickDone }
                // Fall back to the browser if the endpoint balks
            }
            return .openedBrowser(url)
        }
        if let mailto = links.mailto {
            let to = mailto.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
                .components(separatedBy: "?")[0]
            var subject = "unsubscribe"
            if let comps = URLComponents(url: mailto, resolvingAgainstBaseURL: false),
               let s = comps.queryItems?.first(where: { $0.name.lowercased() == "subject" })?.value {
                subject = s
            }
            return .sendEmail(to: to, subject: subject)
        }
        throw MailError.oauthFailed("no unsubscribe link")
    }
}
