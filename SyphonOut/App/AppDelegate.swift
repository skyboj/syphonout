import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var outputManager: OutputManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[SyphonOut Debug] applicationDidFinishLaunching START")
        
        // Menu bar only — no Dock icon (enforced by LSUIElement in Info.plist)
        NSApp.setActivationPolicy(.accessory)
        print("[SyphonOut Debug] Activation policy set to accessory")

        let outputManager = OutputManager()
        self.outputManager = outputManager
        print("[SyphonOut Debug] OutputManager created")

        print("[SyphonOut Debug] Creating StatusBarController...")
        let statusBarController = StatusBarController(outputManager: outputManager)
        self.statusBarController = statusBarController
        print("[SyphonOut Debug] StatusBarController created and stored")

        outputManager.start()
        print("[SyphonOut Debug] OutputManager started")
        
        print("[SyphonOut Debug] applicationDidFinishLaunching COMPLETE")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
