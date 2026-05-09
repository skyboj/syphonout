import Foundation

/// Registry of active window and display capture sessions.
///
/// - Window captures: keyed by CGWindowID — each window routes to one VD at a time.
/// - Display captures: keyed by CGDirectDisplayID — each physical display routes to one VD.
///
/// All public methods must be called on the main thread.
final class WindowCaptureManager {

    static let shared = WindowCaptureManager()
    private init() {}

    // MARK: - State

    private var captures:        [CGWindowID: WindowCapture]          = [:]
    private var displayCaptures: [CGDirectDisplayID: DisplayCapture]  = [:]

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
        for (_, capture) in captures { capture.stop() }
        captures.removeAll()
        for (_, capture) in displayCaptures { capture.stop() }
        displayCaptures.removeAll()
    }

    // MARK: - Display capture API

    /// Start capturing the full physical display `displayID` and routing frames to `vdUUID`.
    /// Any existing capture for that display is stopped first.
    func startDisplayCapture(displayID: CGDirectDisplayID,
                             vdUUID: String,
                             completion: @escaping (Error?) -> Void) {
        AppLog.shared.info("Manager.startDisplayCapture displayID=\(displayID) → vd=\(vdUUID.prefix(8))…", category: "Capture")
        stopDisplayCapture(displayID: displayID)

        let capture = DisplayCapture(displayID: displayID, vdUUID: vdUUID)
        capture.onError = { [weak self] error in
            self?.displayCaptures.removeValue(forKey: displayID)
        }

        displayCaptures[displayID] = capture
        capture.start { [weak self] error in
            if let error {
                self?.displayCaptures.removeValue(forKey: displayID)
                completion(error)
            } else {
                completion(nil)
            }
        }
    }

    /// Stop any active display capture for `displayID`.
    func stopDisplayCapture(displayID: CGDirectDisplayID) {
        displayCaptures[displayID]?.stop()
        displayCaptures.removeValue(forKey: displayID)
    }

    func isCapturingDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        displayCaptures[displayID] != nil
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

    // MARK: - Reverse lookup (by VD UUID)

    /// Returns the window ID currently being captured for `vdUUID`, or nil.
    func capturedWindow(for vdUUID: String) -> CGWindowID? {
        captures.first(where: { $0.value.vdUUID == vdUUID })?.key
    }

    /// Returns the display ID currently being captured for `vdUUID`, or nil.
    func capturedDisplay(for vdUUID: String) -> CGDirectDisplayID? {
        displayCaptures.first(where: { $0.value.vdUUID == vdUUID })?.key
    }

    /// True if any capture (window or display) is routing to `vdUUID`.
    func isCapturingVD(_ vdUUID: String) -> Bool {
        capturedWindow(for: vdUUID) != nil || capturedDisplay(for: vdUUID) != nil
    }

    /// Stops any window capture for `vdUUID`.
    func stopWindowCapture(for vdUUID: String) {
        if let wid = capturedWindow(for: vdUUID) {
            stopCapture(windowID: wid)
        }
    }

    /// Stops any display capture for `vdUUID`.
    func stopDisplayCapture(for vdUUID: String) {
        if let did = capturedDisplay(for: vdUUID) {
            stopDisplayCapture(displayID: did)
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let windowCaptureStarted = Notification.Name("SyphonOutWindowCaptureStarted")
    static let windowCaptureStopped = Notification.Name("SyphonOutWindowCaptureStopped")
}
