import AppKit

/// PowerPoint Presentation Setup panel.
///
/// Shows a live snapshot of every physically-connected display (including
/// OS-mirrored ones) so the user can assign roles, hit Apply, and have the
/// Slide Show window automatically moved to the right screen.
///
/// Apply order:
///   1. Apply/remove OS mirrors.
///   2. Wait 500 ms for macOS to settle and relocate any windows that were
///      on the now-slave display.
///   3. Look for the PPT Slide Show window.  If found → move immediately.
///      If not found → start a WindowInventory watcher that fires when
///      the window eventually appears.

final class PowerPointSetupWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PowerPointSetupWindowController()

    // MARK: - State

    enum Role: Int, CaseIterable {
        case notUsed       = 0
        case slideShow     = 1
        case speakerMirror = 2

        var label: String {
            switch self {
            case .notUsed:       return "Not Used"
            case .slideShow:     return "Slide Show"
            case .speakerMirror: return "Speaker Notes (Mirror)"
            }
        }
    }

    /// All physically-connected display IDs (NSScreen AND online-but-mirrored).
    private var displayIDs:   [CGDirectDisplayID] = []
    private var roleCards:    [DisplayCard]        = []
    /// Roles keyed by unit number (stable across mirror-set ID reassignments).
    private var rolesByUnit:  [UInt32: Role] = [:]
    /// Display names keyed by unit number — populated from NSScreen.localizedName
    /// and surviving ID changes when macOS creates/removes mirror sets.
    private var nameByUnit:   [UInt32: String] = [:]

    private var stackView:    NSStackView!
    private var statusLabel:  NSTextField!
    private var applyButton:  NSButton!
    private var removeMirrorButton: NSButton!

    private var displayRefreshTimer: Timer?

    /// Watcher for PPT Slide Show — stores the target as a CGDirectDisplayID
    /// so the NSScreen reference is resolved fresh at move time.
    private var slideShowWatcher:    WindowInventory?
    private var watchTargetDisplayID: CGDirectDisplayID?

    // MARK: - Init

    private init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "PowerPoint Setup"
        win.center()
        win.minSize = NSSize(width: 480, height: 280)
        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDisplays()
        startDisplayRefreshTimer()
        requestAppleEventsPermission()
    }

    /// Proactively request Automation permission for Microsoft PowerPoint.
    /// macOS 10.14+ requires explicit user authorization before any Apple Event
    /// can be sent. Running a benign "get name" script triggers the system dialog
    /// the first time; subsequent calls are instant (TCC cache hit).
    private func requestAppleEventsPermission() {
        DispatchQueue.global(qos: .background).async {
            var errDict: NSDictionary?
            let script = NSAppleScript(source: """
            tell application "Microsoft PowerPoint"
                get name
            end tell
            """)
            let result = script?.executeAndReturnError(&errDict)
            DispatchQueue.main.async {
                if let e = errDict {
                    let msg = e["NSAppleScriptErrorMessage"] as? String ?? "\(e)"
                    if msg.contains("Not authorized") {
                        AppLog.shared.warn("PPT AS: Automation permission denied — ask user to enable in System Settings → Privacy & Security → Automation", category: "PPTSetup")
                    } else {
                        AppLog.shared.info("PPT AS: permission probe: \(msg)", category: "PPTSetup")
                    }
                } else {
                    AppLog.shared.info("PPT AS: Automation permission granted (probe='\(result?.stringValue ?? "ok")')", category: "PPTSetup")
                }
            }
        }
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing     = 16
        stackView.alignment   = .top
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = stackView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller   = false
        scrollView.autohidesScrollers    = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        applyButton = NSButton(title: "Apply", target: self, action: #selector(applySetup))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.translatesAutoresizingMaskIntoConstraints = false

        removeMirrorButton = NSButton(title: "Remove Mirror", target: self, action: #selector(removeMirror))
        removeMirrorButton.bezelStyle = .rounded
        removeMirrorButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(applyButton)
        contentView.addSubview(removeMirrorButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -12),

            applyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            removeMirrorButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            removeMirrorButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeMirrorButton.leadingAnchor, constant: -8),
        ])
    }

    // MARK: - Display refresh

    /// Returns all physically connected display IDs — both active (in NSScreen.screens)
    /// and online-but-mirrored (not in NSScreen.screens, but CGDisplayIsOnline).
    private func allOnlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private func refreshDisplays() {
        // Active displays (in NSScreen.screens) — update name cache by unit number.
        let activeIDs: [CGDirectDisplayID] = NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nameByUnit[CGDisplayUnitNumber(id)] = screen.localizedName
            }
        }
        let activeSet = Set(activeIDs)

        // Append online-but-not-active IDs (mirror slaves — new IDs, same hardware).
        let mirroredIDs = allOnlineDisplayIDs().filter { !activeSet.contains($0) }
        let allIDs = activeIDs + mirroredIDs

        if allIDs != displayIDs {
            displayIDs = allIDs
            rebuildCards(allIDs: allIDs)
        }

        // Refresh snapshots only for active (non-mirrored) displays.
        for card in roleCards where activeSet.contains(card.displayID) {
            card.refreshSnapshot()
        }
    }

    private func rebuildCards(allIDs: [CGDirectDisplayID]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        roleCards.removeAll()

        let activeSet: Set<CGDirectDisplayID> = Set(NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        })

        for displayID in allIDs {
            let unit     = CGDisplayUnitNumber(displayID)
            let isMirror = !activeSet.contains(displayID)

            // Look up name by unit number — survives ID changes after mirroring.
            let name = nameByUnit[unit] ?? "Display \(unit)"

            // Look up (or default) role by unit number.
            let role: Role
            if let saved = rolesByUnit[unit] {
                role = saved
            } else {
                role = defaultRole(for: displayID, in: allIDs)
                rolesByUnit[unit] = role
            }

            let card = DisplayCard(
                displayID:    displayID,
                displayName:  name,
                isMirrored:   isMirror,
                initialRole:  role
            ) { [weak self] newRole in
                self?.rolesByUnit[unit] = newRole
            }
            roleCards.append(card)
            stackView.addArrangedSubview(card)
        }
    }

    private func defaultRole(for displayID: CGDirectDisplayID, in allIDs: [CGDirectDisplayID]) -> Role {
        if CGDisplayIsBuiltin(displayID) != 0 { return .speakerMirror }
        let firstExternal = allIDs.first { CGDisplayIsBuiltin($0) == 0 }
        if displayID == firstExternal { return .slideShow }
        return .notUsed
    }

    // MARK: - Display refresh timer

    private func startDisplayRefreshTimer() {
        stopDisplayRefreshTimer()
        displayRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshDisplays()
        }
    }

    private func stopDisplayRefreshTimer() {
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopDisplayRefreshTimer()
        stopSlideShowWatcher()
    }

    // MARK: - Apply

    @objc private func applySetup() {
        stopSlideShowWatcher()
        applyButton.isEnabled = false

        // Build ID→role map from unit-based roles (for all currently known IDs).
        let slideShowID      = displayIDs.first { rolesByUnit[CGDisplayUnitNumber($0)] == .slideShow }
        let speakerMirrorIDs = displayIDs.filter  { rolesByUnit[CGDisplayUnitNumber($0)] == .speakerMirror }
        let builtinID        = displayIDs.first { CGDisplayIsBuiltin($0) != 0 }

        var messages: [String] = []

        // ── 1a. Remove mirrors for displays no longer assigned Speaker Notes ──
        // If a display is currently in an OS mirror set but the user changed its
        // role, remove the mirror so it can act independently again.
        for displayID in displayIDs {
            let unit = CGDisplayUnitNumber(displayID)
            let role = rolesByUnit[unit] ?? .notUsed
            // CGDisplayMirrorsDisplay returns the display this one mirrors, or 0.
            if CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay && role != .speakerMirror {
                let name = nameByUnit[unit] ?? "\(displayID)"
                AppLog.shared.info("PPT Setup: removing mirror on \(name) (role changed to \(role.label))", category: "PPTSetup")
                removeSystemMirror(for: displayID)
                messages.append("Unmirror: \(name)")
            }
        }

        // ── 1b. Apply mirrors for Speaker Notes displays ──────────────────
        let mirrorMasterID: CGDirectDisplayID? = builtinID ?? speakerMirrorIDs.first
        let displaysToMirror = speakerMirrorIDs.filter { $0 != mirrorMasterID }

        if displaysToMirror.isEmpty && speakerMirrorIDs.contains(where: { $0 == builtinID }) {
            messages.append("Speaker: MacBook (no mirror needed)")
        } else {
            for mirrorID in displaysToMirror {
                guard let masterID = mirrorMasterID else { continue }
                applySystemMirror(mirrorDisplay: mirrorID, masterDisplay: masterID)
                let mirrorName = nameByUnit[CGDisplayUnitNumber(mirrorID)] ?? "\(mirrorID)"
                let masterName = nameByUnit[CGDisplayUnitNumber(masterID)] ?? "\(masterID)"
                AppLog.shared.info("PPT Setup: system mirror \(mirrorName) ← \(masterName)", category: "PPTSetup")
                messages.append("Mirror: \(mirrorName) ← \(masterName)")
            }
        }

        // ── 2. Move Slide Show window ─────────────────────────────────────
        // Store the target as a plain ID — resolve to NSScreen fresh at move
        // time so we're not holding a stale NSScreen reference from before the
        // mirror config change.
        guard let targetID = slideShowID else {
            if messages.isEmpty { messages.append("Roles saved") }
            setStatus("✓ " + messages.joined(separator: "  |  "))
            applyButton.isEnabled = true
            return
        }

        // Wait 500 ms after applying mirrors: macOS needs a runloop pass to
        // update NSScreen.screens and relocate windows from slave displays.
        let mirrorMsg = messages.joined(separator: "  |  ")
        setStatus((mirrorMsg.isEmpty ? "" : mirrorMsg + "  |  ") + "⏳ Moving Slide Show…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.applyButton.isEnabled = true
            self.moveSlideShowToDisplay(targetID: targetID, mirrorMsg: mirrorMsg)
        }
    }

    private func moveSlideShowToDisplay(targetID: CGDirectDisplayID, mirrorMsg: String) {
        // Resolve target NSScreen fresh after mirror config has settled.
        guard let targetScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetID
        }) else {
            AppLog.shared.warn("PPT Setup: target display \(targetID) not in NSScreen.screens after settling", category: "PPTSetup")
            setStatus((mirrorMsg.isEmpty ? "" : mirrorMsg + "  |  ") + "⚠ Target display unavailable")
            return
        }

        // PRIMARY: set PPT's own slide show monitor preference via AppleScript.
        // This is the only reliable mechanism — PPT overrides external window moves.
        setPPTSlideShowMonitor(targetDisplayID: targetID)

        let screenName = targetScreen.localizedName
        let prefix = mirrorMsg.isEmpty ? "" : mirrorMsg + "  |  "

        if findSlideShowWindow() != nil {
            // Slide Show already running — fallback window move (may work for non-FS windows).
            if let window = findSlideShowWindow() {
                WindowMover.move(window, to: targetScreen, resize: true, fullscreen: false)
            }
            setStatus(prefix + "✓ Slide Show monitor → \(screenName) (restart presentation to apply)")
        } else {
            // Presentation not started yet — watcher will also try AppleScript once PPT
            // opens a presentation, then verify the Slide Show appears on the right screen.
            watchTargetDisplayID = targetID
            setStatus(prefix + "✓ Slide Show monitor set → \(screenName)  |  Start presentation to begin")
            startSlideShowWatcher(targetDisplayID: targetID)
        }
    }

    @objc private func removeMirror() {
        for id in displayIDs {
            removeSystemMirror(for: id)
        }
        AppLog.shared.info("PPT Setup: removed all system mirrors", category: "PPTSetup")
        setStatus("✓ Mirror removed")
    }

    private func setStatus(_ msg: String) {
        statusLabel.stringValue = msg
    }

    // MARK: - WindowInventory watcher

    private func startSlideShowWatcher(targetDisplayID: CGDirectDisplayID) {
        let watcher = WindowInventory()
        var monitorAlreadySet = false   // avoid spamming AppleScript every 0.5s

        watcher.onUpdate = { [weak self] (windows: [WindowInfo]) in
            guard let self else { return }

            let pptWindows = windows.filter { $0.appName.localizedCaseInsensitiveContains("PowerPoint") }
            guard !pptWindows.isEmpty else { return }

            // As soon as PPT is running (any window), set its slide show monitor.
            // Do this once per watcher session so we don't spam AppleScript.
            if !monitorAlreadySet {
                monitorAlreadySet = true
                self.setPPTSlideShowMonitor(targetDisplayID: targetDisplayID)
            }

            // Once the Slide Show window actually appears, verify it landed on the
            // right display.  If not (PPT ignored our AppleScript), try window move.
            guard let slideShowWindow = pptWindows.first(where: {
                $0.title.localizedCaseInsensitiveContains("Slide Show")
            }) else { return }

            guard let targetScreen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetDisplayID
            }) else {
                AppLog.shared.warn("PPT watcher: target display gone", category: "PPTSetup")
                self.stopSlideShowWatcher()
                return
            }

            // Check if window is already on the right screen.
            let windowMidX = slideShowWindow.frame.midX
            let primaryH   = NSScreen.screens.first?.frame.height ?? 0
            let windowMidY = primaryH - slideShowWindow.frame.midY   // Quartz→AppKit
            let alreadyOnTarget = targetScreen.frame.contains(CGPoint(x: windowMidX, y: windowMidY))

            if alreadyOnTarget {
                AppLog.shared.info("PPT watcher: Slide Show is on \(targetScreen.localizedName) ✓", category: "PPTSetup")
                self.setStatus("✓ Slide Show → \(targetScreen.localizedName)")
            } else {
                AppLog.shared.warn(
                    "PPT watcher: Slide Show on wrong display — restarting via AppleScript on \(targetScreen.localizedName)",
                    category: "PPTSetup"
                )
                // AX window moves are unreliable for PPT fullscreen. Instead, stop the
                // current slide show and let PPT re-open it on the correct monitor
                // (already configured via |slide show monitor| earlier).
                self.restartSlideShowOnCorrectMonitor()
                self.setStatus("↩ Restarting Slide Show → \(targetScreen.localizedName)")
            }
            self.stopSlideShowWatcher()
        }
        // Fast polling: catch PPT before it commits to fullscreen on wrong display.
        watcher.start(interval: 0.5)
        slideShowWatcher = watcher
    }

    private func stopSlideShowWatcher() {
        slideShowWatcher?.stop()
        slideShowWatcher  = nil
        watchTargetDisplayID = nil
    }

    /// Stops the running PPT Slide Show and immediately restarts it so macOS
    /// places it on the monitor configured by |slide show monitor|.
    private func restartSlideShowOnCorrectMonitor() {
        let source = """
        tell application "Microsoft PowerPoint"
            try
                if (count of presentations) = 0 then return "no-presentation"
                set ap to active presentation
                -- Stop any running slide show
                try
                    set ssw to slide show window of ap
                    end show ssw
                end try
                -- Small pause for the window to close
                delay 0.4
                -- Restart on the configured monitor
                run slide show (slide show settings of ap)
                return "restarted"
            on error e
                return "error:" & e
            end try
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var errDict: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&errDict)
            DispatchQueue.main.async {
                if let e = errDict {
                    let msg = e["NSAppleScriptErrorMessage"] as? String ?? "\(e)"
                    AppLog.shared.error("PPT restart error: \(msg)", category: "PPTSetup")
                } else {
                    AppLog.shared.info("PPT restart result: \(result?.stringValue ?? "nil")", category: "PPTSetup")
                }
            }
        }
    }

    // MARK: - PowerPoint AppleScript

    /// Sets PPT's own "Slide Show > Show on" display preference via AppleScript.
    ///
    /// This is the primary mechanism — more reliable than AX window moves because
    /// PPT respects its own setting and immediately routes future Slide Shows there.
    ///
    /// PPT numbers monitors 1-based in the same order as NSScreen.screens.
    /// We find the target display's index in NSScreen.screens and pass that.
    private func setPPTSlideShowMonitor(targetDisplayID: CGDirectDisplayID) {
        let screens = NSScreen.screens
        guard let idx = screens.firstIndex(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetDisplayID
        }) else {
            AppLog.shared.warn("PPT AS: target display \(targetDisplayID) not in NSScreen — skipping", category: "PPTSetup")
            return
        }
        let monitorNumber = idx + 1   // PPT uses 1-based monitor index
        let screenName = screens[idx].localizedName

        // Three-word property names need pipe notation |...| to parse correctly.
        // Also enable Presenter View so PowerPoint shows speaker notes + controls
        // on the MacBook display automatically when the slide show runs on the
        // external monitor.
        let source = """
        tell application "Microsoft PowerPoint"
            try
                if (count of presentations) = 0 then return "no-presentation"
                set sss to slide show settings of active presentation
                tell sss
                    set |slide show monitor| to \(monitorNumber)
                    -- Enable Presenter View so MacBook gets speaker notes / controls
                    try
                        set |show presenter tools| to true
                    end try
                end tell
                return "ok-piped:\(monitorNumber)"
            on error outerErr
                return "OUTER:" & outerErr
            end try
        end tell
        """

        AppLog.shared.info("PPT AS: setting slideShowMonitor=\(monitorNumber) (\(screenName))", category: "PPTSetup")

        DispatchQueue.global(qos: .userInitiated).async {
            var errDict: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&errDict)
            DispatchQueue.main.async {
                if let e = errDict {
                    let msg = e["NSAppleScriptErrorMessage"] as? String ?? "\(e)"
                    AppLog.shared.error("PPT AS error: \(msg)", category: "PPTSetup")
                } else {
                    AppLog.shared.info("PPT AS result: \(result?.stringValue ?? "nil")", category: "PPTSetup")
                }
            }
        }
    }

    // MARK: - System mirror API

    private func applySystemMirror(mirrorDisplay: CGDirectDisplayID, masterDisplay: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == CGError.success,
              let config else {
            AppLog.shared.error("PPT Setup: CGBeginDisplayConfiguration failed", category: "PPTSetup")
            return
        }
        CGConfigureDisplayMirrorOfDisplay(config, mirrorDisplay, masterDisplay)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err != CGError.success {
            AppLog.shared.error("PPT Setup: CGCompleteDisplayConfiguration err=\(err.rawValue)", category: "PPTSetup")
        }
    }

    private func removeSystemMirror(for displayID: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == CGError.success,
              let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    // MARK: - PowerPoint window lookup

    /// Finds the PPT Slide Show window using CGWindowList (ALL windows, not just
    /// onscreen-only — catches fullscreen windows on other Spaces).
    private func findSlideShowWindow() -> WindowInfo? {
        guard let entry = pptSnapshotWindows().first(where: {
            $0.appName.localizedCaseInsensitiveContains("PowerPoint") &&
            $0.title.localizedCaseInsensitiveContains("Slide Show")
        }) else { return nil }

        return WindowInfo(
            id:      entry.id,
            title:   entry.title,
            appName: entry.appName,
            appIcon: nil,
            pid:     entry.pid,
            frame:   entry.frame
        )
    }
}

// MARK: - DisplayCard

final class DisplayCard: NSView {

    let displayID:   CGDirectDisplayID
    let displayName: String
    let isMirrored:  Bool
    private let onRoleChange: (PowerPointSetupWindowController.Role) -> Void

    private let snapshotView: NSImageView
    private let nameLabel:    NSTextField
    private let rolePicker:   NSPopUpButton

    init(
        displayID:    CGDirectDisplayID,
        displayName:  String,
        isMirrored:   Bool,
        initialRole:  PowerPointSetupWindowController.Role,
        onRoleChange: @escaping (PowerPointSetupWindowController.Role) -> Void
    ) {
        self.displayID    = displayID
        self.displayName  = displayName
        self.isMirrored   = isMirrored
        self.onRoleChange = onRoleChange

        snapshotView = NSImageView()
        snapshotView.imageScaling   = .scaleProportionallyUpOrDown
        snapshotView.imageAlignment = .alignCenter
        snapshotView.wantsLayer     = true
        snapshotView.layer?.cornerRadius      = 4
        snapshotView.layer?.masksToBounds     = true
        snapshotView.layer?.backgroundColor   = NSColor(white: 0.1, alpha: 1).cgColor
        snapshotView.translatesAutoresizingMaskIntoConstraints = false

        let isMain = (NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        let nameSuffix = isMain ? " (Main)" : isMirrored ? " ⌀" : ""
        nameLabel = NSTextField(labelWithString: displayName + nameSuffix)
        nameLabel.font      = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        rolePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        rolePicker.translatesAutoresizingMaskIntoConstraints = false
        for role in PowerPointSetupWindowController.Role.allCases {
            rolePicker.addItem(withTitle: role.label)
            rolePicker.lastItem?.tag = role.rawValue
        }
        rolePicker.selectItem(withTag: initialRole.rawValue)
        // Mirrored displays are still assignable — changing role and clicking
        // Apply will remove the mirror and apply the new configuration.

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(snapshotView)
        addSubview(nameLabel)
        addSubview(rolePicker)

        // Built-in: blue accent border; mirrored: dim border
        wantsLayer = true
        if CGDisplayIsBuiltin(displayID) != 0 {
            layer?.borderColor  = NSColor.controlAccentColor.cgColor
            layer?.borderWidth  = 1.5
            layer?.cornerRadius = 6
        } else if isMirrored {
            layer?.borderColor  = NSColor.tertiaryLabelColor.cgColor
            layer?.borderWidth  = 1
            layer?.cornerRadius = 6
        }

        rolePicker.target = self
        rolePicker.action = #selector(pickerChanged)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 210),

            snapshotView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            snapshotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            snapshotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            snapshotView.heightAnchor.constraint(equalTo: snapshotView.widthAnchor, multiplier: 9.0 / 16.0),

            nameLabel.topAnchor.constraint(equalTo: snapshotView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            rolePicker.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            rolePicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            rolePicker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            rolePicker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        if isMirrored {
            // Show a "⌀ Mirrored" overlay on the snapshot area
            let label = NSTextField(labelWithString: "⌀  Mirrored")
            label.font      = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: snapshotView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: snapshotView.centerYAnchor),
            ])
        }

        refreshSnapshot()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshSnapshot() {
        guard !isMirrored else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let cgImage = CGDisplayCreateImage(self.displayID) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            DispatchQueue.main.async { self.snapshotView.image = nsImage }
        }
    }

    @objc private func pickerChanged() {
        let rawValue = rolePicker.selectedTag()
        if let role = PowerPointSetupWindowController.Role(rawValue: rawValue) {
            onRoleChange(role)
        }
    }
}

// MARK: - CGWindowList snapshot (all windows, not onscreen-only)

/// Synchronous snapshot of ALL windows via CGWindowList — includes windows on
/// other Spaces and fullscreen presentations that optionOnScreenOnly would miss.
private func pptSnapshotWindows() -> [(id: CGWindowID, title: String, appName: String, pid: pid_t, frame: CGRect)] {
    // Note: no .optionOnScreenOnly — we want windows on all Spaces.
    guard let rawList = CGWindowListCopyWindowInfo(
        [.excludeDesktopElements],
        kCGNullWindowID
    ) else { return [] }

    let list = rawList as NSArray
    var result: [(id: CGWindowID, title: String, appName: String, pid: pid_t, frame: CGRect)] = []
    for item in list {
        guard let dict = item as? NSDictionary else { continue }
        guard let wid   = dict[kCGWindowNumber] as? Int,
              let title = dict[kCGWindowName]   as? String,
              !title.isEmpty else { continue }
        let appName = dict[kCGWindowOwnerName] as? String ?? ""
        let pid     = dict[kCGWindowOwnerPID]  as? Int32  ?? 0

        var frame = CGRect.zero
        if let bounds    = dict[kCGWindowBounds] as? NSDictionary,
           let boundsRef = bounds as? CFDictionary {
            CGRectMakeWithDictionaryRepresentation(boundsRef, &frame)
        }
        result.append((id: CGWindowID(wid), title: title, appName: appName,
                       pid: pid_t(pid), frame: frame))
    }
    return result
}
