/// Global hotkey manager.
///
/// Registers system-wide key monitors so the user can blank / restore outputs
/// even when SyphonOut is not the frontmost app — including when all displays
/// are covered by output windows at NSScreenSaverWindowLevel.
///
/// IMPORTANT: NSEvent.addGlobalMonitorForEvents(matching: .keyDown) requires
/// Accessibility permission (System Settings → Privacy & Security → Accessibility).
/// Without it the monitor is registered but silently fires nothing.
/// We call AXIsProcessTrustedWithOptions(prompt: true) on start() so macOS shows
/// the permission dialog automatically on first launch.
///
/// Hotkeys:
///   ⌃⌥⌘K  — blank all virtual displays to black  (emergency stop)
///   ⌃⌥⌘S  — restore all virtual displays to signal

import AppKit
import ApplicationServices

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onBlankAll:   (() -> Void)?
    var onRestoreAll: (() -> Void)?

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }

        // Request Accessibility permission — required for global keyDown monitoring.
        // If not yet granted, macOS shows the system alert asking the user to allow it.
        // After granting, the user must relaunch the app (system requirement).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            // Log — the monitor is registered below but won't fire until permission is granted.
            NSLog("[SyphonOut] HotkeyManager: Accessibility permission not granted yet. " +
                  "Grant it in System Settings → Privacy & Security → Accessibility, then relaunch.")
        }

        // Register the global monitor regardless — it starts working as soon as permission is active.
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
        case 40: // K  (⌃⌥⌘K — blank all)
            DispatchQueue.main.async { self.onBlankAll?() }
        case 1:  // S  (⌃⌥⌘S — restore signal)
            DispatchQueue.main.async { self.onRestoreAll?() }
        default:
            break
        }
    }
}
