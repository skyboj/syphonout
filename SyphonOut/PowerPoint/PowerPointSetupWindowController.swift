import AppKit

/// PowerPoint Presentation Setup panel.
///
/// Shows a live snapshot of every connected physical display so the user
/// can visually identify them, assign roles (Slide Show / Speaker Notes /
/// Not Used), and hit Apply.
///
/// Apply does two things:
///  1. Finds the PowerPoint "Slide Show" window and moves it to the selected
///     display using WindowMover (Accessibility API).  If PowerPoint is not
///     yet running the panel watches for the window in the background and
///     moves it automatically when it appears.
///  2. Sets the "Speaker Notes" display to mirror the MacBook built-in
///     screen at the OS level via CGConfigureDisplayMirrorOfDisplay.
///
/// Remove Mirror undoes the OS mirroring.

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

    /// Parallel to NSScreen.screens at the time of last refresh.
    private var displayIDs:   [CGDirectDisplayID] = []
    private var roleCards:    [DisplayCard]        = []
    private var roles:        [CGDirectDisplayID: Role] = [:]

    private var stackView:    NSStackView!
    private var statusLabel:  NSTextField!
    private var applyButton:  NSButton!
    private var removeMirrorButton: NSButton!

    private var displayRefreshTimer: Timer?

    /// WindowInventory used to watch for PPT Slide Show after Apply is clicked.
    private var slideShowWatcher: WindowInventory?
    /// The NSScreen we want to move the Slide Show window to.
    private var watchTargetScreen: NSScreen?

    // MARK: - Init

    private init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 320),
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
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Scroll + stack for display cards
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

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        // Buttons
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

    private func refreshDisplays() {
        let screens = NSScreen.screens
        let ids = screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }

        // If set of displays changed, rebuild cards
        if ids != displayIDs {
            displayIDs = ids
            rebuildCards(screens: screens, ids: ids)
        }

        // Refresh snapshots on all cards
        for card in roleCards {
            card.refreshSnapshot()
        }
    }

    private func rebuildCards(screens: [NSScreen], ids: [CGDirectDisplayID]) {
        // Remove old cards
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        roleCards.removeAll()

        for (screen, displayID) in zip(screens, ids) {
            // Preserve role if display was already known
            let role = roles[displayID] ?? defaultRole(for: displayID, in: ids)
            roles[displayID] = role

            let card = DisplayCard(
                displayID: displayID,
                displayName: screen.localizedName,
                initialRole: role
            ) { [weak self] newRole in
                self?.roles[displayID] = newRole
            }
            roleCards.append(card)
            stackView.addArrangedSubview(card)
        }
    }

    private func defaultRole(for displayID: CGDirectDisplayID, in allIDs: [CGDirectDisplayID]) -> Role {
        // Built-in = speaker notes mirror by default
        if CGDisplayIsBuiltin(displayID) != 0 { return .speakerMirror }
        // First external = slide show by default
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

        let slideShowID     = roles.first { $0.value == .slideShow }?.key
        let speakerMirrorID = roles.first { $0.value == .speakerMirror }?.key
        let builtinID       = displayIDs.first { CGDisplayIsBuiltin($0) != 0 }

        var messages: [String] = []

        // ── 1. System-level mirror for the speaker notes display ──────────
        if let mirrorID = speakerMirrorID, mirrorID != builtinID {
            let masterID = builtinID ?? (displayIDs.first { $0 != mirrorID } ?? mirrorID)
            applySystemMirror(mirrorDisplay: mirrorID, masterDisplay: masterID)
            let mirrorName = roleCards.first { $0.displayID == mirrorID }?.displayName ?? "\(mirrorID)"
            let masterName = roleCards.first { $0.displayID == masterID }?.displayName ?? "\(masterID)"
            AppLog.shared.info("PPT Setup: system mirror \(mirrorName) → \(masterName)", category: "PPTSetup")
            messages.append("Mirror: \(mirrorName) ← \(masterName)")
        } else if let mirrorID = speakerMirrorID, mirrorID == builtinID {
            // Built-in selected as speaker notes — nothing to mirror.
            messages.append("Speaker: MacBook (no mirror needed)")
        }

        // ── 2. Move PowerPoint Slide Show window ──────────────────────────
        guard let targetID = slideShowID,
              let targetScreen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetID
              }) else {
            // No Slide Show role assigned — just apply mirror and done.
            if messages.isEmpty { messages.append("Roles saved") }
            setStatus("✓ " + messages.joined(separator: "  |  "))
            return
        }

        if let window = findSlideShowWindow() {
            // PPT is already running — move the window immediately.
            AppLog.shared.info("PPT Setup: Slide Show found, moving to \(targetScreen.localizedName)", category: "PPTSetup")
            WindowMover.move(window, to: targetScreen, resize: true, fullscreen: false)
            messages.append("Slide Show → \(targetScreen.localizedName)")
            setStatus("✓ " + messages.joined(separator: "  |  "))
        } else {
            // PPT not running yet — save the target and watch for the window.
            AppLog.shared.info("PPT Setup: Slide Show not found, watching for it (target: \(targetScreen.localizedName))", category: "PPTSetup")
            watchTargetScreen = targetScreen
            let mirrorMsg = messages.isEmpty ? "" : messages.joined(separator: "  |  ") + "  |  "
            setStatus(mirrorMsg + "⏳ Waiting for Slide Show window…")
            startSlideShowWatcher(targetScreen: targetScreen)
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

    private func startSlideShowWatcher(targetScreen: NSScreen) {
        let watcher = WindowInventory()
        watcher.onUpdate = { [weak self] windows in
            guard let self else { return }
            guard let slideShowWindow = windows.first(where: {
                $0.appName.localizedCaseInsensitiveContains("PowerPoint") &&
                $0.title.localizedCaseInsensitiveContains("Slide Show")
            }) else { return }

            // Found the Slide Show window!
            AppLog.shared.info("PPT Setup: Slide Show window appeared, moving to \(targetScreen.localizedName)", category: "PPTSetup")
            WindowMover.move(slideShowWindow, to: targetScreen, resize: true, fullscreen: false)
            self.setStatus("✓ Slide Show → \(targetScreen.localizedName)")
            self.stopSlideShowWatcher()
        }
        watcher.start()
        slideShowWatcher = watcher
    }

    private func stopSlideShowWatcher() {
        slideShowWatcher?.stop()
        slideShowWatcher = nil
        watchTargetScreen = nil
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
            AppLog.shared.error("PPT Setup: CGCompleteDisplayConfiguration failed err=\(err.rawValue)", category: "PPTSetup")
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

    /// Returns a WindowInfo for the PowerPoint Slide Show window, or nil.
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

/// One card in the panel representing a single physical display.
final class DisplayCard: NSView {

    let displayID:   CGDirectDisplayID
    let displayName: String
    private let onRoleChange: (PowerPointSetupWindowController.Role) -> Void

    private let snapshotView: NSImageView
    private let nameLabel:    NSTextField
    private let rolePicker:   NSPopUpButton

    init(
        displayID:   CGDirectDisplayID,
        displayName: String,
        initialRole: PowerPointSetupWindowController.Role,
        onRoleChange: @escaping (PowerPointSetupWindowController.Role) -> Void
    ) {
        self.displayID    = displayID
        self.displayName  = displayName
        self.onRoleChange = onRoleChange

        snapshotView = NSImageView()
        snapshotView.imageScaling  = .scaleProportionallyUpOrDown
        snapshotView.imageAlignment = .alignCenter
        snapshotView.wantsLayer    = true
        snapshotView.layer?.cornerRadius = 4
        snapshotView.layer?.backgroundColor = NSColor.black.cgColor
        snapshotView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel = NSTextField(labelWithString: displayName)
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

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(snapshotView)
        addSubview(nameLabel)
        addSubview(rolePicker)

        // Built-in display: highlight border to hint it's the MacBook screen
        if CGDisplayIsBuiltin(displayID) != 0 {
            wantsLayer = true
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 1.5
            layer?.cornerRadius = 6
        }

        rolePicker.target = self
        rolePicker.action = #selector(pickerChanged)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 200),

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

        refreshSnapshot()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshSnapshot() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let cgImage = CGDisplayCreateImage(self.displayID) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            DispatchQueue.main.async {
                self.snapshotView.image = nsImage
            }
        }
    }

    @objc private func pickerChanged() {
        let rawValue = rolePicker.selectedTag()
        if let role = PowerPointSetupWindowController.Role(rawValue: rawValue) {
            onRoleChange(role)
        }
    }
}

// MARK: - CGWindowList snapshot

/// Synchronous snapshot of on-screen windows via CGWindowList.
/// Returns window ID, title, app name, PID, and Quartz-coordinate frame.
private func pptSnapshotWindows() -> [(id: CGWindowID, title: String, appName: String, pid: pid_t, frame: CGRect)] {
    guard let rawList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) else { return [] }

    let list = rawList as NSArray
    var result: [(id: CGWindowID, title: String, appName: String, pid: pid_t, frame: CGRect)] = []
    for item in list {
        guard let dict = item as? NSDictionary else { continue }
        guard let wid   = dict[kCGWindowNumber]   as? Int,
              let title = dict[kCGWindowName]      as? String else { continue }
        let appName = dict[kCGWindowOwnerName] as? String ?? ""
        let pid     = dict[kCGWindowOwnerPID]  as? Int32  ?? 0

        var frame = CGRect.zero
        if let bounds = dict[kCGWindowBounds] as? NSDictionary,
           let boundsRef = bounds as? CFDictionary {
            CGRectMakeWithDictionaryRepresentation(boundsRef, &frame)
        }

        result.append((id: CGWindowID(wid), title: title, appName: appName,
                       pid: pid_t(pid), frame: frame))
    }
    return result
}
