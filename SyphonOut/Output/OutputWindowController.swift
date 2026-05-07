import AppKit
import QuartzCore
import CoreVideo
import os.log

/// Manages one fullscreen NSWindow per display.
/// Creates a CAMetalLayer, registers it with the Rust core, and drives
/// the render loop via CVDisplayLink.
final class OutputWindowController {

    let displayId: CGDirectDisplayID
    let displayAlias: String

    private var window: NSWindow?
    private var metalLayer: CAMetalLayer?
    private var displayLink: CVDisplayLink?
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "OutputWindow")

    private(set) var currentMode: SyphonOutMode = SYPHON_OUT_MODE_SIGNAL

    var isVisible: Bool { window?.isVisible ?? false }

    /// True when this display currently carries the macOS menu bar.
    var isMainDisplay: Bool {
        guard let mainID = NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return mainID == displayId
    }

    /// True when the display is physically connected but OS-mirrored
    /// (no longer in NSScreen.screens).
    var isMirrored: Bool {
        let inScreens = NSScreen.screens.contains {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayId
        }
        return !inScreens && CGDisplayIsOnline(displayId) != 0
    }

    /// Cache of display names by unit number, populated by AppDelegate before
    /// mirrors are applied. Survives CGDirectDisplayID reassignment on mirror creation.
    static var displayNameByUnit: [UInt32: String] = [:]

    /// Human-readable name for `displayId`.
    /// Priority: user alias → live NSScreen → unit-number cache (mirrored) → generic fallback.
    static func screenName(for displayId: CGDirectDisplayID) -> String {
        if let alias = PreferencesStore.shared.displayAlias(for: displayId) { return alias }
        if let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayId
        }) {
            // Also keep the cache fresh while the display is live.
            displayNameByUnit[CGDisplayUnitNumber(displayId)] = screen.localizedName
            return screen.localizedName
        }
        // Mirrored / off-screen display — look up the cached name by unit number.
        let unit = CGDisplayUnitNumber(displayId)
        if let cached = displayNameByUnit[unit] { return cached }
        return "Display \(unit)"
    }

    /// Seed the name cache from the current NSScreen list. Call this at launch and
    /// on every screen-change event so names survive future mirror operations.
    static func seedNameCache() {
        for screen in NSScreen.screens {
            guard let displayId = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            displayNameByUnit[CGDisplayUnitNumber(displayId)] = screen.localizedName
        }
    }

    init(display: CGDirectDisplayID) {
        self.displayId = display
        self.displayAlias = OutputWindowController.screenName(for: display)
        setupWindow()
        setupRustOutput()
        setupDisplayLink()
    }

    deinit {
        stopDisplayLink()
        syphonout_output_destroy(displayId)
    }

    // MARK: - Window

    private func setupWindow() {
        // NSWindow(contentRect:) expects AppKit screen coordinates:
        //   origin = bottom-left of the primary display, y increasing upward.
        // CGDisplayBounds returns Quartz coordinates (y increasing downward) —
        // using it directly causes the window to be mis-positioned on any display
        // whose top edge doesn't align with the primary's top edge.
        // NSScreen.frame is already in AppKit coordinates, so use it directly.
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayId
        }
        let nsRect = screen?.frame ?? {
            // Fallback (display not yet in NSScreen.screens): convert Quartz → AppKit.
            let q = CGDisplayBounds(displayId)
            let primaryH = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
            return NSRect(x: q.origin.x,
                          y: primaryH - q.origin.y - q.size.height,
                          width: q.size.width,
                          height: q.size.height)
        }()

        let win = NSWindow(
            contentRect: nsRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // External displays: level 2000 (NSScreenSaverWindowLevel) — above Mission Control.
        // Built-in MacBook display: level 3 (NSFloatingWindowLevel) — above normal apps,
        // but below Mission Control so the Mac stays fully navigable.
        // Also skip .stationary/.ignoresCycle so Mission Control can see and manage the window.
        let isBuiltin = CGDisplayIsBuiltin(displayId) != 0
        if isBuiltin {
            win.level = NSWindow.Level(rawValue: 3)   // floating — below Mission Control
            win.collectionBehavior = [.canJoinAllSpaces]
        } else {
            win.level = NSWindow.Level(rawValue: 2000) // screen saver — above Mission Control
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        win.backgroundColor = .black
        win.isOpaque = true
        win.ignoresMouseEvents = true

        // CAMetalLayer as the window's content view.
        // device MUST be set explicitly before syphonout_output_create — otherwise
        // [CAMetalLayer nextDrawable] returns nil until macOS lazily assigns a GPU,
        // and the Rust renderer gets null drawables → black output every frame.
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = screen?.backingScaleFactor ?? 1.0
        layer.drawableSize = CGSize(width: nsRect.width * layer.contentsScale,
                                    height: nsRect.height * layer.contentsScale)

        let contentView = NSView(frame: NSRect(origin: .zero, size: nsRect.size))
        contentView.wantsLayer = true
        contentView.layer = layer
        win.contentView = contentView

        // Window starts hidden — shown only when user assigns a VD to this display.
        // This prevents covering the built-in display with a black overlay by default.
        win.orderOut(nil)

        self.window = win
        self.metalLayer = layer
    }

    /// Show the output window (call when a VD is assigned to this display).
    func showOutput() {
        window?.makeKeyAndOrderFront(nil)
        if displayLink.map({ !CVDisplayLinkIsRunning($0) }) == true {
            CVDisplayLinkStart(displayLink!)
        }
        AppLog.shared.info("showOutput display=\(displayId)", category: "Output")
    }

    /// Hide the output window (call when the VD assignment is removed).
    func hideOutput() {
        window?.orderOut(nil)
        AppLog.shared.info("hideOutput display=\(displayId)", category: "Output")
    }

    // MARK: - Rust output registration

    private func setupRustOutput() {
        guard let layer = metalLayer else { return }
        let ptr = Unmanaged.passUnretained(layer).toOpaque()
        syphonout_output_create(displayId, ptr)
        // Restore persisted scale mode (Fill/Fit) for this display.
        let savedMode = PreferencesStore.shared.scaleMode(for: displayId)
        syphonout_physical_set_scale_mode(displayId, savedMode)
    }

    // MARK: - Mode / server API (called by StatusBarController)

    func setMode(_ mode: SyphonOutMode) {
        currentMode = mode
        syphonout_output_set_mode(displayId, mode)
        AppLog.shared.info("setMode display=\(displayId) → \(modeName(mode))", category: "Output")

        // Any mode other than Off should make the output window visible.
        // This handles the case where the window was hidden by hideOutput()
        // (e.g. after unassigning a VD) and the user picks TestPattern or
        // another mode directly — we must re-show the window so it's visible.
        if mode == SYPHON_OUT_MODE_OFF {
            window?.orderOut(nil)
        } else {
            if window?.isVisible == false {
                AppLog.shared.info("setMode: window was hidden → showing display=\(displayId)", category: "Output")
                window?.makeKeyAndOrderFront(nil)
                if displayLink.map({ !CVDisplayLinkIsRunning($0) }) == true {
                    CVDisplayLinkStart(displayLink!)
                }
            }
        }
    }

    func setServer(uuid: String) {
        AppLog.shared.info("setServer display=\(displayId) uuid=\(uuid)", category: "Output")
        uuid.withCString { cStr in
            syphonout_output_set_server(displayId, cStr)
        }
        if uuid.hasPrefix("solink:") {
            // SOLink server: strip prefix, open SHM, start polling IOSurfaces
            let rawUUID = String(uuid.dropFirst("solink:".count))
            rawUUID.withCString { SOLinkClientSetServer(displayId, $0) }
            SyphonNativeClearServer(displayId)  // make sure Syphon is off
        } else {
            // Syphon server: connect via dlopen'd SyphonClient
            uuid.withCString { SyphonNativeSetServer(displayId, $0) }
            SOLinkClientClearServer(displayId)
        }
    }

    func clearServer() {
        syphonout_output_clear_server(displayId)
        SyphonNativeClearServer(displayId)
        SOLinkClientClearServer(displayId)
        AppLog.shared.info("clearServer display=\(displayId)", category: "Output")
    }

    func setScaleMode(_ mode: SyphonOutScaleMode) {
        syphonout_physical_set_scale_mode(displayId, mode)
        PreferencesStore.shared.setScaleMode(mode, for: displayId)
        let label = (mode == SYPHON_OUT_SCALE_MODE_FILL) ? "Fill" : "Fit"
        AppLog.shared.info("setScaleMode display=\(displayId) → \(label)", category: "Output")
    }

    private func modeName(_ mode: SyphonOutMode) -> String {
        switch mode {
        case SYPHON_OUT_MODE_SIGNAL:             return "Signal"
        case SYPHON_OUT_MODE_FREEZE:             return "Freeze"
        case SYPHON_OUT_MODE_BLANK_BLACK:        return "BlankBlack"
        case SYPHON_OUT_MODE_BLANK_WHITE:        return "BlankWhite"
        case SYPHON_OUT_MODE_BLANK_TEST_PATTERN: return "TestPattern"
        case SYPHON_OUT_MODE_OFF:                return "Off"
        default: return "Mode(\(mode.rawValue))"
        }
    }

    var currentScaleMode: SyphonOutScaleMode {
        PreferencesStore.shared.scaleMode(for: displayId)
    }

    // MARK: - CVDisplayLink render loop

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        let err = CVDisplayLinkCreateWithCGDisplay(displayId, &link)
        guard err == kCVReturnSuccess, let link else {
            logger.error("CVDisplayLinkCreateWithCGDisplay failed: \(err)")
            return
        }

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let controller = Unmanaged<OutputWindowController>.fromOpaque(userInfo)
                .takeUnretainedValue()
            syphonout_render_frame(controller.displayId)
            return kCVReturnSuccess
        }, selfPtr)

        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        self.displayLink = nil
    }
}
