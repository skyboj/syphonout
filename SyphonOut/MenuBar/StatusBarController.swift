import AppKit
import os.log

/// Owns the NSStatusItem and drives the dynamic menu.
/// All mode/server changes are dispatched to Rust via the FFI.
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    var outputs: [OutputWindowController]
    private var globalShortcutMonitor: Any?
    private var serversChangedObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "StatusBar")

    init(outputs: [OutputWindowController]) {
        self.outputs = outputs
        super.init()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item

        if let button = item.button {
            button.image = makeIcon(state: SYPHON_OUT_ICON_SOLID)
            button.imagePosition = .imageOnly
            button.toolTip = "SyphonOut"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        registerGlobalShortcuts()

        // Rebuild menu icon when server list changes
        serversChangedObserver = NotificationCenter.default.addObserver(
            forName: .syphonServersChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }

        updateIcon()
    }

    deinit {
        if let m = globalShortcutMonitor { NSEvent.removeMonitor(m) }
        if let obs = serversChangedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Icon

    private func updateIcon() {
        let state = syphonout_get_icon_state()
        statusItem?.button?.image = makeIcon(state: state)
    }

    private func makeIcon(state: SyphonOutIcon) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image: NSImage
        switch state {
        case SYPHON_OUT_ICON_SOLID:
            image = NSImage(size: size, flipped: false) { _ in
                NSColor.controlTextColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
                return true
            }
        case SYPHON_OUT_ICON_HALF:
            image = NSImage(size: size, flipped: false) { _ in
                NSColor.controlTextColor.setFill()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 8, y: 2))
                path.line(to: NSPoint(x: 8, y: 14))
                path.appendArc(withCenter: NSPoint(x: 8, y: 8), radius: 6,
                               startAngle: 270, endAngle: 90)
                path.close()
                path.fill()
                return true
            }
        default: // SYPHON_OUT_ICON_EMPTY
            image = NSImage(size: size, flipped: false) { _ in
                NSColor.controlTextColor.setStroke()
                let p = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 11, height: 11))
                p.lineWidth = 1.5
                p.stroke()
                return true
            }
        }
        image.isTemplate = true
        return image
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        MenuBuilder.build(menu: menu, outputs: outputs, delegate: self)
        updateIcon()
    }

    // MARK: - Global shortcuts

    private func registerGlobalShortcuts() {
        let prefs = PreferencesStore.shared
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == prefs.shortcutFreezeAll.flags, event.keyCode == prefs.shortcutFreezeAll.keyCode {
                self.freezeAll()
            } else if flags == prefs.shortcutUnfreezeAll.flags, event.keyCode == prefs.shortcutUnfreezeAll.keyCode {
                self.unfreezeAll()
            } else if flags == prefs.shortcutBlankAll.flags, event.keyCode == prefs.shortcutBlankAll.keyCode {
                self.blankAll()
            } else if flags == prefs.shortcutRestoreAll.flags, event.keyCode == prefs.shortcutRestoreAll.keyCode {
                self.restoreAll()
            }
        }
    }

    // MARK: - Batch operations (operate on Virtual Displays, not physical outputs)

    func freezeAll() {
        VirtualDisplayManager.shared.displays.forEach {
            VirtualDisplayManager.shared.setMode(vdId: $0.id, mode: SYPHON_OUT_MODE_FREEZE)
        }
    }
    func unfreezeAll() {
        VirtualDisplayManager.shared.displays.forEach {
            VirtualDisplayManager.shared.setMode(vdId: $0.id, mode: SYPHON_OUT_MODE_SIGNAL)
        }
    }
    func blankAll() {
        VirtualDisplayManager.shared.displays.forEach {
            VirtualDisplayManager.shared.setMode(vdId: $0.id, mode: SYPHON_OUT_MODE_BLANK_BLACK)
        }
    }
    func restoreAll() {
        VirtualDisplayManager.shared.displays.forEach {
            VirtualDisplayManager.shared.setMode(vdId: $0.id, mode: SYPHON_OUT_MODE_SIGNAL)
        }
    }
}

