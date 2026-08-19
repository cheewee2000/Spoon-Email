import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MailCore

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// An image sitting inline in the composer's text. Carries the `cid` the HTML
/// body will point at, so the serializer can emit `<img src="cid:…">` and the
/// MIME builder can ship the bytes in the matching part.
final class InlineImageAttachment: NSTextAttachment {
    let payload: ComposeAttachment

    init(payload: ComposeAttachment, image: PlatformImage, maxWidth: CGFloat = 420) {
        self.payload = payload
        super.init(data: nil, ofType: nil)
        self.image = image
        let size = image.size
        let scale = size.width > maxWidth ? maxWidth / size.width : 1
        bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Turns dropped items into inline images: reads the bytes, shrinks anything
/// oversized, and hands back both the wire payload and something to draw.
enum InlineImageLoader {
    /// Full-resolution photos make for multi-megabyte mail, so anything larger
    /// than this gets resampled before it goes on the wire.
    private static let maxPixels: CGFloat = 1800
    private static let recompressAbove = 1_200_000

    /// Decodes attachment bytes for display, without touching them — a
    /// reopened draft has to keep the exact part it was saved with.
    static func image(from data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    static func supported(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Loads every image among the providers, in drop order.
    static func load(_ providers: [NSItemProvider]) async -> [(ComposeAttachment, PlatformImage)] {
        var out: [(ComposeAttachment, PlatformImage)] = []
        for provider in providers where supported(provider) {
            guard let (data, name) = await rawData(provider) else { continue }
            guard let loaded = prepare(data: data, filename: name) else { continue }
            out.append(loaded)
        }
        return out
    }

    /// Reads a provider's bytes. `loadFileRepresentation` covers both Finder
    /// drops and in-memory images (which it spools to a temp file), and it
    /// gives us the original filename for free.
    private static func rawData(_ provider: NSItemProvider) async -> (Data, String)? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: ((Data, String)?) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                // The URL only lives for the length of this callback.
                guard let url, let data = try? Data(contentsOf: url) else {
                    finish(nil)
                    return
                }
                finish((data, url.lastPathComponent))
            }
        }
    }

    /// Decodes, downsamples when needed, and picks the MIME type from the
    /// actual bytes rather than trusting the file extension.
    static func prepare(data: Data, filename: String) -> (ComposeAttachment, PlatformImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let sourceType = CGImageSourceGetType(source) as String?
        let sourceUTType = sourceType.flatMap { UTType($0) }
        let widest = CGFloat(max(cgImage.width, cgImage.height))

        var finalImage = cgImage
        var needsReencode = false
        if widest > maxPixels, let smaller = resample(cgImage, scale: maxPixels / widest) {
            finalImage = smaller
            needsReencode = true
        }
        if data.count > recompressAbove { needsReencode = true }

        var bytes = data
        var mimeType = sourceUTType?.preferredMIMEType ?? "image/png"
        var name = filename.isEmpty ? "image" : filename
        if needsReencode {
            // JPEG unless the image relies on transparency, which it would eat.
            let keepAlpha = finalImage.alphaInfo != .none
                && finalImage.alphaInfo != .noneSkipFirst
                && finalImage.alphaInfo != .noneSkipLast
            let type: UTType = keepAlpha ? .png : .jpeg
            if let encoded = encode(finalImage, as: type) {
                bytes = encoded
                mimeType = type.preferredMIMEType ?? mimeType
                name = (name as NSString).deletingPathExtension
                    + "." + (type.preferredFilenameExtension ?? "jpg")
            }
        }

        #if os(macOS)
        let image = NSImage(cgImage: finalImage,
                            size: NSSize(width: finalImage.width, height: finalImage.height))
        #else
        let image = UIImage(cgImage: finalImage)
        #endif
        return (ComposeAttachment(filename: name, mimeType: mimeType, data: bytes), image)
    }

    private static func resample(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}


/// Reads non-image drops (PDFs, zips, documents…) into regular attachments.
/// Mirrors `InlineImageLoader` but keeps the bytes as they are.
enum FileAttachmentLoader {
    /// Anything that is a file's worth of data. Folders and promises (which
    /// only conform to `item`) are left to bounce back.
    static func supported(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
    }

    static func load(_ providers: [NSItemProvider]) async -> [ComposeAttachment] {
        var out: [ComposeAttachment] = []
        for provider in providers where supported(provider) {
            guard let (data, name) = await rawData(provider), !data.isEmpty else { continue }
            let ext = (name as NSString).pathExtension
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            out.append(ComposeAttachment(filename: name.isEmpty ? "attachment" : name,
                                         mimeType: mime, data: data, isInline: false))
        }
        return out
    }

    /// The most specific registered type that is real data — a Finder drop
    /// registers the file's own type ahead of `public.file-url`, so asking
    /// for that one gets the file itself rather than a URL blob.
    private static func rawData(_ provider: NSItemProvider) async -> (Data, String)? {
        let concrete = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
        let typeId = concrete?.identifier ?? UTType.data.identifier
        let fallbackName = provider.suggestedName ?? ""
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: ((Data, String)?) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    finish(nil)
                    return
                }
                finish((data, fallbackName.isEmpty ? url.lastPathComponent : fallbackName))
            }
        }
    }
}
