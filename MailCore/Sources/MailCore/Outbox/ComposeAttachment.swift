import Foundation

/// An image (or file) the composer carries into the outgoing message.
///
/// Inline ones are referenced from the HTML body as `cid:<id>` and shipped in a
/// `multipart/related` part, so they render in place instead of hanging off the
/// bottom of the mail.
public struct ComposeAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String        // Content-ID, without the angle brackets
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var isInline: Bool

    public init(id: String = UUID().uuidString + "@spoon.local",
                filename: String,
                mimeType: String,
                data: Data,
                isInline: Bool = true) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.isInline = isInline
    }

    /// Gmail takes the raw message as JSON, so base64 bloat counts against the
    /// request. Well under the API's ceiling, and roughly what mail servers
    /// accept anyway.
    public static let totalByteLimit = 8 * 1024 * 1024
}
