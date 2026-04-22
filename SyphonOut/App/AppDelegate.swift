import AppKit
import os.log

@objc(AppDelegate)
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var outputs: [OutputWindowController] = []
    private var statusBarController: StatusBarController?
    private var screenChangeObserver: NSObjectProtocol?
    private var assignmentObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Boot Rust core
        syphonout_core_init()

        // 2. Load Syphon.framework at runtime and begin server discovery
        SyphonNativeLoad()
        SyphonNativeStartDiscovery()

        // 2b. SOLink subscriber — discovers OBS obs-solink publishers
        SOLinkClientInit()
        SOLinkClientStartDiscovery()

        // 3. Wire crossfade duration from prefs
        let ms = PreferencesStore.shared.crossfadeDuration * 1000.0
        syphonout_set_crossfade_duration_ms(ms)

        // 4. One OutputWindowController per active display
        for screen in NSScreen.screens {
            guard let displayId = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            outputs.append(OutputWindowController(display: displayId))
        }

        // 4b. Initialise Virtual Display manager.
        //     Shows output windows only for displays that already have a saved assignment.
        _ = VirtualDisplayManager.shared
        for (displayId, _) in VirtualDisplayManager.shared.assignments {
            outputs.first(where: { $0.displayId == displayId })?.showOutput()
        }

        // 5. Register server-changed callback so the menu rebuilds on server list changes
        syphonout_set_server_changed_callback({ _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .syphonServersChanged, object: nil)
            }
        }, nil)

        // 6. Menu bar
        statusBarController = StatusBarController(outputs: outputs)

        // 7. Show/hide output window when user assigns or unassigns a VD
        assignmentObserver = NotificationCenter.default.addObserver(
            forName: .vdAssignmentChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let displayId = note.userInfo?["displayId"] as? CGDirectDisplayID,
                  let assigned  = note.userInfo?["assigned"]  as? Bool
            else { return }
            if let output = self.outputs.first(where: { $0.displayId == displayId }) {
                assigned ? output.showOutput() : output.hideOutput()
            }
        }

        // 8. Watch for display connect / disconnect
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }

        logger.info("SyphonOut started — \(self.outputs.count) display(s)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = assignmentObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = screenChangeObserver { NotificationCenter.default.removeObserver(obs) }
        SOLinkClientStop()
        SyphonNativeStop()
        syphonout_core_deinit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Screen change handling

    private func handleScreenChange() {
        let currentIds = Set(outputs.map { $0.displayId })
        let liveIds: Set<CGDirectDisplayID> = Set(
            NSScreen.screens.compactMap {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            }
        )

        // ── Removed displays ──────────────────────────────────────────────
        let removedIds = currentIds.subtracting(liveIds)
        for id in removedIds {
            // Clean up assignment in VDM before destroying the controller
            // (deinit stops the DisplayLink and calls syphonout_output_destroy)
            VirtualDisplayManager.shared.unassignPhysical(displayId: id)
            outputs.removeAll { $0.displayId == id }
            logger.info("Display \(id) disconnected — output removed")
        }

        // ── Added displays ────────────────────────────────────────────────
        let addedIds = liveIds.subtracting(currentIds)
        for id in addedIds {
            let controller = OutputWindowController(display: id)
            outputs.append(controller)

            logger.info("Display \(id) connected — output added, unassigned (user picks VD)")
        }

        // Sync the updated list into the status bar so menu reflects reality
        if !removedIds.isEmpty || !addedIds.isEmpty {
            statusBarController?.outputs = outputs
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let syphonServersChanged  = Notification.Name("SyphonOutServersChanged")
    static let vdAssignmentChanged   = Notification.Name("SyphonOutVDAssignmentChanged")
}
