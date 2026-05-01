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

    private var currentMode: SyphonOutMode = SYPHON_OUT_MODE_SIGNAL

    init(display: CGDirectDisplayID) {
        self.displayId = display
        self.displayAlias = PreferencesStore.shared.displayAlias(for: display)
            ?? "Display \(CGDisplayUnitNumber(display))"
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
        // External displays: level 2000 (NSScreenSaverWindowLevel) — above Mission Control (~1500).
        // Built-in MacBook display: level 1000 — above normal apps but below Mission Control,
        // so the machine stays navigable while still covering the desktop.
        let isBuiltin = CGDisplayIsBuiltin(displayId) != 0
        win.level = NSWindow.Level(rawValue: isBuiltin ? 1000 : 2000)
        win.backgroundColor = .black
        win.isOpaque = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

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
    }

    /// Hide the output window (call when the VD assignment is removed).
    func hideOutput() {
        window?.orderOut(nil)
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
    }

    func setServer(uuid: String) {
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
            SOLinkClientClearServer(displayId)  // make sure SOLink is off
        }
    }

    func clearServer() {
        syphonout_output_clear_server(displayId)
        SyphonNativeClearServer(displayId)
        SOLinkClientClearServer(displayId)
    }

    func setScaleMode(_ mode: SyphonOutScaleMode) {
        syphonout_physical_set_scale_mode(displayId, mode)
        PreferencesStore.shared.setScaleMode(mode, for: displayId)
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
