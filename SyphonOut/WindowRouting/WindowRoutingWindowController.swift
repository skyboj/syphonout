import AppKit
import ScreenCaptureKit

/// Window Routing panel.
///
/// Layout:
///   • Toolbar    — title, timestamp, Refresh
///   • Table      — icon / Application / Window / Display  (shared)
///   • Tab view   — "Move" tab | "Capture" tab
///   • Count bar  — window count
final class WindowRoutingWindowController: NSWindowController, NSWindowDelegate {

    static let shared = WindowRoutingWindowController()

    // MARK: - Subviews

    private var scrollView:    NSScrollView!
    private var tableView:     NSTableView!
    private var statusLabel:   NSTextField!
    private var refreshButton: NSButton!
    private var tabView:       NSTabView!

    // Move tab
    private var screenPopup:        NSPopUpButton!
    private var moveButton:         NSButton!
    private var moveFillButton:     NSButton!
    private var moveFullscreenButton: NSButton!
    private var moveStatusLabel:    NSTextField!

    // Capture tab
    private var vdPopup:            NSPopUpButton!
    private var captureButton:      NSButton!
    private var moveCaptureButton:  NSButton!
    private var stopButton:         NSButton!
    private var captureStatusLabel: NSTextField!

    // MARK: - Data

    private let inventory = WindowInventory()
    private var windows:  [WindowInfo] = []
    private var captureObservers: [NSObjectProtocol] = []

