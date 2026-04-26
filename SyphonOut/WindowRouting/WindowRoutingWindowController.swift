import AppKit
import ScreenCaptureKit

/// Window Routing panel — live window inventory, move controls, and window capture.
///
/// Layout (top → bottom):
///   • Toolbar:     title, last-updated timestamp, Refresh button
///   • Table:       icon / Application / Window / Display
///   • Move bar:    "Move to:" screen popup, Move, Move & Fill
///   • Capture bar: "Capture to:" VD popup, Capture, Move & Capture, Stop
///   • Count bar:   window count
final class WindowRoutingWindowController: NSWindowController, NSWindowDelegate {

    static let shared = WindowRoutingWindowController()

    // MARK: - Subviews

    private var scrollView:   NSScrollView!
    private var tableView:    NSTableView!
    private var statusLabel:  NSTextField!
    private var refreshButton: NSButton!

    // Move bar
    private var screenPopup:    NSPopUpButton!
    private var moveButton:     NSButton!
    private var moveFillButton: NSButton!

    // Capture bar
    private var vdPopup:           NSPopUpButton!
    private var captureButton:     NSButton!
    private var moveCaptureButton: NSButton!
    private var stopButton:        NSButton!
    private var captureStatusLabel: NSTextField!

    // MARK: - Data

    private let inventory = WindowInventory()
    private var windows:   [WindowInfo] = []

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
        let toolbar = makeContainer()
        content.addSubview(toolbar)

        let titleLabel = makeLabel("On-Screen Windows", size: 13, bold: true)
        toolbar.addSubview(titleLabel)

