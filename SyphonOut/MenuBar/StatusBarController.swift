import AppKit
import Combine

/// Owns the NSStatusItem (menu bar icon) and coordinates the menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let outputManager: OutputManager
    private var cancellables = Set<AnyCancellable>()
    private var globalShortcutMonitor: Any?

    init(outputManager: OutputManager) {
        self.outputManager = outputManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.title = "●"
        statusItem.button?.font = NSFont.systemFont(ofSize: 14)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        outputManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        updateIcon()
        registerGlobalShortcuts()
    }

    // MARK: - Icon

    private func updateIcon() {
        let title: String
        switch outputManager.globalIconState {
        case .solid: title = "●"
        case .half:  title = "◑"
        case .empty: title = "○"
        }
        statusItem.button?.title = title
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        MenuBuilder.build(menu: menu, outputManager: outputManager, delegate: self)
    }

    // MARK: - Global shortcuts

    private func registerGlobalShortcuts() {
        let prefs = PreferencesStore.shared
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == prefs.shortcutFreezeAll.flags && event.keyCode == prefs.shortcutFreezeAll.keyCode {
                self.outputManager.freezeAll()
            } else if flags == prefs.shortcutUnfreezeAll.flags && event.keyCode == prefs.shortcutUnfreezeAll.keyCode {
                self.outputManager.unfreezeAll()
            } else if flags == prefs.shortcutBlankAll.flags && event.keyCode == prefs.shortcutBlankAll.keyCode {
                self.outputManager.blankAll()
            } else if flags == prefs.shortcutRestoreAll.flags && event.keyCode == prefs.shortcutRestoreAll.keyCode {
                self.outputManager.restoreAll()
            }
        }
    }

    deinit {
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Menu actions (forwarded from MenuBuilder)

extension StatusBarController {
    @objc func setModeSignal(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.signal, for: output)
    }

    @objc func setModeFreeze(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.freeze, for: output)
    }

    @objc func setModeBlankBlack(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.blank(.black), for: output)
    }

    @objc func setModeBlankWhite(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.blank(.white), for: output)
    }

    @objc func setModeBlankTestPattern(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.blank(.testPattern), for: output)
    }

    @objc func setModeOff(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.off, for: output)
    }

    @objc func selectSource(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let output = info["output"] as? OutputController,
              let server = info["server"] as? SyphonServerDescription
        else { return }
        outputManager.selectServer(server, for: output)
    }

    @objc func toggleMirror(_ sender: NSMenuItem) {
        outputManager.setMirrorEnabled(!outputManager.mirrorEnabled)
    }

    @objc func openPreferences(_ sender: NSMenuItem) {
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
