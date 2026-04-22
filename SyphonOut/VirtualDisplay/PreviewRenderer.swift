import AppKit
import CoreImage
import IOSurface

/// Generates menu-thumbnail NSImages for Virtual Displays.
///
/// Flow:
///   1. Ask Rust for the VD's current IOSurface (+1 retained via CFRetain).
///   2. Take ownership via Unmanaged.takeRetainedValue() — ARC releases at scope exit.
///   3. Wrap in CIImage (zero-copy — CIImage retains the IOSurface internally).
///   4. GPU-scale to 160×90 via shared CIContext (Metal backend).
///   5. Return NSImage for the menu item.
///
/// The CIContext is created once and reused — context creation is expensive,
/// rendering a 160×90 thumbnail is cheap (~0.1 ms on M1).
enum PreviewRenderer {

    /// Target thumbnail size shown in the menu.
    static let thumbnailSize = CGSize(width: 160, height: 90)

    /// Shared GPU-backed CIContext. Lazy so it's created on first preview request.
    private static let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        ]
        return CIContext(options: options)
    }()

    /// Return a 160×90 NSImage for `vdId`, or nil if no frame has arrived yet.
    ///
    /// Call from the main thread on menu open — CIContext.createCGImage is
    /// synchronous but fast enough for thumbnail size (~0.1–0.5 ms).
    static func thumbnail(for vdId: String) -> NSImage? {
        // Rust returns the IOSurface with a +1 CFRetain so we can safely use it
        // even if the VD receives a new frame and releases its own reference.
        // takeRetainedValue() hands ARC ownership of that +1 — no CFRelease needed.
        guard let rawPtr: UnsafeMutableRawPointer = vdId.withCString({ syphonout_vd_get_iosurface($0) }) else {
            return nil
        }
        let surface = Unmanaged<IOSurface>.fromOpaque(rawPtr).takeRetainedValue()

        // CIImage backed by the IOSurface — zero pixel copy at this point.
        let sourceImage = CIImage(ioSurface: surface)

        let srcW = sourceImage.extent.width
        let srcH = sourceImage.extent.height
        guard srcW > 0, srcH > 0 else { return nil }

        // Letterbox-fit: scale uniformly so the image fills the thumbnail without clipping.
        let scale = min(thumbnailSize.width / srcW, thumbnailSize.height / srcH)
        let scaledW = (srcW * scale).rounded()
        let scaledH = (srcH * scale).rounded()

        // Centre inside the thumbnail canvas.
        let tx = ((thumbnailSize.width  - scaledW) / 2).rounded()
        let ty = ((thumbnailSize.height - scaledH) / 2).rounded()

        let transformed = sourceImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        let outputRect = CGRect(origin: .zero, size: thumbnailSize)
        guard let cgImage = ciContext.createCGImage(transformed, from: outputRect) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: thumbnailSize)
    }
}