    // MARK: - Init

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.title   = "Window Routing"
        window.minSize = NSSize(width: 520, height: 400)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireInventory()
        wireCapturNotifications()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    func showRouting() {
        PermissionManager.shared.requirePermissions(in: nil) { [weak self] granted in
            guard granted else { return }
            self?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ── Toolbar ───────────────────────────────────────────────────────────
        let toolbar = box()
        content.addSubview(toolbar)

        let titleLabel = label("On-Screen Windows", size: 13, bold: true)
        toolbar.addSubview(titleLabel)

        statusLabel = label("", size: 11, bold: false)
        statusLabel.textColor = .secondaryLabelColor
        toolbar.addSubview(statusLabel)

        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(manualRefresh))
        refreshButton.bezelStyle  = .rounded
        refreshButton.controlSize = .small
        toolbar.addSubview(refreshButton)

        // ── Table ─────────────────────────────────────────────────────────────
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20
        col("icon",    "",            20,  20,  20,  false)
        col("app",     "Application", 160, 100, 260, true)
        col("window",  "Window",      280, 120, 500, true)
        col("display", "Display",     120,  80, 200, true)
        tableView.dataSource = self
        tableView.delegate   = self

        scrollView = NSScrollView()
        scrollView.documentView       = tableView
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType         = .bezelBorder
        scrollView.autohidesScrollers = true
        content.addSubview(scrollView)

        // ── Tab view ──────────────────────────────────────────────────────────
        tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.controlSize = .regular
        content.addSubview(tabView)

        tabView.addTabViewItem(buildMoveTab())
        tabView.addTabViewItem(buildCaptureTab())

        // ── Count bar ─────────────────────────────────────────────────────────
        let countBar = box()
        content.addSubview(countBar)

        let countLabel = label("", size: 11, bold: false)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.tag = 42
        countBar.addSubview(countLabel)

        // ── Auto-layout ───────────────────────────────────────────────────────
        [toolbar, scrollView, tabView, countBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        [titleLabel, statusLabel, refreshButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tabView.topAnchor),

            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: countBar.topAnchor),
            tabView.heightAnchor.constraint(equalToConstant: 100),

            countBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            countBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            countBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            countBar.heightAnchor.constraint(equalToConstant: 24),
            countLabel.leadingAnchor.constraint(equalTo: countBar.leadingAnchor, constant: 12),
            countLabel.centerYAnchor.constraint(equalTo: countBar.centerYAnchor),
        ])

        rebuildScreenPopup()
        rebuildVDPopup()
    }

    // MARK: - Move tab

    private func buildMoveTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Move"

        // NSTabView sets the item view's frame directly — must NOT disable
        // autoresizingMask translation on this view or clicks won't reach subviews.
        let v = NSView()
        v.autoresizingMask = [.width, .height]
        item.view = v

        let toLabel = label("Move to:", size: 12, bold: false)

        screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        screenPopup.controlSize = .regular

        moveButton = NSButton(title: "Move", target: self, action: #selector(moveWindow))
        moveButton.bezelStyle = .rounded
        moveButton.isEnabled  = false

        moveFillButton = NSButton(title: "Move & Fill", target: self, action: #selector(moveAndFillWindow))
        moveFillButton.bezelStyle = .rounded
        moveFillButton.isEnabled  = false

        moveFullscreenButton = NSButton(title: "Move & Fullscreen",
                                        target: self, action: #selector(moveAndFullscreen))
        moveFullscreenButton.bezelStyle = .rounded
        moveFullscreenButton.isEnabled  = false

        moveStatusLabel = label("", size: 11, bold: false)
        moveStatusLabel.textColor = .secondaryLabelColor

        [toLabel, screenPopup, moveButton, moveFillButton,
         moveFullscreenButton, moveStatusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview($0)
        }

        NSLayoutConstraint.activate([
            toLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            toLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            screenPopup.leadingAnchor.constraint(equalTo: toLabel.trailingAnchor, constant: 8),
            screenPopup.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            screenPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            moveButton.leadingAnchor.constraint(equalTo: screenPopup.trailingAnchor, constant: 8),
            moveButton.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            moveFillButton.leadingAnchor.constraint(equalTo: moveButton.trailingAnchor, constant: 6),
            moveFillButton.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            moveFullscreenButton.leadingAnchor.constraint(equalTo: moveFillButton.trailingAnchor, constant: 6),
            moveFullscreenButton.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            moveStatusLabel.leadingAnchor.constraint(equalTo: moveFullscreenButton.trailingAnchor, constant: 10),
            moveStatusLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            moveStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
        ])

        return item
    }

    // MARK: - Capture tab

    private func buildCaptureTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Capture"

        // Same as Move tab — NSTabView manages this frame; autoresizingMask must be on.
        let v = NSView()
        v.autoresizingMask = [.width, .height]
        item.view = v

        let captureToLabel = label("Capture to:", size: 12, bold: false)

        vdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        vdPopup.controlSize = .regular

        captureButton = NSButton(title: "Capture", target: self, action: #selector(startCaptureOnly))
        captureButton.bezelStyle = .rounded
        captureButton.isEnabled  = false

        moveCaptureButton = NSButton(title: "Move & Capture", target: self, action: #selector(moveAndCapture))
        moveCaptureButton.bezelStyle = .rounded
        moveCaptureButton.isEnabled  = false

        stopButton = NSButton(title: "Stop", target: self, action: #selector(stopCapture))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled  = false

        captureStatusLabel = label("", size: 11, bold: false)
        captureStatusLabel.textColor = .secondaryLabelColor

        [captureToLabel, vdPopup, captureButton, moveCaptureButton,
         stopButton, captureStatusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview($0)
        }

        NSLayoutConstraint.activate([
            captureToLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            captureToLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            vdPopup.leadingAnchor.constraint(equalTo: captureToLabel.trailingAnchor, constant: 8),
            vdPopup.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            vdPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            captureButton.leadingAnchor.constraint(equalTo: vdPopup.trailingAnchor, constant: 10),
            captureButton.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            moveCaptureButton.leadingAnchor.constraint(equalTo: captureButton.trailingAnchor, constant: 6),
            moveCaptureButton.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            stopButton.leadingAnchor.constraint(equalTo: moveCaptureButton.trailingAnchor, constant: 6),
            stopButton.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            captureStatusLabel.leadingAnchor.constraint(equalTo: stopButton.trailingAnchor, constant: 10),
            captureStatusLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            captureStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
        ])

        return item
    }

    // MARK: - Inventory

    private func wireInventory() {
        inventory.onUpdate = { [weak self] updated in
            guard let self else { return }

            // Remember selected window by ID so a reorder/add/remove
            // doesn't drop the user's selection.
            let selectedID = self.selectedWindowInfo?.id

            self.windows = updated
            self.tableView.reloadData()

            // Restore selection to the same window (new index after sort).
            if let id = selectedID,
               let newRow = updated.firstIndex(where: { $0.id == id }) {
                self.tableView.selectRowIndexes(IndexSet(integer: newRow),
                                                byExtendingSelection: false)
                // Don't scroll — the user is looking at this row already.
            }

            self.updateCountLabel()
            self.statusLabel.stringValue = "Updated \(shortTime())"
            self.updateActionBars()
        }
    }

    private func wireCapturNotifications() {
        let obs1 = NotificationCenter.default.addObserver(
            forName: .windowCaptureStarted, object: nil, queue: .main
        ) { [weak self] _ in self?.updateActionBars() }

        let obs2 = NotificationCenter.default.addObserver(
            forName: .windowCaptureStopped, object: nil, queue: .main
        ) { [weak self] notif in
            if let error = notif.userInfo?["error"] as? Error {
                self?.captureStatusLabel.stringValue = "✗ \(error.localizedDescription)"
                self?.captureStatusLabel.textColor = .systemRed
            }
            self?.updateActionBars()
        }

        // Rebuild VD popup whenever virtual displays are created or destroyed
        let obs3 = NotificationCenter.default.addObserver(
            forName: .vdListChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildVDPopup() }

        captureObservers = [obs1, obs2, obs3]
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        inventory.start()
        rebuildScreenPopup()
        rebuildVDPopup()
    }

    func windowWillClose(_ notification: Notification) {
        inventory.stop()
    }

    // MARK: - Popups

    private func rebuildScreenPopup() {
        screenPopup.removeAllItems()
        NSScreen.screens.forEach { screenPopup.addItem(withTitle: $0.localizedName) }
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func rebuildVDPopup() {
        vdPopup.removeAllItems()
        let vds = VirtualDisplayManager.shared.displays
        if vds.isEmpty {
            vdPopup.addItem(withTitle: "No Virtual Displays")
            vdPopup.isEnabled = false
        } else {
            vds.forEach { vdPopup.addItem(withTitle: $0.name) }
            vdPopup.isEnabled = true
        }
    }

    @objc private func screensChanged() { rebuildScreenPopup() }

    private var selectedScreen: NSScreen? {
        let screens = NSScreen.screens
        let i = screenPopup.indexOfSelectedItem
        return (i >= 0 && i < screens.count) ? screens[i] : screens.first
    }

    private var selectedVD: VirtualDisplay? {
        let vds = VirtualDisplayManager.shared.displays
        let i = vdPopup.indexOfSelectedItem
        return (i >= 0 && i < vds.count) ? vds[i] : vds.first
    }

    // MARK: - Move actions

    @objc private func manualRefresh() {
        statusLabel.stringValue = "Refreshing…"
        inventory.forceRefresh()
        rebuildVDPopup()
    }

    @objc private func moveWindow()        { performMove(resize: false, fullscreen: false) }
    @objc private func moveAndFillWindow() { performMove(resize: true,  fullscreen: false) }
    @objc private func moveAndFullscreen() { performMove(resize: false, fullscreen: true) }

    private func performMove(resize: Bool, fullscreen: Bool = false) {
        guard let info = selectedWindowInfo, let screen = selectedScreen else { return }
        switch WindowMover.move(info, to: screen, resize: resize, fullscreen: fullscreen) {
        case .success:
            let verb = fullscreen ? "sent fullscreen to" : (resize ? "filled on" : "moved to")
            moveStatusLabel.stringValue = "✓ \(info.appName) \(verb) \(screen.localizedName)"
            moveStatusLabel.textColor = .labelColor
            // Force-refresh immediately so windows[] is updated with the new frame.
            // This lets the user move the same window again without re-selecting it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.inventory.forceRefresh()
            }
        case .noAccessibility:
            moveStatusLabel.stringValue = "✗ Accessibility permission required — open Preferences → Permissions"
            moveStatusLabel.textColor = .systemRed
        case .windowNotFound:
            moveStatusLabel.stringValue = "✗ Window not found — try Refresh"
            moveStatusLabel.textColor = .systemOrange
        case .axError(let e):
            moveStatusLabel.stringValue = "✗ AX error \(e.rawValue)"
            moveStatusLabel.textColor = .systemRed
        }
    }

    // MARK: - Capture actions

    @objc private func startCaptureOnly() {
        guard let info = selectedWindowInfo, let vd = selectedVD else { return }
        beginCapture(info: info, vdUUID: vd.id)
    }

    @objc private func moveAndCapture() {
        guard let info = selectedWindowInfo,
              let screen = selectedScreen,
              let vd = selectedVD else { return }
        // Move first, then capture. Capture uses windowID so stale frame is fine.
        _ = WindowMover.move(info, to: screen, resize: false)
        beginCapture(info: info, vdUUID: vd.id)
        // Refresh list so the Display column updates to the new screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.inventory.forceRefresh()
        }
    }

    private func beginCapture(info: WindowInfo, vdUUID: String) {
        let vdName = VirtualDisplayManager.shared.displays.first { $0.id == vdUUID }?.name ?? "?"
        AppLog.shared.info("WindowRouting: capture '\(info.appName)' (wid=\(info.id)) → vd='\(vdName)' (\(vdUUID.prefix(8))…)", category: "Routing")

        // Make sure the target VD is in Signal mode — if it's Blank/Off the user
        // would see nothing even though frames are flowing into the VD.
        let vdm = VirtualDisplayManager.shared
        if let vd = vdm.displays.first(where: { $0.id == vdUUID }),
           vd.mode != SYPHON_OUT_MODE_SIGNAL {
            AppLog.shared.info("WindowRouting: VD '\(vdName)' was \(vd.modeDescription) → switching to Signal", category: "Routing")
            vdm.setMode(vdId: vdUUID, mode: SYPHON_OUT_MODE_SIGNAL)
        }

        captureStatusLabel.stringValue = "Starting…"
        captureStatusLabel.textColor = .secondaryLabelColor
        updateActionBars()

        WindowCaptureManager.shared.startCapture(windowID: info.id, vdUUID: vdUUID) { [weak self] error in
            guard let self else { return }
            if let error {
                self.captureStatusLabel.stringValue = "✗ \(error.localizedDescription)"
                self.captureStatusLabel.textColor = .systemRed
            } else {
                let vdName = VirtualDisplayManager.shared.displays.first { $0.id == vdUUID }?.name ?? vdUUID
                self.captureStatusLabel.stringValue = "● \(info.appName) → \(vdName)"
                self.captureStatusLabel.textColor = .labelColor
            }
            self.updateActionBars()
        }
    }

    @objc private func stopCapture() {
        guard let info = selectedWindowInfo else { return }
        WindowCaptureManager.shared.stopCapture(windowID: info.id)
        captureStatusLabel.stringValue = "Stopped"
        captureStatusLabel.textColor = .secondaryLabelColor
        updateActionBars()
    }

    // MARK: - State

    private var selectedWindowInfo: WindowInfo? {
        let row = tableView.selectedRow
        guard row >= 0, row < windows.count else { return nil }
        return windows[row]
    }

    private func updateActionBars() {
        let sel  = tableView.selectedRow >= 0
        let info = selectedWindowInfo
        let capturing = info.map { WindowCaptureManager.shared.isCapturing($0.id) } ?? false
        let hasVDs = !VirtualDisplayManager.shared.displays.isEmpty

        moveButton.isEnabled           = sel
        moveFillButton.isEnabled       = sel
        moveFullscreenButton.isEnabled = sel
        captureButton.isEnabled     = sel && hasVDs && !capturing
        moveCaptureButton.isEnabled = sel && hasVDs && !capturing
        stopButton.isEnabled        = sel && capturing
    }

    // MARK: - Helpers

    private func col(_ id: String, _ title: String,
                     _ width: CGFloat, _ min: CGFloat, _ max: CGFloat,
                     _ resizable: Bool) {
        let c = NSTableColumn(identifier: .init(id))
        c.title = title; c.width = width; c.minWidth = min; c.maxWidth = max
        c.resizingMask = resizable ? [.autoresizingMask, .userResizingMask] : []
        tableView.addTableColumn(c)
    }

    private func label(_ text: String, size: CGFloat, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return l
    }

    private func box() -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false; return v
    }

    private func updateCountLabel() {
        if let l = window?.contentView?.viewWithTag(42) as? NSTextField {
            let n = windows.count
            l.stringValue = n == 0 ? "No windows" : "\(n) window\(n == 1 ? "" : "s")"
        }
    }

    private func shortTime() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    private func displayName(for frame: CGRect) -> String {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens {
            let r = CGRect(x: screen.frame.minX,
                           y: primary - screen.frame.minY - screen.frame.height,
                           width: screen.frame.width, height: screen.frame.height)
            if r.contains(mid) { return screen.localizedName }
        }
        return "Unknown"
    }
}

// MARK: - NSTableViewDataSource

extension WindowRoutingWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }
}

