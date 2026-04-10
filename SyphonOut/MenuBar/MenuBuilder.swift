import AppKit

/// Builds the NSMenu content dynamically each time the menu opens.
enum MenuBuilder {
    static func build(menu: NSMenu, outputManager: OutputManager, delegate: StatusBarController) {
        // App title (non-clickable header)
        let header = NSMenuItem(title: "SyphonOut", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Per-display sections
        for output in outputManager.outputs {
            addOutputSection(to: menu, output: output, outputManager: outputManager, delegate: delegate)
            menu.addItem(.separator())
        }

        // Mirror toggle
        let mirrorTitle = outputManager.mirrorEnabled
            ? "Mirror: On → \(outputManager.primaryOutput?.displayAlias ?? "Display 1")"
            : "Mirror all outputs → \(outputManager.primaryOutput?.displayAlias ?? "Display 1") source"
        let mirrorItem = NSMenuItem(title: mirrorTitle, action: #selector(StatusBarController.toggleMirror(_:)), keyEquivalent: "")
        mirrorItem.state = outputManager.mirrorEnabled ? .on : .off
        mirrorItem.target = delegate
        menu.addItem(mirrorItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(StatusBarController.openPreferences(_:)), keyEquivalent: ",")
        prefsItem.target = delegate
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(title: "Quit SyphonOut", action: #selector(StatusBarController.quitApp(_:)), keyEquivalent: "q")
        quitItem.target = delegate
        menu.addItem(quitItem)
    }

    // MARK: - Per-output section

    private static func addOutputSection(
        to menu: NSMenu,
        output: OutputController,
        outputManager: OutputManager,
        delegate: StatusBarController
    ) {
        // Display name
        let nameItem = NSMenuItem(title: output.displayAlias, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        // Mode radio items
        addModeRadio(to: menu, title: "Signal",  mode: .signal,       current: output.mode, output: output, action: #selector(StatusBarController.setModeSignal(_:)),  delegate: delegate)
        addModeRadio(to: menu, title: "Freeze",  mode: .freeze,       current: output.mode, output: output, action: #selector(StatusBarController.setModeFreeze(_:)),  delegate: delegate)
        addModeRadio(to: menu, title: "Blank",   mode: .blank(.black), current: output.mode, output: output, action: #selector(StatusBarController.setModeBlack(_:)),  delegate: delegate)
        addModeRadio(to: menu, title: "Off",     mode: .off,          current: output.mode, output: output, action: #selector(StatusBarController.setModeOff(_:)),    delegate: delegate)

        // Source dropdown (submenu)
        let sourceMenu = NSMenu()
        let servers = outputManager.availableServers
        let selectedServer = outputManager.selectedServer(for: output)
        let mirrorActive = outputManager.mirrorEnabled

        if servers.isEmpty {
            let emptyItem = NSMenuItem(title: "No Syphon servers found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            sourceMenu.addItem(emptyItem)
        } else {
            for server in servers {
                let item = NSMenuItem(
                    title: server.displayName,
                    action: #selector(StatusBarController.selectSource(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = ["output": output, "server": server] as [String: Any]
                item.state = (server == selectedServer) ? .on : .off
                item.target = delegate
                item.isEnabled = !mirrorActive
                sourceMenu.addItem(item)
            }
        }

        let sourceItem = NSMenuItem(title: "Source: \(selectedServer?.displayName ?? "None")", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        sourceItem.isEnabled = !mirrorActive
        menu.addItem(sourceItem)

        // Status line
        let statusItem = NSMenuItem(title: "    \(output.signalStatus.description)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
    }

    // MARK: - Helpers

    private static func addModeRadio(
        to menu: NSMenu,
        title: String,
        mode: OutputMode,
        current: OutputMode,
        output: OutputController,
        action: Selector,
        delegate: StatusBarController
    ) {
        let item = NSMenuItem(title: "    \(title)", action: action, keyEquivalent: "")
        item.representedObject = output
        item.target = delegate
        item.state = modesMatch(mode, current) ? .on : .off
        menu.addItem(item)
    }

    private static func modesMatch(_ a: OutputMode, _ b: OutputMode) -> Bool {
        switch (a, b) {
        case (.signal, .signal), (.freeze, .freeze), (.off, .off): return true
        case (.blank, .blank): return true
        default: return false
        }
    }
}