        statusLabel = makeLabel("", size: 11, bold: false)
        statusLabel.textColor = .secondaryLabelColor
        toolbar.addSubview(statusLabel)

        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(manualRefresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        toolbar.addSubview(refreshButton)

        // ── Table ─────────────────────────────────────────────────────────────
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20
        addColumn("icon",    "",            20,  20,  20,  false)
        addColumn("app",     "Application", 160, 100, 260, true)
        addColumn("window",  "Window",      280, 120, 500, true)
        addColumn("display", "Display",     120, 80,  200, true)
        tableView.dataSource = self
        tableView.delegate   = self

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType            = .bezelBorder
        scrollView.autohidesScrollers    = true
        content.addSubview(scrollView)

        // ── Move bar ──────────────────────────────────────────────────────────
        let moveBar = makeContainer()
        content.addSubview(moveBar)

        let toLabel = makeLabel("Move to:", size: 12, bold: false)
        moveBar.addSubview(toLabel)

        screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        screenPopup.controlSize = .regular
        moveBar.addSubview(screenPopup)

        moveButton = NSButton(title: "Move", target: self, action: #selector(moveWindow))
        moveButton.bezelStyle = .rounded
        moveButton.isEnabled = false
        moveBar.addSubview(moveButton)

        moveFillButton = NSButton(title: "Move & Fill", target: self, action: #selector(moveAndFillWindow))
        moveFillButton.bezelStyle = .rounded
        moveFillButton.isEnabled = false
        moveBar.addSubview(moveFillButton)

        // Separator line
        let sep = NSBox()
        sep.boxType = .separator
        content.addSubview(sep)

        // ── Capture bar ───────────────────────────────────────────────────────
        let captureBar = makeContainer()
        content.addSubview(captureBar)

        let captureToLabel = makeLabel("Capture to:", size: 12, bold: false)
        captureBar.addSubview(captureToLabel)

        vdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        vdPopup.controlSize = .regular
        captureBar.addSubview(vdPopup)

        captureButton = NSButton(title: "Capture", target: self, action: #selector(startCaptureOnly))
        captureButton.bezelStyle = .rounded
        captureButton.isEnabled = false
        captureBar.addSubview(captureButton)

        moveCaptureButton = NSButton(title: "Move & Capture", target: self, action: #selector(moveAndCapture))
        moveCaptureButton.bezelStyle = .rounded
        moveCaptureButton.isEnabled = false
        captureBar.addSubview(moveCaptureButton)

        stopButton = NSButton(title: "Stop", target: self, action: #selector(stopCapture))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false
        captureBar.addSubview(stopButton)

        captureStatusLabel = makeLabel("", size: 11, bold: false)
        captureStatusLabel.textColor = .secondaryLabelColor
        captureBar.addSubview(captureStatusLabel)

        // ── Count bar ─────────────────────────────────────────────────────────
        let countBar = makeContainer()
        content.addSubview(countBar)

        let countLabel = makeLabel("", size: 11, bold: false)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.tag = 42
        countBar.addSubview(countLabel)

        // ── Auto-layout ───────────────────────────────────────────────────────
        let views: [String: NSView] = [
            "toolbar": toolbar, "scroll": scrollView,
            "moveBar": moveBar, "sep": sep,
            "captureBar": captureBar, "countBar": countBar,
        ]
        views.values.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        [titleLabel, statusLabel, refreshButton,
         toLabel, screenPopup, moveButton, moveFillButton,
         captureToLabel, vdPopup, captureButton, moveCaptureButton,
         stopButton, captureStatusLabel, countLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // Toolbar
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

            // Table
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: moveBar.topAnchor),

            // Move bar
            moveBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            moveBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            moveBar.bottomAnchor.constraint(equalTo: sep.topAnchor),
            moveBar.heightAnchor.constraint(equalToConstant: 44),
            toLabel.leadingAnchor.constraint(equalTo: moveBar.leadingAnchor, constant: 12),
            toLabel.centerYAnchor.constraint(equalTo: moveBar.centerYAnchor),
            screenPopup.leadingAnchor.constraint(equalTo: toLabel.trailingAnchor, constant: 8),
            screenPopup.centerYAnchor.constraint(equalTo: moveBar.centerYAnchor),
            screenPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            moveButton.leadingAnchor.constraint(equalTo: screenPopup.trailingAnchor, constant: 10),
            moveButton.centerYAnchor.constraint(equalTo: moveBar.centerYAnchor),
            moveFillButton.leadingAnchor.constraint(equalTo: moveButton.trailingAnchor, constant: 6),
            moveFillButton.centerYAnchor.constraint(equalTo: moveBar.centerYAnchor),

            // Separator
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: captureBar.topAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            // Capture bar
            captureBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            captureBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            captureBar.bottomAnchor.constraint(equalTo: countBar.topAnchor),
            captureBar.heightAnchor.constraint(equalToConstant: 44),
            captureToLabel.leadingAnchor.constraint(equalTo: captureBar.leadingAnchor, constant: 12),
            captureToLabel.centerYAnchor.constraint(equalTo: captureBar.centerYAnchor),
            vdPopup.leadingAnchor.constraint(equalTo: captureToLabel.trailingAnchor, constant: 8),
            vdPopup.centerYAnchor.constraint(equalTo: captureBar.centerYAnchor),
            vdPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            captureButton.leadingAnchor.constraint(equalTo: vdPopup.trailingAnchor, constant: 10),
            captureButton.centerYAnchor.constraint(equalTo: captureBar.centerYAnchor),
            moveCaptureButton.leadingAnchor.constraint(equalTo: captureButton.trailingAnchor, constant: 6),
            moveCaptureButton.centerYAnchor.constraint(equalTo: captureBar.centerYAnchor),
            stopButton.leadingAnchor.constraint(equalTo: moveCaptureButton.trailingAnchor, constant: 6),
            stopButton.centerYAnchor.constraint(equalTo: captureBar.centerYAnchor),
            captureStatusLabel.leadingAnchor.constraint(equalTo: stopButton.trailingAnchor, constant: 10),
            captureStatusLabel.centerYAnchor.constraint(equalTo: captureBar.centerYAnchor),
            captureStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: captureBar.trailingAnchor, constant: -12),

            // Count bar
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

    // MARK: - Inventory

    private func wireInventory() {
        inventory.onUpdate = { [weak self] updated in
            guard let self else { return }
            self.windows = updated
            self.tableView.reloadData()
            self.updateCountLabel()
            self.statusLabel.stringValue = "Updated \(shortTime())"
            self.updateActionBar()
        }
    }

    // MARK: - Capture notifications

    private func wireCapturNotifications() {
        let started = NotificationCenter.default.addObserver(
            forName: .windowCaptureStarted, object: nil, queue: .main
        ) { [weak self] _ in self?.updateActionBar() }

        let stopped = NotificationCenter.default.addObserver(
            forName: .windowCaptureStopped, object: nil, queue: .main
        ) { [weak self] notif in
            // Show error if the stream died unexpectedly
            if let error = notif.userInfo?["error"] as? Error {
                self?.captureStatusLabel.stringValue = "✗ \(error.localizedDescription)"
                self?.captureStatusLabel.textColor = .systemRed
            }
            self?.updateActionBar()
        }

        captureObservers = [started, stopped]
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
        let idx = screenPopup.indexOfSelectedItem
        let screens = NSScreen.screens
        guard idx >= 0, idx < screens.count else { return screens.first }
        return screens[idx]
    }

    private var selectedVD: VirtualDisplay? {
        let idx = VirtualDisplayManager.shared.displays.indices
        let vds = VirtualDisplayManager.shared.displays
        let i = vdPopup.indexOfSelectedItem
        guard i >= 0, i < vds.count else { return vds.first }
        return vds[i]
        _ = idx  // silence unused warning
    }

    // MARK: - Actions

    @objc private func manualRefresh() {
        statusLabel.stringValue = "Refreshing…"
        inventory.stop()
        inventory.start()
        rebuildVDPopup()
    }

    @objc private func moveWindow()        { performMove(resize: false) }
    @objc private func moveAndFillWindow() { performMove(resize: true)  }

    private func performMove(resize: Bool) {
        guard let info = selectedWindowInfo, let screen = selectedScreen else { return }
        applyMove(info: info, screen: screen, resize: resize)
    }

    @discardableResult
    private func applyMove(info: WindowInfo, screen: NSScreen, resize: Bool) -> Bool {
        switch WindowMover.move(info, to: screen, resize: resize) {
        case .success:
            // Re-scan after a short delay so the table reflects new position
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.inventory.stop(); self?.inventory.start()
            }
            return true
        case .noAccessibility:
            showMoveError("Accessibility permission required")
        case .windowNotFound:
            showMoveError("Window no longer on screen")
        case .axError(let e):
            showMoveError("AX error \(e.rawValue)")
        }
        return false
    }

    @objc private func startCaptureOnly() {
        guard let info = selectedWindowInfo, let vd = selectedVD else { return }
        beginCapture(info: info, vdUUID: vd.id)
    }

    @objc private func moveAndCapture() {
        guard let info = selectedWindowInfo,
              let screen = selectedScreen,
              let vd = selectedVD else { return }
        // Move first (synchronous AX call), then start capture
        let moved = applyMove(info: info, screen: screen, resize: false)
        if moved || true {   // attempt capture even if move had issues
            beginCapture(info: info, vdUUID: vd.id)
        }
    }

    private func beginCapture(info: WindowInfo, vdUUID: String) {
        captureStatusLabel.stringValue = "Starting capture…"
        captureStatusLabel.textColor = .secondaryLabelColor
        updateActionBar()

        WindowCaptureManager.shared.startCapture(
            windowID: info.id, vdUUID: vdUUID
        ) { [weak self] error in
            guard let self else { return }
            if let error {
                self.captureStatusLabel.stringValue = "✗ \(error.localizedDescription)"
                self.captureStatusLabel.textColor = .systemRed
            } else {
                let vdName = VirtualDisplayManager.shared.displays
                    .first { $0.id == vdUUID }?.name ?? vdUUID
                self.captureStatusLabel.stringValue =
                    "● Capturing \(info.appName) → \(vdName)"
                self.captureStatusLabel.textColor = .labelColor
            }
            self.updateActionBar()
        }
    }

    @objc private func stopCapture() {
        guard let info = selectedWindowInfo else { return }
        WindowCaptureManager.shared.stopCapture(windowID: info.id)
        captureStatusLabel.stringValue = "Stopped"
        captureStatusLabel.textColor = .secondaryLabelColor
        updateActionBar()
    }

    // MARK: - State helpers

    private var selectedWindowInfo: WindowInfo? {
        let row = tableView.selectedRow
        guard row >= 0, row < windows.count else { return nil }
        return windows[row]
    }

    private func updateActionBar() {
        let hasSelection = tableView.selectedRow >= 0
        let info = selectedWindowInfo
        let capturing = info.map { WindowCaptureManager.shared.isCapturing($0.id) } ?? false
        let hasVDs = !VirtualDisplayManager.shared.displays.isEmpty

        moveButton.isEnabled     = hasSelection
        moveFillButton.isEnabled = hasSelection
        captureButton.isEnabled     = hasSelection && hasVDs && !capturing
        moveCaptureButton.isEnabled = hasSelection && hasVDs && !capturing
        stopButton.isEnabled        = hasSelection && capturing
    }

    private func showMoveError(_ msg: String) {
        // Briefly show in the status label; the capture bar has its own label
        statusLabel.stringValue = "✗ \(msg)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.statusLabel.stringValue = ""
        }
    }

    // MARK: - Table helpers

    private func addColumn(_ id: String, _ title: String,
                           _ width: CGFloat, _ min: CGFloat, _ max: CGFloat,
                           _ resizable: Bool) {
        let col = NSTableColumn(identifier: .init(id))
        col.title    = title
        col.width    = width
        col.minWidth = min
        col.maxWidth = max
        col.resizingMask = resizable ? [.autoresizingMask, .userResizingMask] : []
        tableView.addTableColumn(col)
    }

    private func makeLabel(_ text: String, size: CGFloat, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return label
    }

    private func makeContainer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func updateCountLabel() {
        if let label = window?.contentView?.viewWithTag(42) as? NSTextField {
            let n = windows.count
            label.stringValue = n == 0 ? "No windows" : "\(n) window\(n == 1 ? "" : "s")"
        }
    }

    private func shortTime() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    /// Converts an SCWindow frame (Quartz coords) to the containing NSScreen's name.
    private func displayName(for frame: CGRect) -> String {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens {
            let qRect = CGRect(x: screen.frame.minX,
                               y: primary - screen.frame.minY - screen.frame.height,
                               width: screen.frame.width, height: screen.frame.height)
            if qRect.contains(mid) { return screen.localizedName }
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
        updateActionBar()
        captureStatusLabel.stringValue = ""
        captureStatusLabel.textColor = .secondaryLabelColor
        // If the newly selected window is already being captured, show its status
        if let info = selectedWindowInfo,
           WindowCaptureManager.shared.isCapturing(info.id),
           let vdUUID = WindowCaptureManager.shared.vdUUID(for: info.id) {
            let vdName = VirtualDisplayManager.shared.displays
                .first { $0.id == vdUUID }?.name ?? vdUUID
            captureStatusLabel.stringValue = "● Capturing \(info.appName) → \(vdName)"
            captureStatusLabel.textColor = .labelColor
        }
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < windows.count else { return nil }
        let info  = windows[row]
        let colID = tableColumn?.identifier.rawValue ?? ""
        let isCapturing = WindowCaptureManager.shared.isCapturing(info.id)

        switch colID {
        case "icon":
            let v = (tableView.makeView(withIdentifier: .init("icon"), owner: nil)
                     as? NSImageView) ?? NSImageView()
            v.identifier     = .init("icon")
            v.image          = info.appIcon
            v.imageScaling   = .scaleProportionallyUpOrDown
            return v

        case "app":
            return textCell(tableView, id: "app",
                            value: info.appName,
                            color: isCapturing ? .systemGreen : .labelColor)

        case "window":
            return textCell(tableView, id: "window",
                            value: info.displayTitle,
                            color: info.title.isEmpty ? .tertiaryLabelColor : .labelColor)

        case "display":
            return textCell(tableView, id: "display",
                            value: displayName(for: info.frame),
                            color: .secondaryLabelColor)

        default: return nil
        }
    }

    private func textCell(_ tv: NSTableView, id: String,
                          value: String, color: NSColor) -> NSTextField {
        let cell: NSTextField
        if let e = tv.makeView(withIdentifier: .init(id), owner: nil) as? NSTextField {
            cell = e
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier     = .init(id)
            cell.font           = .systemFont(ofSize: 12)
            cell.lineBreakMode  = .byTruncatingTail
        }
        cell.stringValue = value
        cell.textColor   = color
        return cell
    }
}