// MARK: - NSTableViewDelegate

extension WindowRoutingWindowController: NSTableViewDelegate {

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionBars()
        moveStatusLabel.stringValue = ""
        moveStatusLabel.textColor = .secondaryLabelColor
        captureStatusLabel.stringValue = ""
        captureStatusLabel.textColor = .secondaryLabelColor

        if let info = selectedWindowInfo,
           WindowCaptureManager.shared.isCapturing(info.id),
           let vdUUID = WindowCaptureManager.shared.vdUUID(for: info.id) {
            let vdName = VirtualDisplayManager.shared.displays.first { $0.id == vdUUID }?.name ?? vdUUID
            captureStatusLabel.stringValue = "● \(info.appName) → \(vdName)"
            captureStatusLabel.textColor = .labelColor
        }
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < windows.count else { return nil }
        let info  = windows[row]
        let colID = tableColumn?.identifier.rawValue ?? ""
        let capturing = WindowCaptureManager.shared.isCapturing(info.id)

        switch colID {
        case "icon":
            let v = (tableView.makeView(withIdentifier: .init("icon"), owner: nil)
                     as? NSImageView) ?? NSImageView()
            v.identifier = .init("icon")
            v.image = info.appIcon
            v.imageScaling = .scaleProportionallyUpOrDown
            return v
        case "app":
            return textCell(tableView, id: "app", value: info.appName,
                            color: capturing ? .systemGreen : .labelColor)
        case "window":
            return textCell(tableView, id: "window", value: info.displayTitle,
                            color: info.title.isEmpty ? .tertiaryLabelColor : .labelColor)
        case "display":
            return textCell(tableView, id: "display", value: displayName(for: info.frame),
                            color: .secondaryLabelColor)
        default: return nil
        }
    }

    private func textCell(_ tv: NSTableView, id: String,
                          value: String, color: NSColor) -> NSTextField {
        let c: NSTextField
        if let e = tv.makeView(withIdentifier: .init(id), owner: nil) as? NSTextField {
            c = e
        } else {
            c = NSTextField(labelWithString: "")
            c.identifier = .init(id)
            c.font = .systemFont(ofSize: 12)
            c.lineBreakMode = .byTruncatingTail
        }
        c.stringValue = value; c.textColor = color
        return c
    }
}
