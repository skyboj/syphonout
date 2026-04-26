import AppKit

/// Entry-point controller for the Window Routing module.
/// Checks permissions via PermissionManager before loading any UI.
///
/// Steps 2–4 will add WindowInventory, WindowMover, and OutputSlot UI here.
final class WindowRoutingWindowController: NSWindowController {

    static let shared = WindowRoutingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Window Routing"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    /// Called from the menu bar. Checks permissions, then shows the window.
    func showRouting() {
        PermissionManager.shared.requirePermissions(in: nil) { [weak self] granted in
            guard granted else { return }
            self?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