// MARK: - Menu action targets

extension StatusBarController {

    @objc func setModeSignal(_ sender: NSMenuItem) {
        (sender.representedObject as? OutputWindowController)?.setMode(SYPHON_OUT_MODE_SIGNAL)
    }
    @objc func setModeFreeze(_ sender: NSMenuItem) {
        (sender.representedObject as? OutputWindowController)?.setMode(SYPHON_OUT_MODE_FREEZE)
    }
    @objc func setModeBlackBlank(_ sender: NSMenuItem) {
        (sender.representedObject as? OutputWindowController)?.setMode(SYPHON_OUT_MODE_BLANK_BLACK)
    }
    @objc func setModeWhiteBlank(_ sender: NSMenuItem) {
        (sender.representedObject as? OutputWindowController)?.setMode(SYPHON_OUT_MODE_BLANK_WHITE)
    }
    @objc func setModeTestPattern(_ sender: NSMenuItem) {
        (sender.representedObject as? OutputWindowController)?.setMode(SYPHON_OUT_MODE_BLANK_TEST_PATTERN)
    }
    @objc func setModeOff(_ sender: NSMenuItem) {
        (sender.representedObject as? OutputWindowController)?.setMode(SYPHON_OUT_MODE_OFF)
    }

    @objc func selectSource(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let output = info["output"] as? OutputWindowController,
              let uuid   = info["uuid"]   as? String
        else { return }
        output.setServer(uuid: uuid)
    }

    // MARK: - Virtual Display actions

    @objc func createNewVD(_ sender: NSMenuItem) {
        VirtualDisplayManager.shared.createDisplay()
    }

    @objc func deleteVD(_ sender: NSMenuItem) {
        guard let vdId = sender.representedObject as? String else { return }
        VirtualDisplayManager.shared.destroyDisplay(id: vdId)
    }

    @objc func setVDMode(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let vdId = info["vdId"] as? String,
              let modeRaw = info["mode"] as? UInt32
        else { return }
        let mode = SyphonOutMode(rawValue: modeRaw)
        VirtualDisplayManager.shared.setMode(vdId: vdId, mode: mode)
    }

    @objc func selectVDSource(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let vdId = info["vdId"] as? String,
              let uuid = info["uuid"] as? String
        else { return }
        if uuid.isEmpty {
            VirtualDisplayManager.shared.clearSource(vdId: vdId)
        } else {
            VirtualDisplayManager.shared.setSource(vdId: vdId, sourceUUID: uuid)
        }
    }

    @objc func setVDSize(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let vdId = info["vdId"] as? String,
              let width = info["width"] as? UInt32,
              let height = info["height"] as? UInt32
        else { return }
        VirtualDisplayManager.shared.setSize(vdId: vdId, width: width, height: height)
    }

    @objc func assignPhysical(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let displayId = info["displayId"] as? CGDirectDisplayID,
              let vdId = info["vdId"] as? String
        else { return }
        if vdId.isEmpty {
            VirtualDisplayManager.shared.unassignPhysical(displayId: displayId)
        } else {
            VirtualDisplayManager.shared.assignPhysical(displayId: displayId, vdUUID: vdId)
        }
    }

    @objc func toggleMirror(_ sender: NSMenuItem) {
        // Mirror: route all displays from the first output's server
        // Simple toggle: use the first output as primary source
        let mirrorEnabled = sender.state != .on
        if mirrorEnabled, let primaryId = outputs.first?.displayId {
            syphonout_set_mirror(true, primaryId)
        } else {
            syphonout_set_mirror(false, 0)
        }
        sender.state = mirrorEnabled ? .on : .off
    }

    @objc func openPreferences(_ sender: NSMenuItem) {
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
