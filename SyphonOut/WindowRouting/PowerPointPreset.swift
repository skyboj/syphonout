/// PowerPoint Presentation Preset
///
/// When active, watches PowerPoint windows and automatically:
///
///   • Captures the Slide Show window into VD[0] for Syphon/OBS routing
///     (no longer moves or fullscreens — user picks the slideshow display
///      directly in PowerPoint's "Set Up Show" dialog)
///
///   • While a Slide Show is running, captures the MacBook built-in display
///     into VD[1] so the confidence monitor (wired to VD[1] via Physical
///     Outputs) shows a soft-mirror of the Presenter View. This is a
///     SyphonOut-level mirror — macOS isn't aware of it, so PowerPoint's
///     internal "break mirrors during slideshow" logic can't tear it down.
///
/// Lifecycle:
///   • Slide Show window appears  → start MacBook display capture (Slot 1)
///   • Slide Show window goes away → stop capture
///                                  → confidence monitor returns to native
///   • PPT quits / relaunches      → watcher re-converges automatically

import Foundation
import os.log

final class PowerPointPreset {

    static let shared = PowerPointPreset()

    private(set) var isActive = false

    private let inventory  = WindowInventory()

    /// Built-in display ID currently captured (display-capture fallback). nil = not started.
    private var presenterDisplayID: CGDirectDisplayID?

    /// VD UUID currently receiving the soft-mirror feed.  Cached so we can
    /// blank it out cleanly when the slideshow ends.
    private var activeVDID: String?

    private init() {}

    // MARK: - Toggle

    func toggle() { isActive ? deactivate() : activate() }

    // MARK: - Activate / Deactivate

    func activate() {
        guard !isActive else { return }
        isActive = true
        AppLog.shared.info("PowerPoint preset activated", category: "PPTPreset")

        // Ensure VDs are in Signal mode so output windows actually show.
        // The confidence VD (assigned to external display) starts in
        // BLANK_BLACK with the "CONFIDENCE / MONITOR" text until a
        // slideshow begins.
        let confidenceID = confidenceVDID()
        for vd in VirtualDisplayManager.shared.displays {
            let mode = vd.id == confidenceID ? SYPHON_OUT_MODE_BLANK_BLACK : SYPHON_OUT_MODE_SIGNAL
            VirtualDisplayManager.shared.setMode(vdId: vd.id, mode: mode)
        }

        inventory.onUpdate = { [weak self] windows in
            DispatchQueue.main.async { self?.reconcile(windows) }
        }
        inventory.start()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        AppLog.shared.info("PowerPoint preset deactivated", category: "PPTPreset")

        inventory.stop()
        inventory.onUpdate = nil

        stopPresenterCapture()
    }

    // MARK: - Reconciliation (called on every inventory refresh)

    private func reconcile(_ windows: [WindowInfo]) {
        let ppt = windows.filter { isPowerPoint($0) }
        let slideShowWindow = ppt.first(where: { isSlideShow($0) })
        let slideshowActive = slideShowWindow != nil

        if slideshowActive, let vdID = confidenceVDID() {
            // Capture the built-in display (which shows Presenter View) into the
            // confidence VD. Display capture is used instead of window capture
            // because ScreenCaptureKit window capture doesn't track sub-layer
            // updates in PowerPoint's Presenter View window.
            applyPresenterCapture(vdID: vdID)
        } else {
            stopPresenterCapture()
        }
    }

    /// Returns the UUID of the VD assigned to the first external (non-builtin)
    /// display.  This is the VD whose output window will become our soft-mirror
    /// target for Presenter View.
    private func confidenceVDID() -> String? {
        for (displayID, vdUUID) in VirtualDisplayManager.shared.assignments {
            if CGDisplayIsBuiltin(displayID) == 0 {
                return vdUUID
            }
        }
        return nil
    }

    // MARK: - Slide Show slot

    // MARK: - Presenter View slot (soft-mirror via display capture)

    /// Captures the built-in display (Presenter View content) into the confidence VD
    /// while slideshow is running. Display capture is used instead of window capture
    /// because ScreenCaptureKit's window capture does not track sub-layer updates
    /// in PowerPoint's Presenter View — all delivered frames reference the same
    /// unchanged IOSurface content.
    private func applyPresenterCapture(vdID: String) {
        // Already capturing for this VD?  Nothing to do.
        if activeVDID == vdID && presenterDisplayID != nil {
            return
        }

        // Set VD to Signal mode so output renders frames.
        VirtualDisplayManager.shared.setMode(vdId: vdID, mode: SYPHON_OUT_MODE_SIGNAL)

        guard let builtinID = builtInDisplayID() else {
            AppLog.shared.warn("PPT preset: no built-in display — soft-mirror skipped", category: "PPTPreset")
            return
        }

        AppLog.shared.info("PPT preset: slideshow active → MacBook display capture (\(builtinID)) → VD \(vdID)", category: "PPTPreset")
        presenterDisplayID = builtinID
        activeVDID = vdID
        WindowCaptureManager.shared.startDisplayCapture(displayID: builtinID, vdUUID: vdID) { [weak self] error in
            if let error {
                AppLog.shared.error("PPT preset: built-in display capture failed: \(error.localizedDescription)", category: "PPTPreset")
                self?.presenterDisplayID = nil
            }
        }
    }

    private func stopPresenterCapture() {
        if let id = presenterDisplayID {
            AppLog.shared.info("PPT preset: slideshow ended → stop MacBook display capture", category: "PPTPreset")
            WindowCaptureManager.shared.stopDisplayCapture(displayID: id)
            presenterDisplayID = nil
            if let vdID = activeVDID {
                VirtualDisplayManager.shared.setMode(vdId: vdID, mode: SYPHON_OUT_MODE_BLANK_BLACK)
            }
        }
        activeVDID = nil
    }

    /// Returns the CGDirectDisplayID of the MacBook's built-in display, if present.
    private func builtInDisplayID() -> CGDirectDisplayID? {
        NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }.first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: - Window identification

    private func isPowerPoint(_ w: WindowInfo) -> Bool {
        w.appName.localizedCaseInsensitiveContains("PowerPoint")
    }

    private func isSlideShow(_ w: WindowInfo) -> Bool {
        w.title.localizedCaseInsensitiveContains("Slide Show")
    }

    private func isPresenterView(_ w: WindowInfo) -> Bool {
        w.title.localizedCaseInsensitiveContains("Presenter View")
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
