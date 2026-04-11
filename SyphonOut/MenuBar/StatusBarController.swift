import AppKit
import Combine
import os.log

/// Owns the NSStatusItem (menu bar icon) and coordinates the menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let outputManager: OutputManager
    private var cancellables = Set<AnyCancellable>()
    private var globalShortcutMonitor: Any?
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "StatusBarController")

    init(outputManager: OutputManager) {
        self.outputManager = outputManager
        super.init()
        
        logger.log("[SyphonOut Debug] StatusBarController init starting")
        
        // Create status bar item
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item
        
        print("[SyphonOut Debug] Status item created: \(item)")
        print("[SyphonOut Debug] Status item button: \(String(describing: item.button))")
        
        // Configure the button with a simple filled circle image
        if let button = item.button {
            // Create a properly sized circle image
            let size = NSSize(width: 16, height: 16)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.controlTextColor.setFill()
                let circleRect = NSRect(x: 2, y: 2, width: 12, height: 12)
                let path = NSBezierPath(ovalIn: circleRect)
                path.fill()
                return true
            }
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "SyphonOut"
            print("[SyphonOut Debug] Button configured with image")
        } else {
            print("[SyphonOut Debug] ERROR: item.button is nil!")
        }

        // Setup menu
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        print("[SyphonOut Debug] Menu attached")

        // Subscribe to output manager changes
        outputManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("[SyphonOut Debug] OutputManager changed, updating icon")
                self?.updateIcon()
            }
            .store(in: &cancellables)
        print("[SyphonOut Debug] Subscribed to outputManager changes")

        // Initial icon update
        updateIcon()
        
        // Register global shortcuts
        registerGlobalShortcuts()
        
        print("[SyphonOut Debug] StatusBarController init complete")
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem?.button else {
            print("[SyphonOut Debug] updateIcon: button is nil")
            return
        }
        
        let state = outputManager.globalIconState
        print("[SyphonOut Debug] updateIcon state: \(state)")
        
        // Use different image based on state
        let size = NSSize(width: 16, height: 16)
        let image: NSImage
        
        switch state {
        case .solid:
            // Filled circle
            image = NSImage(size: size, flipped: false) { rect in
                NSColor.controlTextColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
                return true
            }
        case .half:
            // Half-filled (semicircle)
            image = NSImage(size: size, flipped: false) { rect in
                NSColor.controlTextColor.setFill()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 8, y: 2))
                path.line(to: NSPoint(x: 8, y: 14))
                path.appendArc(withCenter: NSPoint(x: 8, y: 8), radius: 6, startAngle: 270, endAngle: 90)
                path.close()
                path.fill()
                return true
            }
        case .empty:
            // Empty circle (outline)
            image = NSImage(size: size, flipped: false) { rect in
                NSColor.controlTextColor.setStroke()
                let path = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 11, height: 11))
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
        }
        
        image.isTemplate = true
        button.image = image
        print("[SyphonOut Debug] Icon updated to: \(state)")
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        print("[SyphonOut Debug] menuWillOpen")
        menu.removeAllItems()
        MenuBuilder.build(menu: menu, outputManager: outputManager, delegate: self)
    }

    // MARK: - Global shortcuts

    private func registerGlobalShortcuts() {
        print("[SyphonOut Debug] Registering global shortcuts")
        let prefs = PreferencesStore.shared
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == prefs.shortcutFreezeAll.flags && event.keyCode == prefs.shortcutFreezeAll.keyCode {
                print("[SyphonOut Debug] FreezeAll shortcut pressed")
                self.outputManager.freezeAll()
            } else if flags == prefs.shortcutUnfreezeAll.flags && event.keyCode == prefs.shortcutUnfreezeAll.keyCode {
                print("[SyphonOut Debug] UnfreezeAll shortcut pressed")
                self.outputManager.unfreezeAll()
            } else if flags == prefs.shortcutBlankAll.flags && event.keyCode == prefs.shortcutBlankAll.keyCode {
                print("[SyphonOut Debug] BlankAll shortcut pressed")
                self.outputManager.blankAll()
            } else if flags == prefs.shortcutRestoreAll.flags && event.keyCode == prefs.shortcutRestoreAll.keyCode {
                print("[SyphonOut Debug] RestoreAll shortcut pressed")
                self.outputManager.restoreAll()
            }
        }
    }

    deinit {
        print("[SyphonOut Debug] StatusBarController deinit")
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Menu actions

extension StatusBarController {
    @objc func setModeSignal(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] setModeSignal")
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.signal, for: output)
    }

    @objc func setModeFreeze(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] setModeFreeze")
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.freeze, for: output)
    }

    @objc func setModeBlankBlack(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] setModeBlankBlack")
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.blank(.black), for: output)
    }

    @objc func setModeBlankWhite(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] setModeBlankWhite")
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.blank(.white), for: output)
    }

    @objc func setModeBlankTestPattern(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] setModeBlankTestPattern")
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.blank(.testPattern), for: output)
    }

    @objc func setModeOff(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] setModeOff")
        guard let output = sender.representedObject as? OutputController else { return }
        outputManager.setMode(.off, for: output)
    }

    @objc func selectSource(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] selectSource")
        guard let info = sender.representedObject as? [String: Any],
              let output = info["output"] as? OutputController,
              let server = info["server"] as? SyphonServerDescription
        else { return }
        outputManager.selectServer(server, for: output)
    }

    @objc func toggleMirror(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] toggleMirror")
        outputManager.setMirrorEnabled(!outputManager.mirrorEnabled)
    }

    @objc func openPreferences(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] openPreferences")
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        print("[SyphonOut Debug] quitApp")
        NSApp.terminate(nil)
    }
}
