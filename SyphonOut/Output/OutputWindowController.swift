import AppKit
import QuartzCore
import CoreVideo
import IOKit
import IOKit.graphics
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

    /// Text layer shown on BLANK_BLACK mode ("CONFIDENCE\nMONITOR")
    private var confidenceTextLayer: CATextLayer?
    private var modeObserver: NSObjectProtocol?

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
    /// mirrors are applied. Survives CGDirectDisplayID reassignment on mirror creation
    /// and process restarts (persisted to UserDefaults).
    static var displayNameByUnit: [UInt32: String] = loadPersistedDisplayNames() {
        didSet { persistDisplayNames() }
    }

    private static let displayNamesDefaultsKey = "OutputWindowController.displayNameByUnit"

    private static func loadPersistedDisplayNames() -> [UInt32: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: displayNamesDefaultsKey) as? [String: String] else { return [:] }
        var out: [UInt32: String] = [:]
        for (k, v) in raw {
            if let u = UInt32(k) { out[u] = v }
        }
        return out
    }

    private static func persistDisplayNames() {
        let raw = Dictionary(uniqueKeysWithValues: displayNameByUnit.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(raw, forKey: displayNamesDefaultsKey)
    }

    /// Human-readable name for `displayId`.
    /// Priority: user alias → live NSScreen → unit-number cache → IOKit → generic fallback.
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
        // Last resort: ask IOKit for the display's product name.
        // This works even when the display is not in NSScreen.screens (e.g. mirror slave).
        if let ioName = ioKitDisplayName(for: displayId) {
            displayNameByUnit[unit] = ioName   // cache for future lookups
            return ioName
        }
        return "Display \(unit)"
    }

    /// Queries IOKit for the display product name. Works for offline / mirrored displays.
    /// Uses vendor+model+serial matching (CGDisplayIOServicePort was removed in macOS 12).
    static func ioKitDisplayName(for displayId: CGDirectDisplayID) -> String? {
        let cgVendor = Int(CGDisplayVendorNumber(displayId))
        let cgModel  = Int(CGDisplayModelNumber(displayId))
        let cgSerial = Int(CGDisplaySerialNumber(displayId))

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(0,   // 0 = kIOMasterPortDefault
                                           IOServiceMatching("IODisplayConnect"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            guard let cfDict = IODisplayCreateInfoDictionary(service,
                                                              IOOptionBits(kIODisplayOnlyPreferredName)),
                  let info = cfDict.takeRetainedValue() as? [String: Any] else { continue }

            let vendor = info["DisplayVendorID"]     as? Int ?? 0
            let model  = info["DisplayProductID"]    as? Int ?? 0
            let serial = info["DisplaySerialNumber"] as? Int ?? 0

            guard vendor == cgVendor && model == cgModel else { continue }
            if cgSerial != 0 && serial != 0 && serial != cgSerial { continue }

            if let names = info["DisplayProductName"] as? [String: String],
               let name  = names.values.first { return name }
        }
        return nil
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
        modeObserver = NotificationCenter.default.addObserver(
            forName: .vdModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateConfidenceOverlay()
        }
    }

    deinit {
        stopDisplayLink()
        syphonout_output_destroy(displayId)
        if let observer = modeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

        // Container view backed by a regular CALayer (root layer).
        // Both the CAMetalLayer and text CATextLayer are sublayers of this
        // root layer, which guarantees Core Animation composites them correctly.
        let contentView = NSView(frame: NSRect(origin: .zero, size: nsRect.size))
        contentView.wantsLayer = true
        win.contentView = contentView
        guard let rootLayer = contentView.layer else { return }

        // CAMetalLayer sublayer — device MUST be set explicitly before
        // syphonout_output_create otherwise [CAMetalLayer nextDrawable] returns nil
        // until macOS lazily assigns a GPU, and the Rust renderer gets null
        // drawables → black output every frame.
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = screen?.backingScaleFactor ?? 1.0
        metalLayer.drawableSize = CGSize(width: nsRect.width * metalLayer.contentsScale,
                                         height: nsRect.height * metalLayer.contentsScale)
        metalLayer.frame = rootLayer.bounds
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(metalLayer)

        // Confidence monitor text ("CONFIDENCE / MONITOR") — shown as a
        // CATextLayer sibling of the CAMetalLayer on BLANK_BLACK mode.
        let fontSize = round(contentView.bounds.height * 0.065)
        let textLayer = CATextLayer()
        textLayer.string = "CONFIDENCE\nMONITOR"
        textLayer.font = NSFont.systemFont(ofSize: fontSize, weight: .light)
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = NSColor.gray.cgColor
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.contentsScale = metalLayer.contentsScale
        textLayer.isHidden = true
        textLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let textH = fontSize * 3.0
        textLayer.frame = CGRect(
            x: contentView.bounds.width * 0.075,
            y: (contentView.bounds.height - textH) / 2,
            width: contentView.bounds.width * 0.85,
            height: textH
        )
        textLayer.zPosition = 1
        rootLayer.addSublayer(textLayer)
        confidenceTextLayer = textLayer

        // Window starts hidden — shown only when user assigns a VD to this display.
        // This prevents covering the built-in display with a black overlay by default.
        win.orderOut(nil)

        self.window = win
        self.metalLayer = metalLayer
    }

    /// Show the output window (call when a VD is assigned to this display).
    func showOutput() {
        // Refuse to show on a display that's currently a mirror slave — its
        // bounds collapse onto the master, so the output window would cover
        // the wrong physical display (e.g. MacBook when SB220Q mirrors it).
        let mirrorMaster = CGDisplayMirrorsDisplay(displayId)
        if mirrorMaster != kCGNullDirectDisplay {
            AppLog.shared.warn("showOutput refused: display=\(displayId) is mirroring \(mirrorMaster) — would land on master", category: "Output")
            return
        }
        window?.makeKeyAndOrderFront(nil)
        if displayLink.map({ !CVDisplayLinkIsRunning($0) }) == true {
            CVDisplayLinkStart(displayLink!)
        }
        updateConfidenceOverlay()
        AppLog.shared.info("showOutput display=\(displayId)", category: "Output")
    }

    /// Shows or hides the "CONFIDENCE / MONITOR" text depending on the
    /// assigned VD's current mode and whether the PPT preset is active.
    private func updateConfidenceOverlay() {
        guard let textLayer = confidenceTextLayer else { return }
        let vdm = VirtualDisplayManager.shared
        guard let vd = vdm.assignedVD(for: displayId) else {
            textLayer.isHidden = true
            return
        }
        textLayer.isHidden = !(vd.mode == SYPHON_OUT_MODE_BLANK_BLACK
                               && PowerPointPreset.shared.isActive)
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
        updateConfidenceOverlay()

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
