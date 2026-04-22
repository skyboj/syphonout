import AppKit
import os.log

@objc(AppDelegate)
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var outputs: [OutputWindowController] = []
    private var statusBarController: StatusBarController?
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Boot Rust core
        syphonout_core_init()

        // 2. Load Syphon.framework at runtime and begin server discovery
        //    (discovery calls syphonout_on_server_announced / syphonout_on_server_retired)
        SyphonNativeLoad()
        SyphonNativeStartDiscovery()

        // 2b. SOLink subscriber — discovers OBS obs-solink publishers via
        //     NSDistributedNotificationCenter. Servers appear in the same
        //     unified list as Syphon servers, prefixed with "solink:".
        SOLinkClientInit()
        SOLinkClientStartDiscovery()

        // 3. Wire crossfade duration from prefs
        let ms = PreferencesStore.shared.crossfadeDuration * 1000.0
        syphonout_set_crossfade_duration_ms(ms)

        // 4. One OutputWindowController per active display
        for screen in NSScreen.screens {
            guard let displayId = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            let controller = OutputWindowController(display: displayId)
            outputs.append(controller)
        }

        // 5. Register server-changed callback so the menu rebuilds on server list changes
        syphonout_set_server_changed_callback({ _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .syphonServersChanged, object: nil)
            }
        }, nil)

        // 6. Menu bar
        statusBarController = StatusBarController(outputs: outputs)

        logger.info("SyphonOut started — \(self.outputs.count) display(s)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        SOLinkClientStop()
        SyphonNativeStop()
        syphonout_core_deinit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let syphonServersChanged = Notification.Name("SyphonOutServersChanged")
}
