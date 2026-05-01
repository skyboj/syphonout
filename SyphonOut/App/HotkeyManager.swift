/// Global hotkey manager.
///
/// Registers system-wide key monitors so the user can blank / restore outputs
/// even when SyphonOut is not the frontmost app — including when all displays
/// are covered by output windows at NSScreenSaverWindowLevel.
///
/// Hotkeys:
///   ⌃⌥⌘K  — blank all virtual displays to black  (emergency stop)
///   ⌃⌥⌘S  — restore all virtual displays to signal

import AppKit

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onBlankAll:   (() -> Void)?
    var onRestoreAll: (() -> Void)?

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }

        // Global monitor fires even when another app is key.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    // MARK: - Private

    private func handleEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required: NSEvent.ModifierFlags = [.control, .option, .command]
        guard flags == required else { return }

        switch event.keyCode {
        case 40: // K
            onBlankAll?()
        case 1:  // S
            onRestoreAll?()
        default:
            break
        }
    }
}
