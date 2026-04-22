import AppKit

/// Builds the NSMenu content dynamically each time the menu opens.
enum MenuBuilder {

    static func build(menu: NSMenu, outputs: [OutputWindowController], delegate: StatusBarController) {
        let header = NSMenuItem(title: "SyphonOut", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // ── Virtual Displays ───────────────────────────────────────────────
        let vdHeader = NSMenuItem(title: "Virtual Displays", action: nil, keyEquivalent: "")
        vdHeader.isEnabled = false
        menu.addItem(vdHeader)

        let vdManager = VirtualDisplayManager.shared
        let servers = availableServers()

        if vdManager.displays.isEmpty {
            let empty = NSMenuItem(title: "  No virtual displays", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for vd in vdManager.displays {
                addVDSection(to: menu, vd: vd, servers: servers, delegate: delegate)
            }
        }

        let newVDItem = NSMenuItem(
            title: "  + New Virtual Display…",
            action: #selector(StatusBarController.createNewVD(_:)),
            keyEquivalent: ""
        )
        newVDItem.target = delegate
        menu.addItem(newVDItem)
        menu.addItem(.separator())

        // ── Physical Outputs ───────────────────────────────────────────────
        let physHeader = NSMenuItem(title: "Physical Outputs", action: nil, keyEquivalent: "")
        physHeader.isEnabled = false
        menu.addItem(physHeader)

        for output in outputs {
            addPhysicalSection(to: menu, output: output, vdManager: vdManager, delegate: delegate)
        }
        menu.addItem(.separator())

        // ── Global actions ─────────────────────────────────────────────────
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(StatusBarController.openPreferences(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = delegate
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(
            title: "Quit SyphonOut",
            action: #selector(StatusBarController.quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = delegate
        menu.addItem(quitItem)
    }

    // MARK: - Virtual Display section

    private static func addVDSection(
        to menu: NSMenu,
        vd: VirtualDisplay,
        servers: [(uuid: String, name: String, appName: String)],
        delegate: StatusBarController
    ) {
        // Name header with mode indicator
        let nameItem = NSMenuItem(
            title: "  \(vd.name) — \(vd.modeDescription)",
            action: nil,
            keyEquivalent: ""
        )
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        // Mode submenu
        let modeMenu = NSMenu()
        for (title, mode) in [
            ("Signal", SYPHON_OUT_MODE_SIGNAL),
            ("Freeze", SYPHON_OUT_MODE_FREEZE),
            ("Blank Black", SYPHON_OUT_MODE_BLANK_BLACK),
            ("Blank White", SYPHON_OUT_MODE_BLANK_WHITE),
            ("Test Pattern", SYPHON_OUT_MODE_BLANK_TEST_PATTERN),
            ("Off", SYPHON_OUT_MODE_OFF),
        ] {
            let item = NSMenuItem(
                title: title,
                action: #selector(StatusBarController.setVDMode(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ["vdId": vd.id, "mode": mode.rawValue] as [String: Any]
            item.target = delegate
            item.state = (vd.mode == mode) ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "    Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Source submenu
        let sourceMenu = NSMenu()
        let noneItem = NSMenuItem(
            title: "None",
            action: #selector(StatusBarController.selectVDSource(_:)),
            keyEquivalent: ""
        )
        noneItem.representedObject = ["vdId": vd.id, "uuid": ""] as [String: Any]
        noneItem.target = delegate
        noneItem.state = (vd.sourceUUID == nil) ? .on : .off
        sourceMenu.addItem(noneItem)
        sourceMenu.addItem(.separator())

        for server in servers {
            let displayName = server.appName.isEmpty
                ? server.name
                : "\(server.appName): \(server.name)"
            let item = NSMenuItem(
                title: displayName,
                action: #selector(StatusBarController.selectVDSource(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ["vdId": vd.id, "uuid": server.uuid] as [String: Any]
            item.target = delegate
            item.state = (vd.sourceUUID == server.uuid) ? .on : .off
            sourceMenu.addItem(item)
        }

        let selectedName = vd.sourceUUID.map { uuid in
            servers.first { $0.uuid == uuid }?.name ?? uuid
        } ?? "None"
        let sourceItem = NSMenuItem(title: "    Source: \(selectedName)", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        // Resolution picker (common sizes)
        let resMenu = NSMenu()
        let sizes = [
            ("1280×720", 1280, 720),
            ("1920×1080", 1920, 1080),
            ("2560×1440", 2560, 1440),
            ("3840×2160", 3840, 2160),
        ]
        for (label, w, h) in sizes {
            let item = NSMenuItem(
                title: label,
                action: #selector(StatusBarController.setVDSize(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ["vdId": vd.id, "width": w, "height": h] as [String: Any]
            item.target = delegate
            item.state = (vd.width == UInt32(w) && vd.height == UInt32(h)) ? .on : .off
            resMenu.addItem(item)
        }
        let resItem = NSMenuItem(title: "    Resolution: \(vd.width)×\(vd.height)", action: nil, keyEquivalent: "")
        resItem.submenu = resMenu
        menu.addItem(resItem)

        // Delete
        let deleteItem = NSMenuItem(
            title: "    Delete",
            action: #selector(StatusBarController.deleteVD(_:)),
            keyEquivalent: ""
        )
        deleteItem.representedObject = vd.id
        deleteItem.target = delegate
        menu.addItem(deleteItem)

        // Signal status
        let signal = vd.sourceUUID != nil
            ? (servers.contains(where: { $0.uuid == vd.sourceUUID }) ? "● Live" : "⚠ No Signal")
            : "○ No Source"
        let statusItem = NSMenuItem(title: "    \(signal)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
    }

    // MARK: - Physical Output section

    private static func addPhysicalSection(
        to menu: NSMenu,
        output: OutputWindowController,
        vdManager: VirtualDisplayManager,
        delegate: StatusBarController
    ) {
        let assignedVD = vdManager.assignedVD(for: output.displayId)
        let title = assignedVD != nil
            ? "  \(output.displayAlias) → \(assignedVD!.name)"
            : "  \(output.displayAlias)"
        let nameItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        // Assignment submenu
        let assignMenu = NSMenu()
        let noneItem = NSMenuItem(
            title: "None (black)",
            action: #selector(StatusBarController.assignPhysical(_:)),
            keyEquivalent: ""
        )
        noneItem.representedObject = ["displayId": output.displayId, "vdId": ""] as [String: Any]
        noneItem.target = delegate
        noneItem.state = (assignedVD == nil) ? .on : .off
        assignMenu.addItem(noneItem)
        assignMenu.addItem(.separator())

        for vd in vdManager.displays {
            let item = NSMenuItem(
                title: vd.name,
                action: #selector(StatusBarController.assignPhysical(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ["displayId": output.displayId, "vdId": vd.id] as [String: Any]
            item.target = delegate
            item.state = (assignedVD?.id == vd.id) ? .on : .off
            assignMenu.addItem(item)
        }

        let assignItem = NSMenuItem(title: "    Assign to", action: nil, keyEquivalent: "")
        assignItem.submenu = assignMenu
        menu.addItem(assignItem)

        // Legacy mode controls (still work via implicit VD when unassigned)
        if assignedVD == nil {
            for (title, mode, action) in modeItems(delegate: delegate) {
                let item = NSMenuItem(title: "    \(title)", action: action, keyEquivalent: "")
                item.representedObject = output
                item.target = delegate
                menu.addItem(item)
            }

            let signal = syphonout_get_signal_status(output.displayId)
            let statusText: String
            switch signal {
            case SYPHON_OUT_SIGNAL_PRESENT:            statusText = "● Live"
            case SYPHON_OUT_SIGNAL_NO_SIGNAL:          statusText = "⚠ No Signal"
            case SYPHON_OUT_SIGNAL_NO_SOURCE_SELECTED: statusText = "○ No Source"
            default:                                    statusText = "Unknown"
            }
            let statusItem = NSMenuItem(title: "    \(statusText)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }
    }

    // MARK: - Helpers

    private static func modeItems(delegate _: StatusBarController) -> [(String, SyphonOutMode, Selector)] {
        [
            ("Signal",       SYPHON_OUT_MODE_SIGNAL,             #selector(StatusBarController.setModeSignal(_:))),
            ("Freeze",       SYPHON_OUT_MODE_FREEZE,             #selector(StatusBarController.setModeFreeze(_:))),
            ("Blank Black",  SYPHON_OUT_MODE_BLANK_BLACK,        #selector(StatusBarController.setModeBlackBlank(_:))),
            ("Blank White",  SYPHON_OUT_MODE_BLANK_WHITE,        #selector(StatusBarController.setModeWhiteBlank(_:))),
            ("Test Pattern", SYPHON_OUT_MODE_BLANK_TEST_PATTERN,  #selector(StatusBarController.setModeTestPattern(_:))),
            ("Off",          SYPHON_OUT_MODE_OFF,                #selector(StatusBarController.setModeOff(_:))),
        ]
    }

    static func availableServers() -> [(uuid: String, name: String, appName: String)] {
        var result: [(uuid: String, name: String, appName: String)] = []
        withUnsafeMutablePointer(to: &result) { ptr in
            syphonout_get_servers({ infoPtr, count, ctx in
                guard let infoPtr, let ctx else { return }
                let arr = ctx.assumingMemoryBound(
                    to: [(uuid: String, name: String, appName: String)].self)
                for i in 0..<Int(count) {
                    let info = infoPtr[i]
                    let uuid    = info.uuid    != nil ? String(cString: info.uuid)     : ""
                    let name    = info.name    != nil ? String(cString: info.name)     : ""
                    let appName = info.app_name != nil ? String(cString: info.app_name) : ""
                    arr.pointee.append((uuid: uuid, name: name, appName: appName))
                }
            }, ptr)
        }
        return result
    }
}
