import AppKit
import ScreenCaptureKit
import CoreVideo
import IOSurface

// MARK: - Errors

enum WindowCaptureError: LocalizedError {
    case windowNotFound
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .windowNotFound:   return "Window is no longer on screen"
        case .streamFailed(let e): return "Stream error: \(e.localizedDescription)"
        }
    }
}

// MARK: - WindowCapture

/// Captures a single on-screen window via SCStream and routes each frame
/// to a Virtual Display via `syphonout_on_new_frame_vd`.
///
/// Lifecycle: call `start(completion:)` → frames flow → call `stop()`.
/// The object is single-use; create a new instance to restart.
final class WindowCapture: NSObject {

    let windowID: CGWindowID
    let vdUUID:   String

    private var stream:      SCStream?
    private let frameQueue = DispatchQueue(
        label: "com.syphonout.WindowCapture.frames", qos: .userInteractive)
    private var stopped = false

    // Frame-rate stats (logged every ~2 seconds to "FrameStats" category).
    private var frameCount: Int = 0
    private var statsWindowStart: Date = Date()

    // Called on main thread when the stream stops unexpectedly.
    var onError: ((Error) -> Void)?

    init(windowID: CGWindowID, vdUUID: String) {
        self.windowID = windowID
        self.vdUUID   = vdUUID
    }

    // MARK: - Start

    func start(completion: @escaping (Error?) -> Void) {
        AppLog.shared.info("WindowCapture.start wid=\(windowID) → vd=\(vdUUID.prefix(8))…", category: "Capture")
        // Look up the live SCWindow by ID.
        // onScreenWindowsOnly: false — must include windows on ALL Spaces/displays
        // so we can capture presentation windows that are on external displays or
        // full-screen Spaces even when the capturing device is on a different Space.
        SCShareableContent.getExcludingDesktopWindows(
            true, onScreenWindowsOnly: false
        ) { [weak self] content, error in
            guard let self else { return }
            if let error {
                AppLog.shared.error("SCShareableContent error: \(error.localizedDescription)", category: "Capture")
                DispatchQueue.main.async { completion(error) }
                return
            }
            guard let content,
                  let scWindow = content.windows.first(where: {
                      CGWindowID($0.windowID) == self.windowID
                  })
            else {
                AppLog.shared.error("WindowCapture: window \(self.windowID) not found in shareable content", category: "Capture")
                DispatchQueue.main.async {
                    completion(WindowCaptureError.windowNotFound)
                }
                return
            }
            self.createStream(scWindow: scWindow, completion: completion)
        }
    }

    private func createStream(scWindow: SCWindow, completion: @escaping (Error?) -> Void) {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        let cfg = SCStreamConfiguration()
        // Use the window's natural point size × the screen's backing scale factor.
        // Fall back to 1× if the screen can't be determined.
        let scale = NSScreen.screens.first(where: {
            $0.frame.intersects(scWindow.frame)
        })?.backingScaleFactor ?? 1.0

        cfg.width  = max(1, Int(scWindow.frame.width  * scale))
        cfg.height = max(1, Int(scWindow.frame.height * scale))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 3
        cfg.showsCursor = false
        // Minimise latency: capture as fast as the window updates
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            DispatchQueue.main.async { completion(error) }
            return
        }

        s.startCapture { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    AppLog.shared.error("WindowCapture.startCapture failed: \(error.localizedDescription)", category: "Capture")
                } else {
                    self?.stream = s
                    self?.statsWindowStart = Date()
                    AppLog.shared.info("WindowCapture stream started (wid=\(self?.windowID ?? 0), \(cfg.width)×\(cfg.height))", category: "Capture")
                }
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
        AppLog.shared.info("WindowCapture.stop wid=\(windowID)", category: "Capture")
    }
}

// MARK: - SCStreamOutput

extension WindowCapture: SCStreamOutput {

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard !stopped else { return }

        // Extract IOSurface — zero-copy; owned by the sample buffer.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        let width  = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let height = UInt32(CVPixelBufferGetHeight(pixelBuffer))

        // The Rust core does CFRetain on the incoming IOSurfaceRef, so it is
        // safe to pass while the sample buffer (and thus the pixel buffer) is
        // still alive on this stack frame.
        let rawPtr = Unmanaged.passUnretained(ioSurface).toOpaque()
        vdUUID.withCString { vdC in
            syphonout_on_new_frame_vd(vdC, rawPtr, width, height)
        }

        recordFrameStat()
    }

    /// Counts frames and emits an FPS log line every 2 seconds.
    private func recordFrameStat() {
        frameCount += 1
        let elapsed = Date().timeIntervalSince(statsWindowStart)
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            AppLog.shared.info(
                String(format: "wid=%u %d frames in %.2fs = %.1f fps", windowID, frameCount, elapsed, fps),
                category: "FrameStats"
            )
            frameCount = 0
            statsWindowStart = Date()
        }
    }
}

// MARK: - SCStreamDelegate

extension WindowCapture: SCStreamDelegate {

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.shared.error("WindowCapture stream stopped with error (wid=\(windowID)): \(error.localizedDescription)", category: "Capture")
        guard !stopped else { return }
        stopped = true
        self.stream = nil
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }
}
