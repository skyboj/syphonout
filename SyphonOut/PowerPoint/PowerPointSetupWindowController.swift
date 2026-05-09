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
        case notUsed          = 0
        case confidenceMonitor = 2

        var label: String {
            switch self {
            case .notUsed:          return "Not Used"
            case .confidenceMonitor: return "Confidence Monitor"
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
    private var helpLabel:    NSTextField!
    private var statusLabel:  NSTextField!
    private var applyButton:  NSButton!
    private var removeMirrorButton: NSButton!

    private var displayRefreshTimer: Timer?
    private var screenChangeObserver: NSObjectProtocol?

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
        updateWatcherStatus()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDisplays()
        }
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        helpLabel = NSTextField(wrappingLabelWithString: "SyphonOut automatically captures Presenter View from the MacBook and displays it on the monitor you mark as «Confidence Monitor». Activates when a slideshow is running in PowerPoint. The slideshow display is selected in PowerPoint itself (Slide Show → Set Up Show).")
        helpLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(helpLabel)

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
            helpLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            helpLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            helpLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 8),
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
                let unit = CGDisplayUnitNumber(id)
                nameByUnit[unit] = screen.localizedName
                // Also seed the shared cache (persisted to UserDefaults).
                OutputWindowController.displayNameByUnit[unit] = screen.localizedName
            }
        }
        let activeSet = Set(activeIDs)

        // Append online-but-not-active IDs (mirror slaves — new IDs, same hardware).
        let mirroredIDs = allOnlineDisplayIDs().filter { !activeSet.contains($0) }
        let allIDs = activeIDs + mirroredIDs

        // Always refresh card labels even if the ID list hasn't changed —
        // names may have come in late from IOKit / persistence.
        if allIDs != displayIDs {
            displayIDs = allIDs
            rebuildCards(allIDs: allIDs)
        } else {
            for card in roleCards {
                let liveName = OutputWindowController.screenName(for: card.displayID)
                let idx = displayIDs.firstIndex(of: card.displayID) ?? 0
                card.updateDisplayName(liveName, displayIndex: idx)
            }
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

        for (index, displayID) in allIDs.enumerated() {
            let unit     = CGDisplayUnitNumber(displayID)
            let isMirror = !activeSet.contains(displayID)

            // Use the shared name resolver: NSScreen → cache → IOKit → "Display N".
            // This survives mirror-set ID changes and process restarts.
            let name = OutputWindowController.screenName(for: displayID)
            nameByUnit[unit] = name

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
                displayIndex: index,
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
        guard let index = allIDs.firstIndex(of: displayID) else { return .notUsed }
        // Index 0 = built-in (Presenter View), Index 1 = slide show projector,
        // Index 2+ = available for confidence monitoring.
        return index >= 2 ? .confidenceMonitor : .notUsed
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
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }

    // MARK: - Apply

    @objc private func applySetup() {
        applyButton.isEnabled = false

        // 1. Remove system mirrors on all displays (SyphonOut uses soft-mirror)
        for displayID in displayIDs {
            if CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay {
                let name = OutputWindowController.screenName(for: displayID)
                AppLog.shared.info("PPT Setup: removing macOS mirror on \(name)", category: "PPTSetup")
                removeSystemMirror(for: displayID)
            }
        }

        // 2. Find confidence monitor display ID
        let confidenceID = displayIDs.first { rolesByUnit[CGDisplayUnitNumber($0)] == .confidenceMonitor }

        // 3. Save confidence display preference for PowerPointPreset to use.
        if let cid = confidenceID {
            let unit = CGDisplayUnitNumber(cid)
            UserDefaults.standard.set(Int(unit), forKey: "pptConfidenceDisplayUnit")
            let name = OutputWindowController.screenName(for: cid)
            AppLog.shared.info("PPT Setup: confidence display unit=\(unit) (\(name))", category: "PPTSetup")
            setStatus("✓ Confidence monitor: \(name)")
        } else {
            UserDefaults.standard.removeObject(forKey: "pptConfidenceDisplayUnit")
            AppLog.shared.info("PPT Setup: no confidence role", category: "PPTSetup")
            setStatus("✓ Roles saved (confidence monitor off)")
        }

        // 4. Activate/deactivate PowerPointPreset based on saved preference
        if UserDefaults.standard.bool(forKey: "pptPresetEnabled") {
            PowerPointPreset.shared.activate()
        } else {
            PowerPointPreset.shared.deactivate()
        }

        applyButton.isEnabled = true
        updateWatcherStatus()
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

    private func updateWatcherStatus() {
        if PowerPointPreset.shared.isActive {
            statusLabel.stringValue = "Watcher: ● ON"
        } else {
            statusLabel.stringValue = "Watcher: ○ OFF"
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
}

// MARK: - DisplayCard

final class DisplayCard: NSView {

    let displayID:   CGDirectDisplayID
    private(set) var displayName: String
    let isMirrored:  Bool
    private let onRoleChange: (PowerPointSetupWindowController.Role) -> Void

    private let snapshotView: NSImageView
    private let nameLabel:    NSTextField
    private let rolePicker:   NSPopUpButton

    init(
        displayID:    CGDirectDisplayID,
        displayIndex: Int,
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
        nameLabel = NSTextField(labelWithString: "\(displayName) (Index \(displayIndex))\(nameSuffix)")
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

    /// Update the visible display name + index. Called when a previously-unknown
    /// name becomes available (e.g. via IOKit lookup or NSScreen reattachment).
    func updateDisplayName(_ newName: String, displayIndex: Int) {
        guard newName != displayName else { return }
        displayName = newName
        let isMain = (NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        let nameSuffix = isMain ? " (Main)" : isMirrored ? " ⌀" : ""
        nameLabel.stringValue = "\(newName) (Index \(displayIndex))\(nameSuffix)"
    }

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
