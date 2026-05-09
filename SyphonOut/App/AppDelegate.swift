import AppKit
import os.log

@objc(AppDelegate)
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var outputs: [OutputWindowController] = []
    private var statusBarController: StatusBarController?
    private var screenChangeObserver: NSObjectProtocol?
    private var assignmentObserver: NSObjectProtocol?
    private var vdModeObserver: NSObjectProtocol?
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

        // 4. Seed display name cache BEFORE creating controllers so mirrored
        //    displays that appear during init already have names cached.
        OutputWindowController.seedNameCache()

        // 4. One OutputWindowController per active display
        for screen in NSScreen.screens {
            guard let displayId = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            outputs.append(OutputWindowController(display: displayId))
        }

        // Also add controllers for displays that are online but NOT in NSScreen.screens —
        // these are already-mirrored displays that macOS hid from the screen list before
        // we launched. Without this they don't appear in the tray until a screen-change event.
        let knownIds = Set(outputs.map { $0.displayId })
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineIds = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIds, &onlineCount)
        for displayId in onlineIds.prefix(Int(onlineCount)) {
            guard !knownIds.contains(displayId) else { continue }
            outputs.append(OutputWindowController(display: displayId))
            logger.info("Display \(displayId) online but not in NSScreen (already mirrored) — adding controller")
        }

        // 4b. Initialise Virtual Display manager.
        //     Shows output windows only for external displays that already have a saved assignment.
        //     The built-in MacBook display is NEVER auto-shown on launch — the user must
        //     explicitly assign it after startup. This ensures the Mac is always accessible.
        _ = VirtualDisplayManager.shared
        for (displayId, _) in VirtualDisplayManager.shared.assignments {
            guard CGDisplayIsBuiltin(displayId) == 0 else {
                logger.info("Skipping auto-show for built-in display \(displayId) on launch")
                continue
            }
            // If the assigned display is currently mirroring another display,
            // its bounds collapse onto the master's — showing the output window
            // would put it on top of the master (e.g. MacBook).  Skip until the
            // user breaks the mirror, after which the assignmentChanged path
            // will pick this up.
            let mirrorMaster = CGDisplayMirrorsDisplay(displayId)
            guard mirrorMaster == kCGNullDirectDisplay else {
                logger.info("Skipping auto-show for display \(displayId): mirroring \(mirrorMaster) (would land on master)")
                continue
            }
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

        // 6b. Start the always-on PowerPoint watcher.
        //     It captures the MacBook display into whichever VD is assigned to
        //     an external display, but ONLY while a Slide Show is active.
        //     This is the SyphonOut "soft mirror" for Presenter View.
        PowerPointPreset.shared.activate()

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

        // 7b. Show/hide output windows when a VD mode changes to/from Off.
        //     This handles the case where mode is set via VirtualDisplayManager
        //     (e.g. through the menu's Mode submenu) rather than directly on the
        //     OutputWindowController.
        vdModeObserver = NotificationCenter.default.addObserver(
            forName: .vdModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let vdId   = note.userInfo?["vdId"]   as? String,
                  let rawMode = note.userInfo?["mode"]   as? UInt32
            else { return }
            let mode = SyphonOutMode(rawValue: rawMode)
            // Find all physical displays assigned to this VD and update their windows.
            let vdm = VirtualDisplayManager.shared
            for output in self.outputs {
                guard vdm.assignedVD(for: output.displayId)?.id == vdId else { continue }
                if mode == SYPHON_OUT_MODE_OFF {
                    output.hideOutput()
                } else if !output.isVisible {
                    output.showOutput()
                }
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

        // 9. Global hotkeys (Carbon RegisterEventHotKey — no Accessibility permission needed)
        let hkLog = Logger(subsystem: "com.syphonout.SyphonOut", category: "Hotkey")
        HotkeyManager.shared.onFreezeAll = {
            VirtualDisplayManager.shared.setAllModes(SYPHON_OUT_MODE_FREEZE)
            hkLog.info("freeze all (⌃⌥F)")
        }
        HotkeyManager.shared.onUnfreezeAll = {
            VirtualDisplayManager.shared.setAllModes(SYPHON_OUT_MODE_SIGNAL)
            hkLog.info("unfreeze all (⌃⌥U)")
        }
        HotkeyManager.shared.onBlankAll = {
            VirtualDisplayManager.shared.setAllModes(SYPHON_OUT_MODE_BLANK_BLACK)
            hkLog.info("blank all (⌃⌥⌘K)")
        }
        HotkeyManager.shared.onRestoreAll = {
            VirtualDisplayManager.shared.setAllModes(SYPHON_OUT_MODE_SIGNAL)
            hkLog.info("restore all (⌃⌥⌘S)")
        }
        HotkeyManager.shared.start()

        logger.info("SyphonOut started — \(self.outputs.count) display(s)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = assignmentObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = screenChangeObserver { NotificationCenter.default.removeObserver(obs) }
        WindowCaptureManager.shared.stopAll()
        SOLinkClientStop()
        SyphonNativeStop()
        syphonout_core_deinit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Screen change handling

    private func handleScreenChange() {
        // Refresh name cache first — before mirrors change the NSScreen list.
        OutputWindowController.seedNameCache()

        let currentIds = Set(outputs.map { $0.displayId })
        let liveIds: Set<CGDirectDisplayID> = Set(
            NSScreen.screens.compactMap {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            }
        )

        // ── Removed displays ──────────────────────────────────────────────
        // When macOS creates an OS mirror set it reassigns CGDirectDisplayIDs —
        // the old slave ID disappears and a fresh ID appears for the hardware.
        // CGDisplayIsOnline(oldID) therefore returns 0 even though the monitor
        // is still physically connected. We detect "still connected" by comparing
        // unit numbers (CGDisplayUnitNumber), which are stable across ID changes.
        let onlineUnitNumbers: Set<UInt32> = {
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetOnlineDisplayList(count, &ids, &count)
            return Set(ids.prefix(Int(count)).map { CGDisplayUnitNumber($0) })
        }()

        let removedIds = currentIds.subtracting(liveIds)
        for id in removedIds {
            let unit = CGDisplayUnitNumber(id)
            if onlineUnitNumbers.contains(unit) {
                // Same physical hardware, just remapped to a new ID (mirroring).
                // Keep the OutputWindowController so the menu still shows it.
                logger.info("Display \(id) (unit \(unit)) left NSScreen but hardware still online (mirrored) — keeping controller")
                continue
            }
            // Unit number gone → cable unplugged. Clean up completely.
            VirtualDisplayManager.shared.unassignPhysical(displayId: id)
            outputs.removeAll { $0.displayId == id }
            logger.info("Display \(id) (unit \(unit)) disconnected — output removed")
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
    static let vdListChanged         = Notification.Name("SyphonOutVDListChanged")
    static let vdModeChanged         = Notification.Name("SyphonOutVDModeChanged")
}
