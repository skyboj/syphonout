/// PowerPoint Presentation Preset
///
/// When active, automatically routes PowerPoint windows to the right places:
///
///   Slide Show  → moved to the presentation screen + native fullscreen
///                 also captured into VD[0] for Syphon/OBS routing
///
///   Presenter View → NOT moved; instead the entire MacBook built-in display
///                    is captured into VD[1] so a confidence monitor (wired
///                    to VD[1] via Physical Outputs) shows the speaker notes.
///
/// Screen selection for Slide Show:
///   1. If VD[0] is assigned to a physical display → that NSScreen is used.
///   2. Fallback: first external (non-built-in) screen.
///
/// On PPT quit + relaunch:
///   • Slide Show  — re-captured automatically when the new window appears.
///   • Presenter View display capture — runs continuously; survives PPT restarts.
///
/// Activation also sets both target VDs to Signal mode.
/// Deactivation stops only the captures the preset itself started.

import Foundation
import os.log

final class PowerPointPreset {

    static let shared = PowerPointPreset()

    private(set) var isActive = false

    private let inventory  = WindowInventory()
    private let logger     = Logger(subsystem: "com.syphonout.SyphonOut", category: "PPTPreset")

    /// Window ID currently captured for Slide Show. nil = waiting.
    private var slideShowWindowID: CGWindowID?

    /// Built-in display ID currently captured for Presenter View. nil = not started.
    private var presenterDisplayID: CGDirectDisplayID?

    private init() {}

    // MARK: - Toggle

    func toggle() { isActive ? deactivate() : activate() }

    // MARK: - Activate / Deactivate

    func activate() {
        guard !isActive else { return }
        isActive = true
        logger.info("PowerPoint preset activated")

        // Ensure target VDs are in Signal mode so output windows actually show.
        let vds = VirtualDisplayManager.shared.displays
        for vd in vds.prefix(2) {
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
        logger.info("PowerPoint preset deactivated")

        inventory.stop()
        inventory.onUpdate = nil

        // Stop window capture for Slide Show.
        if let id = slideShowWindowID {
            WindowCaptureManager.shared.stopCapture(windowID: id)
        }
        slideShowWindowID = nil

        // Stop display capture for Presenter View.
        if let id = presenterDisplayID {
            WindowCaptureManager.shared.stopDisplayCapture(displayID: id)
        }
        presenterDisplayID = nil
    }

    // MARK: - Reconciliation (called on every inventory refresh)

    private func reconcile(_ windows: [WindowInfo]) {
        let vds = VirtualDisplayManager.shared.displays
        let ppt = windows.filter { isPowerPoint($0) }

        // Slot 0: Slide Show window → fullscreen on presentation screen + capture to VD[0]
        if let vd = vds[safe: 0] {
            applySlideShow(ppt: ppt, vdID: vd.id)
        }

        // Slot 1: MacBook built-in display → capture to VD[1] (runs once, survives PPT restarts)
        if let vd = vds[safe: 1] {
            applyPresenterCapture(vdID: vd.id)
        }
    }

    // MARK: - Slide Show slot

    private func applySlideShow(ppt: [WindowInfo], vdID: String) {
        guard let window = ppt.first(where: { isSlideShow($0) }) else {
            if slideShowWindowID != nil {
                logger.info("PPT preset: Slide Show window gone — waiting for relaunch")
                slideShowWindowID = nil
            }
            return
        }

        // Already handled this window.
        guard window.id != slideShowWindowID else { return }

        logger.info("PPT preset: found Slide Show (wid=\(window.id)) → VD \(vdID)")
        slideShowWindowID = window.id

        // 1. Move to presentation screen + enter native fullscreen.
        if let screen = presentationScreen(for: vdID) {
            logger.info("PPT preset: moving Slide Show to \(screen.localizedName) + fullscreen")
            WindowMover.move(window, to: screen, resize: false, fullscreen: true)
        } else {
            logger.warning("PPT preset: no presentation screen found — skipping fullscreen move")
        }

        // 2. Capture window to VD[0] for Syphon/OBS routing.
        WindowCaptureManager.shared.startCapture(windowID: window.id, vdUUID: vdID) { [weak self] error in
            if let error {
                self?.logger.error("PPT preset: Slide Show capture failed: \(error.localizedDescription)")
                self?.slideShowWindowID = nil   // allow retry on next reconcile
            }
        }
    }

    /// Returns the NSScreen to use for the Slide Show fullscreen.
    /// Priority: screen that VD[0] is currently assigned to → first external screen.
    private func presentationScreen(for vdID: String) -> NSScreen? {
        // Prefer the screen showing VD[0]'s output (user already configured this).
        if let screen = VirtualDisplayManager.shared.assignedScreen(for: vdID) {
            return screen
        }
        // Fallback: first external (non-built-in) screen.
        return NSScreen.screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                       as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) == 0
        }
    }

    // MARK: - Presenter View slot (display capture)

    /// Starts capturing the MacBook's built-in display once and keeps it running.
    /// Survives PowerPoint restarts because it's keyed by display ID, not window ID.
    private func applyPresenterCapture(vdID: String) {
        guard presenterDisplayID == nil else { return }   // already capturing

        guard let builtinID = builtInDisplayID() else {
            logger.warning("PPT preset: no built-in display found — Presenter View capture skipped")
            return
        }

        logger.info("PPT preset: capturing built-in display (\(builtinID)) → VD \(vdID)")
        presenterDisplayID = builtinID

        WindowCaptureManager.shared.startDisplayCapture(displayID: builtinID, vdUUID: vdID) { [weak self] error in
            if let error {
                self?.logger.error("PPT preset: built-in display capture failed: \(error.localizedDescription)")
                self?.presenterDisplayID = nil   // allow retry
            }
        }
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
