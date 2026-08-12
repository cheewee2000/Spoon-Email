import Foundation

/// Builds RFC 2822 messages for the Gmail send endpoint.
public enum MimeBuilder {
    public static func build(fromEmail: String,
                             to: String, cc: String, bcc: String,
                             subject: String, bodyText: String,
                             inReplyTo: String, references: String,
                             date: Date = Date()) -> Data {
        let boundary = "sdh-" + UUID().uuidString
        var headers: [String] = []
        headers.append("From: \(fromEmail)")
        headers.append("To: \(to)")
        if !cc.isEmpty { headers.append("Cc: \(cc)") }
        if !bcc.isEmpty { headers.append("Bcc: \(bcc)") }
        headers.append("Subject: \(encodeHeader(subject))")
        headers.append("Date: \(rfc5322Date(date))")
        headers.append("Message-ID: <\(UUID().uuidString)@superduperhuman.local>")
        if !inReplyTo.isEmpty { headers.append("In-Reply-To: \(inReplyTo)") }
        if !references.isEmpty { headers.append("References: \(references)") }
        headers.append("MIME-Version: 1.0")
        headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")

        let html = "<div style=\"font-family:-apple-system,sans-serif;font-size:14px\">"
            + escapeHTML(bodyText).replacingOccurrences(of: "\n", with: "<br>")
            + "</div>"

        var lines: [String] = headers
        lines.append("")
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(base64Wrapped(bodyText))
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/html; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(base64Wrapped(html))
        lines.append("--\(boundary)--")

        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// RFC 2047 B-encoding for non-ASCII header values.
    static func encodeHeader(_ s: String) -> String {
        guard !s.allSatisfy({ $0.isASCII }) else { return s }
        return "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
    }

    static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    static func base64Wrapped(_ s: String) -> String {
        let b64 = Data(s.utf8).base64EncodedString()
        var out: [String] = []
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex
            out.append(String(b64[idx..<end]))
            idx = end
        }
        return out.joined(separator: "\r\n")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
