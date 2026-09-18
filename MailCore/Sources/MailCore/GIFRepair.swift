import Foundation
import ImageIO

/// ImageIO — and so WebKit — refuses some perfectly valid GIFs: a large,
/// flat frame (a newsletter's blank 2000×2667 first frame is enough) comes
/// back undecodable, and one bad frame blanks the whole picture. The frames
/// it *can* decode are composited full-canvas already, so re-encoding just
/// those gives a GIF it will draw.
public enum GIFRepair {
    /// A re-encoded copy when some frames fail and others don't; nil when
    /// there's nothing to fix (not a GIF, every frame decodes) or nothing to
    /// salvage.
    public static func repaired(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              (CGImageSourceGetType(src) as String?) == "com.compuserve.gif" else { return nil }
        let count = CGImageSourceGetCount(src)
        var frames: [(CGImage, Double)] = []
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            frames.append((image, delay))
        }
        guard !frames.isEmpty, frames.count < count else { return nil }

        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "com.compuserve.gif" as CFString,
                                                         frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary:
                                                [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, delay) in frames {
            CGImageDestinationAddImage(dst, image, [kCGImagePropertyGIFDictionary:
                                                      [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
