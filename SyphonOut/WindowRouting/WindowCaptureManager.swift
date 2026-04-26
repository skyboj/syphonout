import Foundation

/// Registry of active WindowCapture sessions.
/// Keyed by CGWindowID so each window can only route to one VD at a time.
/// All public methods must be called on the main thread.
final class WindowCaptureManager {

    static let shared = WindowCaptureManager()
    private init() {}

    // MARK: - State

    private var captures: [CGWindowID: WindowCapture] = [:]

    // MARK: - Public API

    /// Start capturing `windowID` and routing frames to `vdUUID`.
    /// Any existing capture for that window is stopped first.
    /// `completion` is called on the main thread with nil on success.
    func startCapture(windowID: CGWindowID,
                      vdUUID: String,
                      completion: @escaping (Error?) -> Void) {
        stopCapture(windowID: windowID)

        let capture = WindowCapture(windowID: windowID, vdUUID: vdUUID)
        capture.onError = { [weak self] error in
            self?.captures.removeValue(forKey: windowID)
            NotificationCenter.default.post(
                name: .windowCaptureStopped,
                object: nil,
                userInfo: ["windowID": windowID, "error": error]
            )
        }

        captures[windowID] = capture
        capture.start { [weak self] error in
            if let error {
                self?.captures.removeValue(forKey: windowID)
                completion(error)
            } else {
                completion(nil)
                NotificationCenter.default.post(
                    name: .windowCaptureStarted,
                    object: nil,
                    userInfo: ["windowID": windowID, "vdUUID": vdUUID]
                )
            }
        }
    }

    /// Stop any active capture for `windowID`.
    func stopCapture(windowID: CGWindowID) {
        captures[windowID]?.stop()
        captures.removeValue(forKey: windowID)
        NotificationCenter.default.post(
            name: .windowCaptureStopped,
            object: nil,
            userInfo: ["windowID": windowID]
        )
    }

    /// Stop all active captures (e.g. on quit or VD destruction).
    func stopAll() {
        for (id, capture) in captures { capture.stop(); _ = id }
        captures.removeAll()
    }

    // MARK: - Query

    func isCapturing(_ windowID: CGWindowID) -> Bool {
        captures[windowID] != nil
    }

    /// Returns the VD UUID that `windowID` is currently routing to, or nil.
    func vdUUID(for windowID: CGWindowID) -> String? {
        captures[windowID]?.vdUUID
    }

    /// All currently-captured window IDs.
    var capturedWindowIDs: Set<CGWindowID> {
        Set(captures.keys)
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let windowCaptureStarted = Notification.Name("SyphonOutWindowCaptureStarted")
    static let windowCaptureStopped = Notification.Name("SyphonOutWindowCaptureStopped")
}
