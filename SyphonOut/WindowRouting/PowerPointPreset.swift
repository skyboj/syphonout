/// PowerPoint Presentation Preset
///
/// When active, automatically captures PowerPoint windows into Virtual Displays:
///   Slot 0  →  Slide Show     (the fullscreen presentation — no "Presenter" in title)
///   Slot 1  →  Presenter View (window whose title contains "Presenter")
///
/// The preset watches the window list continuously while active.
/// If PowerPoint is quit and relaunched, the new windows are captured automatically
/// in the same slot order — no manual intervention needed.
///
/// Activation also sets both target VDs to Signal mode so output windows show.
/// Deactivation stops only the captures the preset itself started.

import Foundation
import os.log

final class PowerPointPreset {

    static let shared = PowerPointPreset()

    private(set) var isActive = false

    private let inventory  = WindowInventory()
    private let logger     = Logger(subsystem: "com.syphonout.SyphonOut", category: "PPTPreset")

    /// CGWindowID currently occupying each slot. nil = slot is waiting for a window.
    private var slideShowWindowID:    CGWindowID?
    private var presenterWindowID:    CGWindowID?

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

        // Stop only the captures this preset started.
        if let id = slideShowWindowID  { WindowCaptureManager.shared.stopCapture(windowID: id) }
        if let id = presenterWindowID  { WindowCaptureManager.shared.stopCapture(windowID: id) }
        slideShowWindowID  = nil
        presenterWindowID  = nil
    }

    // MARK: - Reconciliation (called on every inventory refresh)

    private enum Slot { case slideShow, presenterView }

    private func reconcile(_ windows: [WindowInfo]) {
        let vds = VirtualDisplayManager.shared.displays
        let ppt = windows.filter { isPowerPoint($0) }

        if let vd = vds[safe: 0] { applySlot(.slideShow,     ppt: ppt, vdID: vd.id) }
        if let vd = vds[safe: 1] { applySlot(.presenterView, ppt: ppt, vdID: vd.id) }
    }

    private func currentID(for slot: Slot) -> CGWindowID? {
        slot == .slideShow ? slideShowWindowID : presenterWindowID
    }

    private func setCurrentID(_ id: CGWindowID?, for slot: Slot) {
        if slot == .slideShow { slideShowWindowID = id }
        else                  { presenterWindowID  = id }
    }

    private func applySlot(_ slot: Slot, ppt: [WindowInfo], vdID: String) {
        let role   = slot == .slideShow ? "SlideShow" : "PresenterView"
        let window = slot == .slideShow
            ? ppt.first { isSlideShow($0) }
            : ppt.first { isPresenterView($0) }

        guard let window else {
            if currentID(for: slot) != nil {
                logger.info("PPT preset: \(role) window gone — waiting for relaunch")
                setCurrentID(nil, for: slot)
            }
            return
        }

        guard window.id != currentID(for: slot) else { return }

        logger.info("PPT preset: capturing \(role) (wid=\(window.id)) → VD \(vdID)")
        setCurrentID(window.id, for: slot)

        WindowCaptureManager.shared.startCapture(windowID: window.id, vdUUID: vdID) { [weak self] error in
            if let error {
                self?.logger.error("PPT preset: capture failed for \(role): \(error.localizedDescription)")
                self?.setCurrentID(nil, for: slot)  // allow retry
            }
        }
    }

    // MARK: - Window identification

    private func isPowerPoint(_ w: WindowInfo) -> Bool {
        w.appName.localizedCaseInsensitiveContains("PowerPoint")
    }

    private func isPresenterView(_ w: WindowInfo) -> Bool {
        w.title.localizedCaseInsensitiveContains("Presenter View")
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
