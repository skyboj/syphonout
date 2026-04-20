import AppKit

/// Builds the NSMenu content dynamically each time the menu opens.
enum MenuBuilder {

    static func build(menu: NSMenu, outputs: [OutputWindowController], delegate: StatusBarController) {
        let header = NSMenuItem(title: "SyphonOut", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Collect available servers from Rust
        let servers = availableServers()

        for output in outputs {
            addOutputSection(to: menu, output: output, servers: servers, delegate: delegate)
            menu.addItem(.separator())
        }

        // Mirror toggle
        let mirrorItem = NSMenuItem(
            title: "Mirror all outputs",
            action: #selector(StatusBarController.toggleMirror(_:)),
            keyEquivalent: ""
        )
        mirrorItem.target = delegate
        menu.addItem(mirrorItem)

        menu.addItem(.separator())

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

    // MARK: - Per-output section

    private static func addOutputSection(
        to menu: NSMenu,
        output: OutputWindowController,
        servers: [(uuid: String, name: String, appName: String)],
        delegate: StatusBarController
    ) {
        // Display name header
        let nameItem = NSMenuItem(title: output.displayAlias, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        // Mode radio items

        for (title, mode, action) in modeItems(delegate: delegate) {
            let item = NSMenuItem(title: "  \(title)", action: action, keyEquivalent: "")
            item.representedObject = output
            item.target = delegate
            menu.addItem(item)
        }

        // Source submenu
        let sourceMenu = NSMenu()
        if servers.isEmpty {
            let empty = NSMenuItem(title: "No Syphon servers found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sourceMenu.addItem(empty)
        } else {
            // Get currently selected server name for this display
            let selectedName: String? = {
                guard let cStr = syphonout_get_selected_server_name(output.displayId) else { return nil }
                return String(cString: cStr)
            }()

            for server in servers {
                let displayName = server.appName.isEmpty
                    ? server.name
                    : "\(server.appName): \(server.name)"
                let item = NSMenuItem(
                    title: displayName,
                    action: #selector(StatusBarController.selectSource(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = ["output": output, "uuid": server.uuid] as [String: Any]
                item.target = delegate
                item.state = (displayName == selectedName) ? .on : .off
                sourceMenu.addItem(item)
            }
        }

        let selectedDisplay: String = {
            guard let cStr = syphonout_get_selected_server_name(output.displayId) else { return "None" }
            return String(cString: cStr)
        }()
        let sourceItem = NSMenuItem(title: "Source: \(selectedDisplay)", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        // Signal status
        let signal = syphonout_get_signal_status(output.displayId)
        let statusText: String
        switch signal {
        case SYPHON_OUT_SIGNAL_PRESENT:           statusText = "● Live"
        case SYPHON_OUT_SIGNAL_NO_SIGNAL:         statusText = "⚠ No Signal"
        case SYPHON_OUT_SIGNAL_NO_SOURCE_SELECTED: statusText = "○ No Source"
        default:                                   statusText = "Unknown"
        }
        let statusItem = NSMenuItem(title: "  \(statusText)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
    }

    // MARK: - Mode items

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

    // MARK: - Server enumeration

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
