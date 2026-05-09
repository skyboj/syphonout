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
///   • Slide Show window appears  → start window capture (Slot 0)
///                                  → start MacBook display capture (Slot 1)
///   • Slide Show window goes away → stop both captures
///                                  → confidence monitor returns to native
///   • PPT quits / relaunches      → watcher re-converges automatically

import Foundation
import os.log

final class PowerPointPreset {

    static let shared = PowerPointPreset()

    private(set) var isActive = false

    private let inventory  = WindowInventory()

    /// Built-in display ID currently captured for Presenter View. nil = not started.
    private var presenterDisplayID: CGDirectDisplayID?

    private init() {}

    // MARK: - Toggle

    func toggle() { isActive ? deactivate() : activate() }

    // MARK: - Activate / Deactivate

    func activate() {
        guard !isActive else { return }
        isActive = true
        AppLog.shared.info("PowerPoint preset activated", category: "PPTPreset")

        // Ensure VDs are in Signal mode so output windows actually show.
        for vd in VirtualDisplayManager.shared.displays {
            VirtualDisplayManager.shared.setMode(vdId: vd.id, mode: SYPHON_OUT_MODE_SIGNAL)
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

        // Stop display capture for Presenter View soft-mirror.
        if let id = presenterDisplayID {
            WindowCaptureManager.shared.stopDisplayCapture(displayID: id)
        }
        presenterDisplayID = nil
    }

    // MARK: - Reconciliation (called on every inventory refresh)

    private func reconcile(_ windows: [WindowInfo]) {
        let ppt = windows.filter { isPowerPoint($0) }
        let slideShowWindow = ppt.first(where: { isSlideShow($0) })
        let slideshowActive = slideShowWindow != nil

        // Soft-mirror: capture MacBook display into the VD that is assigned to
        // an EXTERNAL physical display (≠ built-in).  When slideshow is active,
        // start the capture; when it ends, stop it so the confidence monitor
        // returns to its native content.
        //
        // We pick the target VD by looking at which non-builtin display has a
        // VD assigned — that's the confidence monitor.  No need for a fixed
        // VD[0]/VD[1] index scheme.
        if slideshowActive, let vdID = confidenceVDID() {
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

    /// Captures the MacBook's built-in display while a Slide Show is running,
    /// so the confidence monitor shows a soft-mirror of Presenter View.
    private func applyPresenterCapture(vdID: String) {
        guard presenterDisplayID == nil else { return }   // already capturing

        guard let builtinID = builtInDisplayID() else {
            AppLog.shared.warn("PPT preset: no built-in display found — Presenter View capture skipped", category: "PPTPreset")
            return
        }

        AppLog.shared.info("PPT preset: slideshow active → start MacBook display capture (\(builtinID)) → VD \(vdID)", category: "PPTPreset")
        presenterDisplayID = builtinID

        WindowCaptureManager.shared.startDisplayCapture(displayID: builtinID, vdUUID: vdID) { [weak self] error in
            if let error {
                AppLog.shared.error("PPT preset: built-in display capture failed: \(error.localizedDescription)", category: "PPTPreset")
                self?.presenterDisplayID = nil   // allow retry
            }
        }
    }

    private func stopPresenterCapture() {
        guard let id = presenterDisplayID else { return }
        AppLog.shared.info("PPT preset: slideshow ended → stop MacBook display capture", category: "PPTPreset")
        WindowCaptureManager.shared.stopDisplayCapture(displayID: id)
        presenterDisplayID = nil
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
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
