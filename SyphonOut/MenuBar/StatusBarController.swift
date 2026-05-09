import AppKit

/// Owns the NSStatusItem and drives the dynamic menu.
/// All mode/server changes are dispatched to Rust via the FFI.
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    var outputs: [OutputWindowController]
    private var serversChangedObserver: NSObjectProtocol?

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

    // MARK: Physical output: source (routes through assigned VD)

    /// Sets the Syphon source on the VD assigned to the given physical display.
    @objc func togglePPTPreset(_ sender: NSMenuItem) {
        PowerPointPreset.shared.toggle()
        UserDefaults.standard.set(PowerPointPreset.shared.isActive, forKey: "pptPresetEnabled")
        // Rebuild menu to update checkbox state
        if let menu = statusItem?.menu {
            menu.removeAllItems()
            MenuBuilder.build(menu: menu, outputs: outputs, delegate: self)
        }
    }

    @objc func setPhysicalSource(_ sender: NSMenuItem) {
        guard let info      = sender.representedObject as? [String: Any],
              let displayId = info["displayId"] as? CGDirectDisplayID,
              let uuid      = info["uuid"]      as? String
        else { return }
        let vdm = VirtualDisplayManager.shared
        guard let vd = vdm.assignedVD(for: displayId) else { return }
        if uuid.isEmpty {
            vdm.clearSource(vdId: vd.id)
        } else {
            vdm.setSource(vdId: vd.id, sourceUUID: uuid)
        }
    }

    // MARK: Physical output: mode (routes through assigned VD, falls back to direct)

    /// Sets the mode on the VD assigned to the given physical display.
    /// Falls back to the OutputWindowController if no VD is assigned.
    @objc func setPhysicalMode(_ sender: NSMenuItem) {
        guard let info      = sender.representedObject as? [String: Any],
              let displayId = info["displayId"] as? CGDirectDisplayID,
              let modeRaw   = info["mode"]      as? UInt32
        else { return }
        let mode = SyphonOutMode(rawValue: modeRaw)
        let vdm  = VirtualDisplayManager.shared
        if let vd = vdm.assignedVD(for: displayId) {
            vdm.setMode(vdId: vd.id, mode: mode)
        } else if let output = outputs.first(where: { $0.displayId == displayId }) {
            output.setMode(mode)
        }
    }

    // MARK: Physical output: VD assignment (used when unassigned)

    @objc func assignPhysical(_ sender: NSMenuItem) {
        guard let info      = sender.representedObject as? [String: Any],
              let displayId = info["displayId"] as? CGDirectDisplayID,
              let vdId      = info["vdId"]      as? String
        else { return }
        if vdId.isEmpty {
            VirtualDisplayManager.shared.unassignPhysical(displayId: displayId)
        } else {
            VirtualDisplayManager.shared.assignPhysical(displayId: displayId, vdUUID: vdId)
        }
    }

    // MARK: Physical output: scale

    @objc func setScaleMode(_ sender: NSMenuItem) {
        guard let info      = sender.representedObject as? [String: Any],
              let displayId = info["displayId"] as? CGDirectDisplayID,
              let rawMode   = info["mode"]      as? UInt32
        else { return }
        let mode = SyphonOutScaleMode(rawValue: rawMode)
        if let output = outputs.first(where: { $0.displayId == displayId }) {
            output.setScaleMode(mode)
        }
    }

    // MARK: Utilities

    @objc func addNewVirtualDisplay(_ sender: NSMenuItem) {
        VirtualDisplayManager.shared.createDisplay()
        let wc = VirtualDisplayWindowController.shared
        wc.window?.makeKeyAndOrderFront(sender)
        wc.subscribeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openVirtualDisplays(_ sender: NSMenuItem) {
        let wc = VirtualDisplayWindowController.shared
        wc.window?.makeKeyAndOrderFront(sender)
        wc.subscribeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openPowerPointSetup(_ sender: NSMenuItem) {
        PowerPointSetupWindowController.shared.show()
    }

    @objc func openWindowRouting(_ sender: NSMenuItem) {
        WindowRoutingWindowController.shared.showRouting()
    }

    @objc func showLogViewer(_ sender: NSMenuItem) {
        LogViewerWindowController.shared.showLog()
    }

    @objc func openPreferences(_ sender: NSMenuItem) {
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
