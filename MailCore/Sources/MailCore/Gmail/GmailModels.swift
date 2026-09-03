import Foundation

// MARK: - Gmail REST resource DTOs

public struct GThreadList: Decodable, Sendable {
    public let threads: [GThreadStub]?
    public let nextPageToken: String?
}

public struct GThreadStub: Decodable, Sendable {
    public let id: String
}

public struct GThread: Decodable, Sendable {
    public let id: String
    public let messages: [GMessage]?
}

public struct GMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let internalDate: String?
    public let payload: GPart?
}

public struct GPart: Decodable, Sendable {
    public let partId: String?
    public let mimeType: String?
    public let filename: String?
    public let headers: [GHeader]?
    public let body: GBody?
    public let parts: [GPart]?
}

public struct GHeader: Decodable, Sendable {
    public let name: String
    public let value: String
}

public struct GBody: Decodable, Sendable {
    public let data: String?
    public let size: Int?
    public let attachmentId: String?
}

public struct GHistoryList: Decodable, Sendable {
    public let history: [GHistory]?
    public let historyId: String?
    public let nextPageToken: String?
}

public struct GHistory: Decodable, Sendable {
    public let messagesAdded: [GMessageWrap]?
    public let messagesDeleted: [GMessageWrap]?
    public let labelsAdded: [GLabelChange]?
    public let labelsRemoved: [GLabelChange]?
}

public struct GMessageWrap: Decodable, Sendable {
    public let message: GMessageMin
}

public struct GLabelChange: Decodable, Sendable {
    public let message: GMessageMin
}

public struct GMessageMin: Decodable, Sendable {
    public let id: String
    public let threadId: String
}

// MARK: - MIME payload parsing

