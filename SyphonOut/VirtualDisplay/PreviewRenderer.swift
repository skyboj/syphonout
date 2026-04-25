import AppKit
import CoreImage
import IOSurface

/// Generates menu-thumbnail NSImages for Virtual Displays.
///
/// Strategy per mode:
///   Signal / Freeze  — IOSurface from Rust (zero-copy via CIImage → GPU scale)
///   Blank Black      — solid black rectangle
///   Blank White      — solid white rectangle
///   Test Pattern     — SMPTE colour bars drawn with AppKit
///   Off              — nil (no thumbnail shown)
enum PreviewRenderer {

    static let thumbnailSize = CGSize(width: 160, height: 90)

    /// Return a 160×90 NSImage for the given VD, or nil if nothing to show.
    static func thumbnail(for vd: VirtualDisplay) -> NSImage? {
        switch vd.mode {
        case SYPHON_OUT_MODE_BLANK_BLACK:
            return solidColor(NSColor.black)
        case SYPHON_OUT_MODE_BLANK_WHITE:
            return solidColor(NSColor.white)
        case SYPHON_OUT_MODE_BLANK_TEST_PATTERN:
            return smpteBars()
        case SYPHON_OUT_MODE_OFF:
            return nil
        default:
            // Signal or Freeze — try to grab the latest IOSurface frame.
            return iosurfaceThumbnail(for: vd.id)
        }
    }

    // MARK: - IOSurface path (Signal / Freeze)

    /// Shared GPU-backed CIContext — created once, reused for every thumbnail.
    private static let ciContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        ])
    }()

    private static func iosurfaceThumbnail(for vdId: String) -> NSImage? {
        guard let rawPtr: UnsafeMutableRawPointer =
            vdId.withCString({ syphonout_vd_get_iosurface($0) }) else { return nil }

        // takeRetainedValue() consumes the +1 CFRetain Rust added for us.
        let surface = Unmanaged<IOSurface>.fromOpaque(rawPtr).takeRetainedValue()
        let sourceImage = CIImage(ioSurface: surface)

        let srcW = sourceImage.extent.width
        let srcH = sourceImage.extent.height
        guard srcW > 0, srcH > 0 else { return nil }

        let scale  = min(thumbnailSize.width / srcW, thumbnailSize.height / srcH)
        let scaledW = (srcW * scale).rounded()
        let scaledH = (srcH * scale).rounded()
        let tx = ((thumbnailSize.width  - scaledW) / 2).rounded()
        let ty = ((thumbnailSize.height - scaledH) / 2).rounded()

        let transformed = sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        let outputRect = CGRect(origin: .zero, size: thumbnailSize)
        guard let cg = ciContext.createCGImage(transformed, from: outputRect) else { return nil }
        return NSImage(cgImage: cg, size: thumbnailSize)
    }

    // MARK: - Solid colour

    private static func solidColor(_ color: NSColor) -> NSImage {
        NSImage(size: thumbnailSize, flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    // MARK: - SMPTE colour bars

    /// Classic 7-bar SMPTE pattern: top 75 % bars + bottom strip.
    private static func smpteBars() -> NSImage {
        NSImage(size: thumbnailSize, flipped: false) { rect in
            let w = rect.width
            let h = rect.height

            // Top 75 % — 7 equal columns
            let barH   = (h * 0.75).rounded()
            let barW   = (w / 7).rounded()
            let topColors: [NSColor] = [
                NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.75, alpha: 1), // 75 % White
                NSColor(calibratedRed: 0.75, green: 0.75, blue: 0,    alpha: 1), // Yellow
                NSColor(calibratedRed: 0,    green: 0.75, blue: 0.75, alpha: 1), // Cyan
                NSColor(calibratedRed: 0,    green: 0.75, blue: 0,    alpha: 1), // Green
                NSColor(calibratedRed: 0.75, green: 0,    blue: 0.75, alpha: 1), // Magenta
                NSColor(calibratedRed: 0.75, green: 0,    blue: 0,    alpha: 1), // Red
                NSColor(calibratedRed: 0,    green: 0,    blue: 0.75, alpha: 1), // Blue
            ]
            for (i, color) in topColors.enumerated() {
                let x = (CGFloat(i) * barW).rounded()
                let barRect = NSRect(x: x, y: h - barH, width: barW, height: barH)
                color.setFill()
                barRect.fill()
            }

            // Bottom 25 % — simplified: black / white / black strip
            let botH = h - barH
            let segments: [(CGFloat, NSColor)] = [
                (w * 0.40, NSColor.black),
                (w * 0.20, NSColor.white),
                (w * 0.40, NSColor.black),
            ]
            var x: CGFloat = 0
            for (segW, color) in segments {
                let segRect = NSRect(x: x.rounded(), y: 0, width: segW.rounded(), height: botH)
                color.setFill()
                segRect.fill()
                x += segW
            }
            return true
        }
    }
}
