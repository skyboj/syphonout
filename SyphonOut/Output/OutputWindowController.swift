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
        let screenRect = CGDisplayBounds(displayId)
        let nsRect = NSRect(
            x: screenRect.origin.x,
            y: screenRect.origin.y,
            width: screenRect.size.width,
            height: screenRect.size.height
        )

        let win = NSWindow(
            contentRect: nsRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: 2000)   // above Mission Control (~1500)
        win.backgroundColor = .black
        win.isOpaque = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // CAMetalLayer as the window's content view
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = NSScreen.screens
            .first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayId })?
            .backingScaleFactor ?? 1.0
        layer.drawableSize = CGSize(width: nsRect.width * layer.contentsScale,
                                    height: nsRect.height * layer.contentsScale)

        let contentView = NSView(frame: nsRect)
        contentView.wantsLayer = true
        contentView.layer = layer
        win.contentView = contentView

        win.makeKeyAndOrderFront(nil)

        self.window = win
        self.metalLayer = layer
    }

    // MARK: - Rust output registration

    private func setupRustOutput() {
        guard let layer = metalLayer else { return }
        let ptr = Unmanaged.passUnretained(layer).toOpaque()
        syphonout_output_create(displayId, ptr)
    }

    // MARK: - Mode / server API (called by StatusBarController)

    func setMode(_ mode: SyphonOutMode) {
        currentMode = mode
        syphonout_output_set_mode(displayId, mode)
    }

    func setServer(uuid: String) {
        uuid.withCString { cStr in
            syphonout_output_set_server(displayId, cStr)
            SyphonNativeSetServer(displayId, cStr)
        }
    }

    func clearServer() {
        syphonout_output_clear_server(displayId)
        SyphonNativeClearServer(displayId)
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