public enum MimeParser {
    public static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    static func header(_ payload: GPart?, _ name: String) -> String {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    /// Walks the part tree and returns (html, plainText) bodies.
    static func bodies(of part: GPart?) -> (html: String?, text: String?) {
        var html: String?
        var text: String?
        func walk(_ p: GPart?) {
            guard let p else { return }
            let mime = p.mimeType ?? ""
            let isAttachment = !(p.filename ?? "").isEmpty
            if !isAttachment, let data = p.body?.data, let decoded = base64URLDecode(data) {
                let str = decodeBody(decoded, contentType: header(p, "Content-Type"))
                if mime == "text/html", html == nil { html = str }
                if mime == "text/plain", text == nil { text = str }
            }
            p.parts?.forEach { walk($0) }
        }
        walk(part)
        return (html, text)
    }

    /// Body bytes → String, honoring the part's declared charset. A UTF-8
    /// body carrying a handful of corrupt bytes used to fail the strict
    /// decode and fall back to Latin-1 wholesale, which mojibaked every
    /// emoji and accent in the message ("⚠️" → "âš ï¸"). Now only the bad
    /// bytes are lost. The Latin-1 path survives for bodies that are
    /// actually legacy-encoded: declared, or undeclared but so far from
    /// valid UTF-8 that replacement characters would litter the text.
    static func decodeBody(_ data: Data, contentType: String) -> String {
        let ct = contentType.lowercased()
        if ct.contains("windows-1252") || ct.contains("cp1252") {
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        if ct.contains("iso-8859-1") || ct.contains("latin1") {
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        if let strict = String(data: data, encoding: .utf8) { return strict }
        let lossy = String(decoding: data, as: UTF8.self)   // U+FFFD per bad byte
        let bad = lossy.unicodeScalars.lazy.filter { $0.value == 0xFFFD }.count
        if bad > 8, bad * 100 > lossy.unicodeScalars.count, // frequent AND numerous: not UTF-8 at all
           let latin = String(data: data, encoding: .isoLatin1) {
            return latin
        }
        return lossy
    }

    /// "Ann Example <ann@example.com>" → ("Ann Example", "ann@example.com")
    public static func parseAddress(_ raw: String) -> (name: String, email: String) {
        guard let lt = raw.lastIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt else {
            let email = raw.trimmingCharacters(in: .whitespaces)
            return (email.components(separatedBy: "@").first ?? email, email)
        }
        let email = String(raw[raw.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        var name = String(raw[..<lt]).trimmingCharacters(in: .whitespaces)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (name.isEmpty ? email : name, email)
    }

    /// Converts a Gmail API message into our local Message, its label ids,
    /// and its attachment metadata.
    public static func localMessage(from g: GMessage, accountId: String) -> (Message, [String], [Attachment]) {
        let from = parseAddress(header(g.payload, "From"))
        let (html, text) = bodies(of: g.payload)
        let dateMs = Double(g.internalDate ?? "0") ?? 0
        let msg = Message(
            accountId: accountId,
            id: g.id,
            threadId: g.threadId,
            fromName: from.name,
            fromEmail: from.email,
            toList: header(g.payload, "To"),
            ccList: header(g.payload, "Cc"),
            date: Date(timeIntervalSince1970: dateMs / 1000),
            snippet: decodeEntities(g.snippet ?? ""),
            bodyHTML: html,
            bodyText: text,
            isUnread: g.labelIds?.contains(GmailLabels.unread) ?? false,
            messageIdHeader: header(g.payload, "Message-ID"),
            referencesHeader: header(g.payload, "References"),
            listUnsubscribe: header(g.payload, "List-Unsubscribe"),
            listUnsubscribePost: header(g.payload, "List-Unsubscribe-Post"),
            isDraft: g.labelIds?.contains(GmailLabels.draft) ?? false
        )
        return (msg, g.labelIds ?? [], attachments(of: g, accountId: accountId))
    }

    /// Parts with a filename are attachments. Inline images count too even
    /// when the filename is empty — Apple Mail and Gmail both send pasted
    /// pictures that way, and without a row here the body's `cid:` reference
    /// has no part to fetch, so the image renders as a hole.
    static func attachments(of g: GMessage, accountId: String) -> [Attachment] {
        var found: [Attachment] = []
        func walk(_ p: GPart?) {
            guard let p else { return }
            let mime = p.mimeType ?? "application/octet-stream"
            let cid = contentId(of: p)
            let name = p.filename ?? ""
            if !name.isEmpty || (!cid.isEmpty && mime.hasPrefix("image/")) {
                let partId = p.partId ?? String(found.count)
                found.append(Attachment(
                    accountId: accountId, messageId: g.id,
                    partId: partId,
                    filename: name.isEmpty ? placeholderName(mime: mime, partId: partId) : name,
                    mimeType: mime,
                    size: p.body?.size ?? 0,
                    contentId: cid))
            }
            p.parts?.forEach { walk($0) }
        }
        walk(g.payload)
        return found
    }

    /// A name for a nameless inline image, so saving it somewhere lands a
    /// file with a sensible extension.
    private static func placeholderName(mime: String, partId: String) -> String {
        let ext = mime.split(separator: "/").last.map(String.init) ?? "img"
        return "image-\(partId).\(ext)"
    }

    /// The part's Content-ID with the angle brackets peeled off — this is what
    /// the HTML body's `cid:` references point at.
    static func contentId(of part: GPart) -> String {
        header(part, "Content-ID")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Splits plain text into (new content, quoted trail) at the first
    /// quote marker, so replies can collapse the history.
    public static func splitQuoted(_ text: String) -> (main: String, quoted: String?) {
        let lines = text.components(separatedBy: "\n")
        var cut: Int?
        var sawContent = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            let isMarker = t.hasPrefix(">")
                || (t.hasPrefix("On ") && t.hasSuffix("wrote:"))
                || t.hasPrefix("-----Original Message-----")
                || t.hasPrefix("---------- Forwarded message")
            if isMarker {
                // Only fold when there's real content above the quote trail
                if sawContent { cut = i }
                break
            }
            if !t.isEmpty { sawContent = true }
        }
        guard let cut else { return (text, nil) }
        return (lines[..<cut].joined(separator: "\n"),
                lines[cut...].joined(separator: "\n"))
    }

    public static func subject(of g: GMessage) -> String {
        header(g.payload, "Subject")
    }

    /// Crude HTML → searchable/preview text.
    public static func stripHTML(_ html: String) -> String {
        var s = html
        // drop <style>/<script> blocks entirely
        for tag in ["style", "script", "head"] {
            while let r = s.range(of: "<\(tag)[\\s\\S]*?</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r)
            }
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

// MARK: - Split-inbox category

public enum ThreadCategory {
    /// Precedence: personal/starred/important → important, then promotions,
    /// updates, social/forums. Uncategorized mail counts as important.
    public static func derive(from labelIds: Set<String>) -> String {
        if labelIds.contains(GmailLabels.categoryPersonal)
            || labelIds.contains(GmailLabels.starred)
            || labelIds.contains(GmailLabels.important) {
            return "important"
        }
        if labelIds.contains(GmailLabels.categoryPromotions) { return "newsletters" }
        if labelIds.contains(GmailLabels.categoryUpdates) { return "updates" }
        if labelIds.contains(GmailLabels.categorySocial)
            || labelIds.contains(GmailLabels.categoryForums) {
            return "other"
        }
        return "important"
    }
}
