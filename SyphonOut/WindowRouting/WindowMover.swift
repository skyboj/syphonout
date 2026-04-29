import AppKit

/// Moves a window (identified by a WindowInfo snapshot) to a target NSScreen
/// using the macOS Accessibility API (AXUIElement).
///
/// Coordinate systems:
///   • SCWindow.frame / CGWindowListCopyWindowInfo → Quartz: origin top-left of
///     primary screen, Y increases downward.
///   • NSScreen.frame → AppKit: origin bottom-left of primary screen, Y increases upward.
///   • kAXPositionAttribute → Quartz (same as SCWindow.frame), so we pass
///     SCWindow coordinates directly when setting position.
///   • kAXSizeAttribute → plain width/height, no coordinate flip needed.
enum WindowMover {

    // MARK: - Result

    enum MoveResult {
        case success
        case noAccessibility         // AXIsProcessTrusted() returned false
        case windowNotFound          // could not match AXUIElement to the WindowInfo
        case axError(AXError)        // underlying AX call failed
    }

    // MARK: - Public API

    /// Moves `window` to `screen`.
    ///
    /// - Parameters:
    ///   - window: Snapshot from WindowInventory.
    ///   - screen: Destination NSScreen.
    ///   - resize: If true, resize to fill the destination screen.
    ///             If false (default), size is preserved — UNLESS the window
    ///             was already filling its source screen (≥85% area coverage),
    ///             in which case it is automatically scaled to fill the new screen.
    @discardableResult
    static func move(_ window: WindowInfo,
                     to screen: NSScreen,
                     resize: Bool = false) -> MoveResult {

        guard AXIsProcessTrusted() else { return .noAccessibility }

        let app = AXUIElementCreateApplication(window.pid)

        var rawWindows: CFTypeRef?
        let listErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
        guard listErr == .success, let windowList = rawWindows as? [AXUIElement] else {
            return .axError(listErr)
        }

        guard let axWindow = findAXWindow(in: windowList, matching: window) else {
            return .windowNotFound
        }

        // Determine whether to resize:
        // • explicit resize: always fill destination
        // • auto: fill destination only if window is already filling its source screen
        let shouldResize = resize || isFillingSourceScreen(window.frame)

        // Target position: top-left of destination screen in Quartz coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let targetOrigin = CGPoint(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY   // AppKit→Quartz Y flip
        )

        // 1. Set position first (move before resize avoids brief off-screen flash)
        var point = targetOrigin
        if let posValue = AXValueCreate(.cgPoint, &point) {
            let err = AXUIElementSetAttributeValue(axWindow,
                                                   kAXPositionAttribute as CFString,
                                                   posValue)
            if err != .success { return .axError(err) }
        }

        // 2. Resize if needed
        if shouldResize {
            var size = screen.frame.size
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                let err = AXUIElementSetAttributeValue(axWindow,
                                                       kAXSizeAttribute as CFString,
                                                       sizeValue)
                if err != .success { return .axError(err) }
            }
        }

        return .success
    }

    // MARK: - Source screen fill detection

    /// Returns true if `frame` (Quartz coords) covers ≥85% of the screen it sits on.
    /// Used to auto-scale windows that are effectively fullscreen on their source display.
    private static func isFillingSourceScreen(_ frame: CGRect) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        for screen in NSScreen.screens {
            // Convert NSScreen frame to Quartz coordinates
            let screenQuartz = CGRect(
                x: screen.frame.minX,
                y: primaryHeight - screen.frame.minY - screen.frame.height,
                width:  screen.frame.width,
                height: screen.frame.height
            )
            guard screenQuartz.intersects(frame) else { continue }

            let screenArea = screenQuartz.width * screenQuartz.height
            guard screenArea > 0 else { continue }

            // Coverage = intersection area / screen area
            let intersection = screenQuartz.intersection(frame)
            let coverage = (intersection.width * intersection.height) / screenArea
            if coverage >= 0.85 { return true }
        }
        return false
    }

    // MARK: - AXUIElement matching

    /// Finds the AXUIElement window that best matches `info` by comparing
    /// position and size (within a tolerance) and optionally title.
    ///
    /// SCWindow.frame is in Quartz coordinates; AX position is also Quartz.
    private static func findAXWindow(in windows: [AXUIElement],
                                     matching info: WindowInfo) -> AXUIElement? {

        let tolerance: CGFloat = 4   // pixels; handles sub-pixel rounding

        for axWin in windows {
            // Read AX position
            var rawPos: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &rawPos) == .success,
                  let posVal = rawPos
            else { continue }

            var axPos = CGPoint.zero
            guard AXValueGetValue(posVal as! AXValue, .cgPoint, &axPos) else { continue }

            // Read AX size
            var rawSize: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &rawSize) == .success,
                  let sizeVal = rawSize
            else { continue }

            var axSize = CGSize.zero
            guard AXValueGetValue(sizeVal as! AXValue, .cgSize, &axSize) else { continue }

            // info.frame is already in Quartz coords (from SCWindow.frame)
            let framePos  = CGPoint(x: info.frame.minX, y: info.frame.minY)
            let frameSize = info.frame.size

            let posMatch  = abs(axPos.x - framePos.x)  < tolerance &&
                            abs(axPos.y - framePos.y)  < tolerance
            let sizeMatch = abs(axSize.width  - frameSize.width)  < tolerance &&
                            abs(axSize.height - frameSize.height) < tolerance

            if posMatch && sizeMatch {
                // Optionally verify title for extra confidence (some apps have
                // windows at identical positions, e.g. inspector panels)
                if !info.title.isEmpty {
                    var rawTitle: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &rawTitle) == .success,
                       let axTitle = rawTitle as? String,
                       !axTitle.isEmpty,
                       axTitle != info.title {
                        continue   // title mismatch — keep searching
                    }
                }
                return axWin
            }
        }
        return nil
    }

    // MARK: - Raise window

    /// Brings a window to the front (raises it) without moving it.
    @discardableResult
    static func raise(_ window: WindowInfo) -> MoveResult {
        guard AXIsProcessTrusted() else { return .noAccessibility }

        let app = AXUIElementCreateApplication(window.pid)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windowList = rawWindows as? [AXUIElement],
              let axWin = findAXWindow(in: windowList, matching: window)
        else { return .windowNotFound }

        let err = AXUIElementSetAttributeValue(axWin,
                                               kAXMainAttribute as CFString,
                                               kCFBooleanTrue)
        return err == .success ? .success : .axError(err)
    }
}
