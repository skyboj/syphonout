import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var outputManager: OutputManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon (enforced by LSUIElement in Info.plist)
        NSApp.setActivationPolicy(.accessory)

        let outputManager = OutputManager()
        self.outputManager = outputManager

        let statusBarController = StatusBarController(outputManager: outputManager)
        self.statusBarController = statusBarController

        outputManager.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
