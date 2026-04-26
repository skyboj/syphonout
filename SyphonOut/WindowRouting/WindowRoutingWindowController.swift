import AppKit
import ScreenCaptureKit

/// Entry-point controller for the Window Routing module.
/// Hosts the routing panel: a live window list (WindowInventory) + move controls.
///
/// Step 4 will add OutputSlot capture integration.
final class WindowRoutingWindowController: NSWindowController, NSWindowDelegate {

    static let shared = WindowRoutingWindowController()

    // MARK: - Subviews

    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!

    // Bottom action bar
    private var screenPopup: NSPopUpButton!
    private var moveButton: NSButton!
    private var moveFillButton: NSButton!
    private var actionStatusLabel: NSTextField!

    // MARK: - Data

    private let inventory = WindowInventory()
    private var windows: [WindowInfo] = []

    // MARK: - Init

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Window Routing"
        window.minSize = NSSize(width: 500, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireInventory()
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

    // MARK: - UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ── Toolbar ───────────────────────────────────────────────────────────
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)

        let titleLabel = makeLabel("On-Screen Windows", size: 13, bold: true)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(titleLabel)

        statusLabel = makeLabel("", size: 11, bold: false)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(statusLabel)

        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(manualRefresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(refreshButton)

        // ── Table ─────────────────────────────────────────────────────────────
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20

        addColumn(id: "icon",    title: "",            width: 20,  minWidth: 20,  maxWidth: 20,  resizable: false)
        addColumn(id: "app",     title: "Application", width: 160, minWidth: 100, maxWidth: 260, resizable: true)
        addColumn(id: "window",  title: "Window",      width: 280, minWidth: 120, maxWidth: 500, resizable: true)
        addColumn(id: "display", title: "Display",     width: 120, minWidth: 80,  maxWidth: 200, resizable: true)

        tableView.dataSource = self
        tableView.delegate   = self

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        // ── Action bar ────────────────────────────────────────────────────────
        let actionBar = NSView()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(actionBar)

        let toLabel = makeLabel("Move to:", size: 12, bold: false)
        toLabel.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(toLabel)

        screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        screenPopup.controlSize = .regular
        screenPopup.translatesAutoresizingMaskIntoConstraints = false
        screenPopup.target = self
        screenPopup.action = #selector(screenPopupChanged)
        actionBar.addSubview(screenPopup)

        moveButton = NSButton(title: "Move", target: self, action: #selector(moveWindow))
        moveButton.bezelStyle = .rounded
        moveButton.isEnabled = false
        moveButton.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(moveButton)

        moveFillButton = NSButton(title: "Move & Fill", target: self, action: #selector(moveAndFillWindow))
        moveFillButton.bezelStyle = .rounded
        moveFillButton.isEnabled = false
        moveFillButton.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(moveFillButton)

        actionStatusLabel = makeLabel("", size: 11, bold: false)
        actionStatusLabel.textColor = .secondaryLabelColor
        actionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(actionStatusLabel)

        // ── Bottom count bar ──────────────────────────────────────────────────
        let countBar = NSView()
        countBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(countBar)

        let countLabel = makeLabel("", size: 11, bold: false)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.tag = 42
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countBar.addSubview(countLabel)

        // ── Constraints ───────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            // Toolbar (top)
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

            // Table (middle, stretches)
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            // Action bar
            actionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: countBar.topAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 44),
            toLabel.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 12),
            toLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            screenPopup.leadingAnchor.constraint(equalTo: toLabel.trailingAnchor, constant: 8),
            screenPopup.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            screenPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            moveButton.leadingAnchor.constraint(equalTo: screenPopup.trailingAnchor, constant: 10),
            moveButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            moveFillButton.leadingAnchor.constraint(equalTo: moveButton.trailingAnchor, constant: 6),
            moveFillButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            actionStatusLabel.leadingAnchor.constraint(equalTo: moveFillButton.trailingAnchor, constant: 12),
            actionStatusLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            actionStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionBar.trailingAnchor, constant: -12),

