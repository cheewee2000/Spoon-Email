import Foundation

/// Builds RFC 2822 messages for the Gmail send endpoint.
public enum MimeBuilder {
    public static func build(fromEmail: String,
                             to: String, cc: String, bcc: String,
                             subject: String, bodyText: String, bodyHTML: String = "",
                             quotedText: String = "", quotedHTML: String? = nil,
                             attachments: [ComposeAttachment] = [],
                             inReplyTo: String, references: String,
                             date: Date = Date()) -> Data {
        let boundary = "sdh-" + UUID().uuidString
        let relatedBoundary = "sdh-rel-" + UUID().uuidString
        let mixedBoundary = "sdh-mix-" + UUID().uuidString
        let inline = attachments.filter(\.isInline)
        let files = attachments.filter { !$0.isInline }
        var headers: [String] = []
        headers.append("From: \(fromEmail)")
        headers.append("To: \(to)")
        if !cc.isEmpty { headers.append("Cc: \(cc)") }
        if !bcc.isEmpty { headers.append("Bcc: \(bcc)") }
        headers.append("Subject: \(encodeHeader(subject))")
        headers.append("Date: \(rfc5322Date(date))")
        headers.append("Message-ID: <\(UUID().uuidString)@spoon.local>")
        if !inReplyTo.isEmpty { headers.append("In-Reply-To: \(inReplyTo)") }
        if !references.isEmpty { headers.append("References: \(references)") }
        headers.append("MIME-Version: 1.0")
        // Nesting, outermost first: multipart/mixed (only with file
        // attachments) > multipart/related (only with inline images, so they
        // resolve against their cid) > multipart/alternative (always).
        let relatedHeader = "Content-Type: multipart/related; "
            + "boundary=\"\(relatedBoundary)\"; type=\"multipart/alternative\""
        let alternativeHeader = "Content-Type: multipart/alternative; boundary=\"\(boundary)\""
        if !files.isEmpty {
            headers.append("Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"")
        } else if !inline.isEmpty {
            headers.append(relatedHeader)
        } else {
            headers.append(alternativeHeader)
        }

        // The composer sends rich HTML for what was typed; plain text is the
        // fallback for drafts written before, and for the text/plain part.
        let composed = bodyHTML.isEmpty
            ? escapeHTML(bodyText).replacingOccurrences(of: "\n", with: "<br>")
            : bodyHTML
        var html = "<div style=\"font-family:-apple-system,sans-serif;font-size:14px\">"
            + composed
            + "</div>"
        // Quoted/forwarded trail: use the original HTML when we have it so
        // formatting survives; otherwise fall back to the plain-text quote.
        if let quotedHTML, !quotedHTML.isEmpty {
            html += quotedHTML
        } else if !quotedText.isEmpty {
            html += "<div style=\"color:#555\">"
                + escapeHTML(quotedText).replacingOccurrences(of: "\n", with: "<br>")
                + "</div>"
        }
        let plainText = quotedText.isEmpty ? bodyText : bodyText + "\n\n" + quotedText

        var lines: [String] = headers
        lines.append("")
        if !files.isEmpty {
            lines.append("--\(mixedBoundary)")
            lines.append(inline.isEmpty ? alternativeHeader : relatedHeader)
            lines.append("")
        }
        if !inline.isEmpty {
            lines.append("--\(relatedBoundary)")
            lines.append(alternativeHeader)
            lines.append("")
        }
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(base64Wrapped(plainText))
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/html; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(base64Wrapped(html))
        lines.append("--\(boundary)--")

        func appendPart(_ attachment: ComposeAttachment, boundary: String) {
            let name = encodeHeader(attachment.filename)
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(attachment.mimeType); name=\"\(name)\"")
            lines.append("Content-Transfer-Encoding: base64")
            if attachment.isInline { lines.append("Content-ID: <\(attachment.id)>") }
            lines.append("Content-Disposition: \(attachment.isInline ? "inline" : "attachment")"
                + "; filename=\"\(name)\"")
            lines.append("")
            lines.append(base64Wrapped(attachment.data))
        }
        for attachment in inline { appendPart(attachment, boundary: relatedBoundary) }
        if !inline.isEmpty { lines.append("--\(relatedBoundary)--") }
        for attachment in files { appendPart(attachment, boundary: mixedBoundary) }
        if !files.isEmpty { lines.append("--\(mixedBoundary)--") }

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
        base64Wrapped(Data(s.utf8))
    }

    static func base64Wrapped(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
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
