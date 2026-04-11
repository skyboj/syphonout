import AppKit
import Metal
import MetalKit

/// Manages one physical display: owns the NSWindow, MetalRenderer, and SyphonClientWrapper.
final class OutputController {
    let screen: NSScreen
    private(set) var mode: OutputMode = .off

    private var window: NSWindow?
    private var renderer: MetalRenderer?
    private var syphonClient: SyphonClientWrapper?

    /// User-visible alias for this display (e.g. "Stage Left")
    var displayAlias: String

    var signalStatus: SignalStatus {
        guard case .signal = mode else { return .noSourceSelected }
        return syphonClient?.hasSignal == true ? .present : .noSignal
    }

    init(screen: NSScreen) {
        self.screen = screen
        self.displayAlias = screen.localizedName
    }

    // MARK: - Mode Transitions

    func setMode(_ newMode: OutputMode, availableServers: [SyphonServerDescription], selectedServer: SyphonServerDescription?) {
        let previousMode = mode
        mode = newMode

        switch newMode {
        case .signal:
            showWindow()
            renderer?.endFreeze()
            if let server = selectedServer {
                connectSyphon(server: server)
            }

        case .freeze:
            renderer?.beginFreeze()
            // Syphon client stays connected in background

        case .blank(let option):
            renderer?.showBlank(option: option)
            if case .signal = previousMode {
                disconnectSyphon()
            }

        case .off:
            hideWindow()
            disconnectSyphon()
        }
    }

    /// Switches the Syphon source for this output.
    /// Works in both Signal (live) and Freeze (background) modes per spec:
    /// "User can switch Source in the menu — new server begins buffering"
    func switchSource(to server: SyphonServerDescription) {
        // Allow switching in signal or freeze mode; other modes have no active Syphon connection
        switch mode {
        case .signal, .freeze:
            connectSyphon(server: server)
        default:
            return
        }
    }

    // MARK: - Window

    private func showWindow() {
        if window == nil {
            createWindow()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func hideWindow() {
        window?.orderOut(nil)
    }

    private func createWindow() {
        let frame = screen.frame
        let win = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // Above Mission Control (~1500); NSScreenSaverWindowLevel = 2000
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isOpaque = true
        win.backgroundColor = .black
        win.setFrameOrigin(frame.origin)

        let device = MTLCreateSystemDefaultDevice()!
        let renderer = MetalRenderer(frame: frame, device: device)
        self.renderer = renderer

        win.contentView = renderer.mtkView
        self.window = win
    }

    // MARK: - Syphon

    private func connectSyphon(server: SyphonServerDescription) {
        let device = MTLCreateSystemDefaultDevice()!
        let client = SyphonClientWrapper(serverDescription: server, device: device) { [weak self] texture in
            self?.renderer?.updateTexture(texture)
        }
        self.syphonClient = client
    }

    private func disconnectSyphon() {
        syphonClient = nil
    }

    // MARK: - Display Identity

    var displayID: CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

enum SignalStatus {
    case present
    case noSignal
    case noSourceSelected

    var description: String {
        switch self {
        case .present: return "✓ Signal present"
        case .noSignal: return "✗ No signal"
        case .noSourceSelected: return "— No source selected"
        }
    }
}
