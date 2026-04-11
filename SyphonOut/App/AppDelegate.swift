import AppKit
import os.log

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var outputManager: OutputManager?
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("[SyphonOut Debug] applicationDidFinishLaunching START")
        
        // Menu bar only — no Dock icon (enforced by LSUIElement in Info.plist)
        NSApp.setActivationPolicy(.accessory)
        logger.log("[SyphonOut Debug] Activation policy set to accessory")

        let outputManager = OutputManager()
        self.outputManager = outputManager
        logger.log("[SyphonOut Debug] OutputManager created")

        logger.log("[SyphonOut Debug] Creating StatusBarController...")
        let statusBarController = StatusBarController(outputManager: outputManager)
        self.statusBarController = statusBarController
        logger.log("[SyphonOut Debug] StatusBarController created and stored")

        outputManager.start()
        logger.log("[SyphonOut Debug] OutputManager started")
        
        logger.log("[SyphonOut Debug] applicationDidFinishLaunching COMPLETE")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