            // Count bar (bottom)
            countBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            countBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            countBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            countBar.heightAnchor.constraint(equalToConstant: 24),
            countLabel.leadingAnchor.constraint(equalTo: countBar.leadingAnchor, constant: 12),
            countLabel.centerYAnchor.constraint(equalTo: countBar.centerYAnchor),
        ])

        rebuildScreenPopup()
    }

    // MARK: - Screen popup

    private func rebuildScreenPopup() {
        screenPopup.removeAllItems()
        for screen in NSScreen.screens {
            screenPopup.addItem(withTitle: screen.localizedName)
        }
        // Observe display config changes
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    @objc private func screensChanged() {
        rebuildScreenPopup()
    }

    @objc private func screenPopupChanged() {
        // No-op — selection is read at move time
    }

    private var selectedScreen: NSScreen? {
        let idx = screenPopup.indexOfSelectedItem
        let screens = NSScreen.screens
        guard idx >= 0, idx < screens.count else { return screens.first }
        return screens[idx]
    }

    // MARK: - Inventory wiring

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

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        inventory.start()
        rebuildScreenPopup()
    }

    func windowWillClose(_ notification: Notification) {
        inventory.stop()
    }

    // MARK: - Actions

    @objc private func manualRefresh() {
        statusLabel.stringValue = "Refreshing…"
        inventory.stop()
        inventory.start()
    }

    @objc private func moveWindow() {
        performMove(resize: false)
    }

    @objc private func moveAndFillWindow() {
        performMove(resize: true)
    }

    private func performMove(resize: Bool) {
        guard let info = selectedWindowInfo,
              let screen = selectedScreen else { return }

        let result = WindowMover.move(info, to: screen, resize: resize)
        switch result {
        case .success:
            let verb = resize ? "moved & filled" : "moved"
            actionStatusLabel.stringValue = "✓ \(info.appName): \(info.displayTitle) \(verb) to \(screen.localizedName)"
            actionStatusLabel.textColor = .labelColor
            // Refresh inventory shortly so the table updates with new position
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.inventory.stop()
                self?.inventory.start()
            }
        case .noAccessibility:
            actionStatusLabel.stringValue = "✗ Accessibility permission required"
            actionStatusLabel.textColor = .systemRed
        case .windowNotFound:
            actionStatusLabel.stringValue = "✗ Window no longer on screen"
            actionStatusLabel.textColor = .systemOrange
        case .axError(let err):
            actionStatusLabel.stringValue = "✗ AX error \(err.rawValue)"
            actionStatusLabel.textColor = .systemRed
        }
    }

    // MARK: - Selection helpers

    private var selectedWindowInfo: WindowInfo? {
        let row = tableView.selectedRow
        guard row >= 0, row < windows.count else { return nil }
        return windows[row]
    }

    private func updateActionBar() {
        let hasSelection = tableView.selectedRow >= 0
        moveButton.isEnabled     = hasSelection
        moveFillButton.isEnabled = hasSelection
    }

    // MARK: - Helpers

    private func addColumn(id: String, title: String, width: CGFloat,
                           minWidth: CGFloat, maxWidth: CGFloat, resizable: Bool) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = minWidth
        col.maxWidth = maxWidth
        col.resizingMask = resizable ? [.autoresizingMask, .userResizingMask] : []
        tableView.addTableColumn(col)
    }

    private func makeLabel(_ text: String, size: CGFloat, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return label
    }

    private func updateCountLabel() {
        if let label = window?.contentView?.viewWithTag(42) as? NSTextField {
            let n = windows.count
            label.stringValue = n == 0 ? "No windows" : "\(n) window\(n == 1 ? "" : "s")"
        }
    }

    private func shortTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// Converts an SCWindow frame (Quartz coords) to the name of the containing NSScreen.
    private func displayName(for frame: CGRect) -> String {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens {
            // Convert NSScreen (AppKit, bottom-left origin) → Quartz (top-left origin)
            let quartzRect = CGRect(
                x: screen.frame.origin.x,
                y: primary - screen.frame.origin.y - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height
            )
            if quartzRect.contains(mid) { return screen.localizedName }
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
        // Clear stale status message when the user picks a different row
        actionStatusLabel.stringValue = ""
        actionStatusLabel.textColor = .secondaryLabelColor
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < windows.count else { return nil }
        let info = windows[row]
        let colID = tableColumn?.identifier.rawValue ?? ""

        switch colID {
        case "icon":
            let cell = (tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("icon"), owner: nil)
                as? NSImageView) ?? NSImageView()
            cell.identifier = NSUserInterfaceItemIdentifier("icon")
            cell.image = info.appIcon
            cell.imageScaling = .scaleProportionallyUpOrDown
            return cell

        case "app":
            return makeTextCell(tableView, id: "app", value: info.appName,
                                color: .labelColor)

        case "window":
            return makeTextCell(tableView, id: "window", value: info.displayTitle,
                                color: info.title.isEmpty ? .tertiaryLabelColor : .labelColor)

        case "display":
            return makeTextCell(tableView, id: "display", value: displayName(for: info.frame),
                                color: .secondaryLabelColor)

        default:
            return nil
        }
    }

    private func makeTextCell(_ tv: NSTableView, id: String,
                               value: String, color: NSColor) -> NSTextField {
        let cell: NSTextField
        if let existing = tv.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? NSTextField {
            cell = existing
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = NSUserInterfaceItemIdentifier(id)
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingTail
        }
        cell.stringValue = value
        cell.textColor = color
        return cell
    }
}
