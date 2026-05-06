import AppKit
import ScreenCaptureKit
import CoreVideo
import IOSurface

/// Captures an entire physical display via SCStream and routes each frame
/// to a Virtual Display via `syphonout_on_new_frame_vd`.
///
/// Used by PowerPointPreset to capture the MacBook's built-in display
/// (showing Presenter View) and route it to a confidence monitor.
///
/// Lifecycle: call `start(completion:)` → frames flow → call `stop()`.
/// Single-use; create a new instance to restart.
final class DisplayCapture: NSObject {

    let displayID: CGDirectDisplayID
    let vdUUID:    String

    private var stream:      SCStream?
    private let frameQueue = DispatchQueue(
        label: "com.syphonout.DisplayCapture.frames", qos: .userInteractive)
    private var stopped = false

    /// Called on main thread when the stream stops unexpectedly.
    var onError: ((Error) -> Void)?

    init(displayID: CGDirectDisplayID, vdUUID: String) {
        self.displayID = displayID
        self.vdUUID    = vdUUID
    }

    // MARK: - Start

    func start(completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(
            true, onScreenWindowsOnly: false
        ) { [weak self] content, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(error) }
                return
            }
            guard let scDisplay = content?.displays.first(where: { $0.displayID == self.displayID }) else {
                DispatchQueue.main.async {
                    completion(NSError(
                        domain: "DisplayCapture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Display \(self.displayID) not found in shareable content"]
                    ))
                }
                return
            }
            self.createStream(scDisplay: scDisplay, completion: completion)
        }
    }

    private func createStream(scDisplay: SCDisplay, completion: @escaping (Error?) -> Void) {
        // Capture the full display excluding nothing (empty exclusion lists = capture everything).
        let filter = SCContentFilter(display: scDisplay,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        let cfg = SCStreamConfiguration()

        // Determine backing scale factor from the corresponding NSScreen.
        let scale = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        })?.backingScaleFactor ?? 1.0

        // scDisplay.width/height are in points; multiply by scale for pixels.
        cfg.width  = max(1, Int(CGFloat(scDisplay.width)  * scale))
        cfg.height = max(1, Int(CGFloat(scDisplay.height) * scale))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth  = 3
        cfg.showsCursor = true   // Presenter View: speaker moves the mouse; keep cursor visible
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            DispatchQueue.main.async { completion(error) }
            return
        }

        s.startCapture { [weak self] error in
            DispatchQueue.main.async {
                if error == nil { self?.stream = s }
                completion(error)
            }
        }
    }

    // MARK: - Stop

    func stop() {
        guard !stopped else { return }
        stopped = true
        stream?.stopCapture { _ in }
        stream = nil
    }
}

// MARK: - SCStreamOutput

extension DisplayCapture: SCStreamOutput {

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, !stopped else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let ioSurface   = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        let width  = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let height = UInt32(CVPixelBufferGetHeight(pixelBuffer))

        let rawPtr = Unmanaged.passUnretained(ioSurface).toOpaque()
        vdUUID.withCString { vdC in
            syphonout_on_new_frame_vd(vdC, rawPtr, width, height)
        }
    }
}

// MARK: - SCStreamDelegate

extension DisplayCapture: SCStreamDelegate {

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        stopped = true
        self.stream = nil
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }
}
