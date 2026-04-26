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

    // Called on main thread when the stream stops unexpectedly.
    var onError: ((Error) -> Void)?

    init(windowID: CGWindowID, vdUUID: String) {
        self.windowID = windowID
        self.vdUUID   = vdUUID
    }

    // MARK: - Start

    func start(completion: @escaping (Error?) -> Void) {
        // Look up the live SCWindow by ID
        SCShareableContent.getExcludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) { [weak self] content, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(error) }
                return
            }
            guard let content,
                  let scWindow = content.windows.first(where: {
                      CGWindowID($0.windowID) == self.windowID
                  })
            else {
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
    }
}

// MARK: - SCStreamDelegate

extension WindowCapture: SCStreamDelegate {

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        stopped = true
        self.stream = nil
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }
}
